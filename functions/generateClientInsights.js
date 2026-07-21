/**
 * Coach AI: concise client activity insights (Haiku).
 * Free for coaches — gated by coach↔client auth + share toggles + daily rate limit.
 * Caches recent insights so reopening a client detail view does not burn a generation.
 */

const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { HttpsError } = require("firebase-functions/v2/https");
const { callClaudeMessages, COMPANION_CHAT_MODEL } = require("./claudeClient");
const { loadSharedClientTrainingContext } = require("./trainingContext");
const { assertActiveCoachForClient } = require("./coachClientAccess");
const { reserveRateLimit, windowKey } = require("./rateLimit");

/** Max fresh insight generations per coach per UTC day (cache hits do not count). */
const COACH_INSIGHTS_DAILY_LIMIT = 40;
/** Reuse a cached insight younger than this (ms). */
const COACH_INSIGHTS_CACHE_TTL_MS = 6 * 60 * 60 * 1000;
const COACH_INSIGHTS_MAX_TOKENS = 450;
/** Exposed for tests — must stay on Haiku for cheap summarization. */
const COACH_INSIGHTS_MODEL = COMPANION_CHAT_MODEL;

function toHttpsError(err, fallbackCode, fallbackMessage) {
  if (err instanceof HttpsError) return err;
  const code = (err && err.code) || fallbackCode;
  const message = (err && err.message) || fallbackMessage;
  const allowed = new Set([
    "ok",
    "cancelled",
    "unknown",
    "invalid-argument",
    "deadline-exceeded",
    "not-found",
    "already-exists",
    "permission-denied",
    "resource-exhausted",
    "failed-precondition",
    "aborted",
    "out-of-range",
    "unimplemented",
    "internal",
    "unavailable",
    "data-loss",
    "unauthenticated",
  ]);
  let resolved = allowed.has(code) ? code : fallbackCode;
  if (resolved === "internal") {
    resolved = fallbackCode === "internal" ? "unavailable" : fallbackCode;
  }
  return new HttpsError(resolved, message);
}

function buildInsightsPrompt({ clientName, trainingSummary }) {
  const system = [
    "You are SyncFit's coach assistant.",
    "Write a concise quick-scan insight for a human coach reviewing one client.",
    "3–6 short bullet points or a short paragraph — NOT a full report.",
    "Focus on consistency patterns, notable changes, and anything worth the coach's attention.",
    "Only use data present in sharedCategories / the provided context.",
    "If a category was not shared, do not invent or speculate about it.",
    "CRITICAL counting rules:",
    "- workoutSessionCount (and workoutCount) = DISTINCT workout SESSIONS (calendar days / labeled sessions), NOT individual exercise documents.",
    "- muscleGroupSessionFrequency / muscleGroupFrequency values are session counts (how many sessions hit that muscle group), not exercise-entry counts.",
    "- exerciseEntryCount is raw per-exercise documents — do NOT report this as workouts/sessions.",
    "You may use light Markdown (**bold**, bullets). Put a blank line between bullets/sections.",
    "No medical diagnosis. Plain language. No markdown headers (#).",
  ].join("\n");

  const user = [
    `Client: ${clientName || "Client"}`,
    "",
    "Shared client activity context (respect sharedCategories — unshared domains are absent on purpose):",
    JSON.stringify(trainingSummary, null, 2),
    "",
    "Return only the insight text for the coach.",
  ].join("\n");

  return { system, user };
}

/**
 * @param {string} coachUid
 * @param {{ clientUserID: string, forceRefresh?: boolean }} input
 * @param {object} [deps]
 */
async function generateClientInsightsForUid(coachUid, input, deps = {}) {
  if (!coachUid || typeof coachUid !== "string") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const clientUserID =
    input && typeof input.clientUserID === "string" ? input.clientUserID.trim() : "";
  if (!clientUserID) {
    throw new HttpsError("invalid-argument", "clientUserID is required.");
  }

  const forceRefresh = Boolean(input && input.forceRefresh);
  const db = deps.db || getFirestore();
  const now = deps.now || new Date();
  const cacheTtlMs = deps.cacheTtlMs ?? COACH_INSIGHTS_CACHE_TTL_MS;

  const assertCoach =
    deps.assertActiveCoachForClient || assertActiveCoachForClient;
  const { permissions, connection } = await assertCoach(
    db,
    coachUid,
    clientUserID
  );

  const cacheRef = db
    .collection("coaches")
    .doc(coachUid)
    .collection("clientInsights")
    .doc(clientUserID);

  if (!forceRefresh) {
    const cached = await cacheRef.get();
    if (cached.exists) {
      const data = cached.data() || {};
      const generatedAt =
        data.generatedAt && typeof data.generatedAt.toDate === "function"
          ? data.generatedAt.toDate()
          : data.generatedAt instanceof Date
            ? data.generatedAt
            : null;
      const insight =
        typeof data.insight === "string" ? data.insight.trim() : "";
      if (
        insight &&
        generatedAt &&
        now.getTime() - generatedAt.getTime() < cacheTtlMs
      ) {
        return {
          insight,
          cached: true,
          generatedAt: generatedAt.toISOString(),
          sharedCategoriesUsed: data.sharedCategoriesUsed || permissions,
          clientUserID,
        };
      }
    }
  }

  const reserve =
    deps.reserveRateLimit ||
    ((args) =>
      reserveRateLimit({
        ...args,
        message:
          "AI client insight limit reached for today. Try again tomorrow.",
        logLabel: "generateClientInsights",
      }));

  await reserve({
    db,
    ref: db
      .collection("users")
      .doc(coachUid)
      .collection("coachAiInsightsRateLimits")
      .doc(windowKey(now, "day")),
    now,
    limit: deps.dailyLimit || COACH_INSIGHTS_DAILY_LIMIT,
    window: "day",
  });

  const loadContext =
    deps.loadSharedContext ||
    ((uid, perms) => loadSharedClientTrainingContext(uid, perms, { db, now }));
  const trainingSummary = await loadContext(clientUserID, permissions);

  if (typeof deps.onTrainingSummary === "function") {
    deps.onTrainingSummary(trainingSummary);
  }

  const clientName =
    (connection && (connection.clientName || connection.clientDisplayName)) ||
    (trainingSummary.profileHints && trainingSummary.profileHints.profileName) ||
    "Client";

  const { system, user } = buildInsightsPrompt({ clientName, trainingSummary });
  const callClaude = deps.callClaude || callClaudeMessages;
  const getApiKey =
    deps.getApiKey ||
    (() => {
      throw Object.assign(new Error("ANTHROPIC_API_KEY is not configured."), {
        code: "failed-precondition",
      });
    });

  let insightText;
  try {
    insightText = await callClaude({
      apiKey: getApiKey(),
      system,
      user,
      model: COACH_INSIGHTS_MODEL,
      maxTokens: COACH_INSIGHTS_MAX_TOKENS,
    });
  } catch (err) {
    console.error(
      `[generateClientInsights] Claude failed coach=${coachUid} client=${clientUserID}`,
      err && err.raw ? err.raw : err
    );
    throw toHttpsError(
      err,
      "unavailable",
      "Client insight generation failed talking to the AI provider."
    );
  }

  const insight = String(insightText || "").trim();
  if (!insight) {
    throw new HttpsError(
      "unavailable",
      "Client insight generation returned an empty response."
    );
  }

  await cacheRef.set({
    insight,
    clientUserID,
    generatedAt: Timestamp.fromDate(now),
    updatedAt: FieldValue.serverTimestamp(),
    sharedCategoriesUsed: trainingSummary.sharedCategories || permissions,
    model: COACH_INSIGHTS_MODEL,
  });

  console.log(
    `[generateClientInsights] Generated coach=${coachUid} client=${clientUserID} chars=${insight.length}`
  );

  return {
    insight,
    cached: false,
    generatedAt: now.toISOString(),
    sharedCategoriesUsed: trainingSummary.sharedCategories || permissions,
    clientUserID,
  };
}

module.exports = {
  COACH_INSIGHTS_DAILY_LIMIT,
  COACH_INSIGHTS_CACHE_TTL_MS,
  COACH_INSIGHTS_MAX_TOKENS,
  COACH_INSIGHTS_MODEL,
  buildInsightsPrompt,
  generateClientInsightsForUid,
};
