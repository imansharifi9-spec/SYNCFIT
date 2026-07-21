/**
 * Coach AI: draft a CoachRoutineTemplate for a client (review before send).
 * Free for coaches — gated by coach↔client auth + share toggles + daily rate limit.
 * No SyncFit+ entitlement check.
 */

const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { HttpsError } = require("firebase-functions/v2/https");
const {
  assertValidGoal,
  parseAndValidateCoachRoutineTemplate,
} = require("./programSchema");
const {
  callClaudeMessages,
  buildProgramPrompt,
  PROGRAM_MODEL,
} = require("./claudeClient");
const { loadSharedClientTrainingContext } = require("./trainingContext");
const { assertActiveCoachForClient } = require("./coachClientAccess");
const { reserveRateLimit, windowKey } = require("./rateLimit");

/** Max AI routine drafts per coach per UTC day. */
const COACH_ROUTINE_DRAFT_DAILY_LIMIT = 8;

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
  return new HttpsError(allowed.has(code) ? code : fallbackCode, message);
}

/**
 * @param {string} coachUid Authenticated coach (request.auth.uid)
 * @param {{ clientUserID: string, goal: string }} input
 * @param {object} [deps]
 */
async function generateCoachRoutineDraftForUid(coachUid, input, deps = {}) {
  if (!coachUid || typeof coachUid !== "string") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const clientUserID =
    input && typeof input.clientUserID === "string" ? input.clientUserID.trim() : "";
  if (!clientUserID) {
    throw new HttpsError("invalid-argument", "clientUserID is required.");
  }

  let goal;
  try {
    goal = assertValidGoal(input && input.goal);
  } catch (err) {
    throw toHttpsError(err, "invalid-argument", "Invalid goal.");
  }

  const db = deps.db || getFirestore();
  const now = deps.now || new Date();

  const assertCoach =
    deps.assertActiveCoachForClient || assertActiveCoachForClient;
  const { permissions } = await assertCoach(db, coachUid, clientUserID);

  const reserve =
    deps.reserveRateLimit ||
    ((args) =>
      reserveRateLimit({
        ...args,
        message:
          "AI routine draft limit reached for today. Try again tomorrow.",
        logLabel: "generateCoachRoutineDraft",
      }));

  await reserve({
    db,
    ref: db
      .collection("users")
      .doc(coachUid)
      .collection("coachAiRoutineDraftRateLimits")
      .doc(windowKey(now, "day")),
    now,
    limit: deps.dailyLimit || COACH_ROUTINE_DRAFT_DAILY_LIMIT,
    window: "day",
  });

  const loadContext =
    deps.loadSharedContext ||
    ((uid, perms) => loadSharedClientTrainingContext(uid, perms, { db, now }));
  const trainingSummary = await loadContext(clientUserID, permissions);

  // Expose the filtered payload for tests / diagnostics — never log client PII in prod paths.
  if (typeof deps.onTrainingSummary === "function") {
    deps.onTrainingSummary(trainingSummary);
  }

  const { system, user } = buildProgramPrompt({ goal, trainingSummary });
  const coachSystem = [
    system,
    "",
    "You are drafting a routine FOR A HUMAN COACH to review before sending to their client.",
    "Only use categories listed in sharedCategories — do not invent nutrition or progress context that was not provided.",
    `Shared categories: ${JSON.stringify(trainingSummary.sharedCategories || {})}.`,
  ].join("\n");

  const callClaude = deps.callClaude || callClaudeMessages;
  const getApiKey =
    deps.getApiKey ||
    (() => {
      throw Object.assign(new Error("ANTHROPIC_API_KEY is not configured."), {
        code: "failed-precondition",
      });
    });

  let rawText;
  try {
    rawText = await callClaude({
      apiKey: getApiKey(),
      system: coachSystem,
      user,
      model: PROGRAM_MODEL,
    });
  } catch (err) {
    console.error(
      `[generateCoachRoutineDraft] Claude failed coach=${coachUid} client=${clientUserID}`,
      err && err.raw ? err.raw : err
    );
    throw toHttpsError(
      err,
      "unavailable",
      "Routine draft generation failed talking to the AI provider."
    );
  }

  const validated = parseAndValidateCoachRoutineTemplate(rawText);
  if (!validated.ok) {
    console.error(
      `[generateCoachRoutineDraft] Invalid AI JSON coach=${coachUid} error=${validated.error}`
    );
    throw new HttpsError(
      "unavailable",
      "Routine draft generation failed: AI response was not valid program JSON."
    );
  }

  const template = validated.template;
  const firestoreTs = Timestamp.now();
  const firestorePayload = {
    id: template.id,
    name: template.name,
    days: template.days,
    createdAt: firestoreTs,
    updatedAt: firestoreTs,
    source: "ai_draft",
    status: "draft",
    goal,
    draftForClientId: clientUserID,
    generatedAt: FieldValue.serverTimestamp(),
    generatedByCoachUid: coachUid,
    sharedCategoriesUsed: trainingSummary.sharedCategories || permissions,
  };

  // Draft only — coach must review/edit and send via existing sendRoutineCard flow.
  await db
    .collection("coaches")
    .doc(coachUid)
    .collection("routine_templates")
    .doc(template.id)
    .set(firestorePayload);

  console.log(
    `[generateCoachRoutineDraft] Saved draft coach=${coachUid} client=${clientUserID} id=${template.id} goal=${goal}`
  );

  return {
    programId: template.id,
    template: {
      ...template,
      source: "ai_draft",
      status: "draft",
      goal,
      draftForClientId: clientUserID,
    },
    source: "ai_draft",
    status: "draft",
    goal,
    sharedCategoriesUsed: trainingSummary.sharedCategories || permissions,
  };
}

module.exports = {
  COACH_ROUTINE_DRAFT_DAILY_LIMIT,
  generateCoachRoutineDraftForUid,
};
