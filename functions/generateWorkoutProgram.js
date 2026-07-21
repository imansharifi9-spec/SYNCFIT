/**
 * Core SyncFit+ AI workout program generation (testable without onCall wrapper).
 */

const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { HttpsError } = require("firebase-functions/v2/https");
const {
  checkSubscriptionEntitlementForUid,
} = require("./subscriptionGate");
const {
  assertValidGoal,
  parseAndValidateCoachRoutineTemplate,
} = require("./programSchema");
const {
  callClaudeMessages,
  buildProgramPrompt,
  PROGRAM_MODEL,
} = require("./claudeClient");
const { loadUserTrainingContext } = require("./trainingContext");

/**
 * @param {unknown} err
 * @param {string} fallbackCode
 * @param {string} fallbackMessage
 * @returns {HttpsError}
 */
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
 * Generate + persist an AI weekly program for an entitled user.
 *
 * @param {string} uid Authenticated user id (never from client body)
 * @param {{ goal: string }} input
 * @param {object} [deps] Injectable dependencies for tests
 * @param {() => Promise<{ entitled: boolean, reason: string }>} [deps.checkEntitlement]
 * @param {(uid: string) => Promise<object>} [deps.loadContext]
 * @param {(args: object) => Promise<string>} [deps.callClaude]
 * @param {() => string} [deps.getApiKey]
 * @param {FirebaseFirestore.Firestore} [deps.db]
 * @returns {Promise<{ programId: string, template: object, source: string, goal: string }>}
 */
async function generateWorkoutProgramForUid(uid, input, deps = {}) {
  if (!uid || typeof uid !== "string") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const checkEntitlement =
    deps.checkEntitlement || (() => checkSubscriptionEntitlementForUid(uid));
  const entitlement = await checkEntitlement();
  if (!entitlement.entitled) {
    throw new HttpsError(
      "permission-denied",
      `SyncFit+ subscription required to generate workout programs. (${entitlement.reason})`
    );
  }

  let goal;
  try {
    goal = assertValidGoal(input && input.goal);
  } catch (err) {
    throw toHttpsError(err, "invalid-argument", "Invalid goal.");
  }

  const loadContext = deps.loadContext || ((userId) => loadUserTrainingContext(userId));
  const trainingSummary = await loadContext(uid);

  const { system, user } = buildProgramPrompt({ goal, trainingSummary });
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
      system,
      user,
      model: PROGRAM_MODEL,
    });
  } catch (err) {
    console.error(
      `[generateWorkoutProgram] Claude call failed uid=${uid}`,
      err && err.raw ? err.raw : err
    );
    throw toHttpsError(
      err,
      "internal",
      "Workout program generation failed talking to the AI provider."
    );
  }

  const validated = parseAndValidateCoachRoutineTemplate(rawText);
  if (!validated.ok) {
    console.error(
      `[generateWorkoutProgram] Invalid AI JSON uid=${uid} error=${validated.error} raw=${rawText}`
    );
    throw new HttpsError(
      "internal",
      "Workout program generation failed: AI response was not valid program JSON."
    );
  }

  const template = validated.template;
  const db = deps.db || getFirestore();
  const now = Timestamp.now();

  const firestorePayload = {
    id: template.id,
    name: template.name,
    days: template.days,
    createdAt: now,
    updatedAt: now,
    source: "ai_generated",
    goal,
    generatedAt: FieldValue.serverTimestamp(),
    generatedForUid: uid,
  };

  // Same nested CoachRoutineTemplate shape as coaches/{uid}/routine_templates,
  // scoped to the athlete: users/{uid}/routine_templates/{id}
  const ref = db
    .collection("users")
    .doc(uid)
    .collection("routine_templates")
    .doc(template.id);

  await ref.set(firestorePayload);

  console.log(
    `[generateWorkoutProgram] Saved ai program uid=${uid} id=${template.id} goal=${goal}`
  );

  return {
    programId: template.id,
    template: {
      ...template,
      source: "ai_generated",
      goal,
    },
    source: "ai_generated",
    goal,
  };
}

module.exports = {
  generateWorkoutProgramForUid,
};
