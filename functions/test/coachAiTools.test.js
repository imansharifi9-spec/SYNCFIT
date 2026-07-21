/**
 * Emulator tests for coach AI tools:
 * - generateCoachRoutineDraft
 * - generateClientInsights
 *
 * CRITICAL: share-toggle tests assert the actual Claude payload omits unshared data.
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "syncfit-8441f";
process.env.GOOGLE_CLOUD_PROJECT =
  process.env.GOOGLE_CLOUD_PROJECT || "syncfit-8441f";

const { expect } = require("chai");
const admin = require("firebase-admin");
const { HttpsError } = require("firebase-functions/v2/https");
const { randomUUID } = require("crypto");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "syncfit-8441f" });
}

const {
  generateCoachRoutineDraftForUid,
  COACH_ROUTINE_DRAFT_DAILY_LIMIT,
} = require("../generateCoachRoutineDraft");
const {
  generateClientInsightsForUid,
  COACH_INSIGHTS_MODEL,
} = require("../generateClientInsights");
const {
  connectionDocId,
  resolveSharePermissions,
  assertActiveCoachForClient,
} = require("../coachClientAccess");
const { loadSharedClientTrainingContext } = require("../trainingContext");

const db = admin.firestore();

const COACH = "coach-ai-tools-coach";
const CLIENT = "coach-ai-tools-client";
const STRANGER = "coach-ai-tools-stranger";

function validProgramJson(name = "Coach AI Draft PPL") {
  const days = [
    { weekday: 2, dayLabel: "Push", isRest: false },
    { weekday: 3, dayLabel: "Pull", isRest: false },
    { weekday: 4, dayLabel: "Legs", isRest: false },
    { weekday: 5, dayLabel: "THU", isRest: true },
    { weekday: 6, dayLabel: "FRI", isRest: true },
    { weekday: 7, dayLabel: "SAT", isRest: true },
    { weekday: 1, dayLabel: "SUN", isRest: true },
  ].map((d) => ({
    id: randomUUID(),
    ...d,
    exercises: d.isRest
      ? []
      : [
          {
            id: randomUUID(),
            name: d.dayLabel === "Push" ? "Bench Press" : "Barbell Row",
            muscleGroup: d.dayLabel === "Push" ? "Chest" : "Back",
            setCount: 4,
            reps: 8,
            weight: 135,
          },
        ],
  }));

  return JSON.stringify({
    id: randomUUID(),
    name,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    days,
  });
}

async function clearDocTree(ref) {
  await admin.firestore().recursiveDelete(ref);
}

async function seedConnection({
  coachId = COACH,
  clientId = CLIENT,
  shareWorkouts = true,
  shareNutrition = true,
  shareProgress = true,
  status = "active",
} = {}) {
  const id = connectionDocId(clientId, coachId);
  await db.collection("coach_clients").doc(id).set({
    coachId,
    clientId,
    clientUserID: clientId,
    clientName: "Test Client",
    coachName: "Test Coach",
    status,
    permissions: {
      workouts: shareWorkouts,
      nutrition: shareNutrition,
      progress: shareProgress,
    },
    shareWorkouts,
    shareNutrition,
    shareProgress,
    connectedAt: admin.firestore.Timestamp.now(),
  });
  return id;
}

async function seedClientData(clientId = CLIENT) {
  const now = admin.firestore.Timestamp.now();
  await db.collection("users").doc(clientId).set({
    profileName: "Test Client",
    goalRaw: "Build muscle",
    experienceRaw: "intermediate",
    calorieTarget: 2400,
    proteinTarget: 160,
  });

  await db
    .collection("users")
    .doc(clientId)
    .collection("workouts")
    .doc("w1")
    .set({
      id: "w1",
      date: now,
      exerciseName: "SECRET_WORKOUT_SQUAT",
      muscleGroup: "Legs",
      sets: [{ reps: 5, weight: 225 }],
    });

  await db
    .collection("users")
    .doc(clientId)
    .collection("meals")
    .doc("m1")
    .set({
      id: "m1",
      date: now,
      name: "SECRET_MEAL_CHICKEN",
      meal: "lunch",
      calories: 500,
      protein: 40,
      carbs: 30,
      fat: 10,
    });

  await db
    .collection("users")
    .doc(clientId)
    .collection("weights")
    .doc("wt1")
    .set({
      id: "wt1",
      date: now,
      weight: 180,
      unit: "lb",
      notes: "SECRET_WEIGHT_NOTE",
    });
}

describe("coachClientAccess", function () {
  this.timeout(20000);

  before(function () {
    if (!process.env.FIRESTORE_EMULATOR_HOST) {
      throw new Error(
        "FIRESTORE_EMULATOR_HOST is not set — run via firebase emulators:exec"
      );
    }
  });

  beforeEach(async function () {
    await clearDocTree(db.collection("coach_clients").doc(connectionDocId(CLIENT, COACH)));
    await clearDocTree(db.collection("users").doc(CLIENT));
    await clearDocTree(db.collection("users").doc(COACH));
    await clearDocTree(db.collection("coaches").doc(COACH));
  });

  it("resolveSharePermissions prefers map and defaults missing to false", function () {
    expect(
      resolveSharePermissions({
        permissions: { workouts: true, nutrition: false },
        shareProgress: true,
      })
    ).to.deep.equal({
      workouts: true,
      nutrition: false,
      progress: true,
    });

    expect(resolveSharePermissions({})).to.deep.equal({
      workouts: false,
      nutrition: false,
      progress: false,
    });
  });

  it("assertActiveCoachForClient allows the real coach and rejects strangers", async function () {
    await seedConnection();
    const ok = await assertActiveCoachForClient(db, COACH, CLIENT);
    expect(ok.permissions.workouts).to.equal(true);

    try {
      await assertActiveCoachForClient(db, STRANGER, CLIENT);
      expect.fail("expected permission-denied");
    } catch (err) {
      expect(err).to.be.instanceOf(HttpsError);
      expect(err.code).to.equal("permission-denied");
    }
  });
});

describe("loadSharedClientTrainingContext — share toggle enforcement", function () {
  this.timeout(20000);

  beforeEach(async function () {
    await clearDocTree(db.collection("users").doc(CLIENT));
    await seedClientData(CLIENT);
  });

  it("omits nutrition and progress keys entirely when those toggles are off", async function () {
    const summary = await loadSharedClientTrainingContext(
      CLIENT,
      { workouts: true, nutrition: false, progress: false },
      { db }
    );

    expect(summary.sharedCategories).to.deep.equal({
      workouts: true,
      nutrition: false,
      progress: false,
    });
    expect(summary).to.have.property("recentWorkouts");
    expect(summary.recentWorkouts.some((w) => w.exerciseName === "SECRET_WORKOUT_SQUAT")).to.equal(
      true
    );
    expect(summary.workoutSessionCount).to.equal(1);
    expect(summary.workoutCount).to.equal(1);
    expect(summary.exerciseEntryCount).to.equal(1);

    // CRITICAL: unshared domains must not appear at all (not even empty arrays).
    expect(summary).to.not.have.property("recentMeals");
    expect(summary).to.not.have.property("mealCount");
    expect(summary).to.not.have.property("nutritionTotals");
    expect(summary).to.not.have.property("recentWeights");
    expect(summary).to.not.have.property("weightCount");

    const serialized = JSON.stringify(summary);
    expect(serialized).to.not.include("SECRET_MEAL_CHICKEN");
    expect(serialized).to.not.include("SECRET_WEIGHT_NOTE");
    expect(serialized).to.include("SECRET_WORKOUT_SQUAT");
  });

  it("counts distinct sessions not raw exercise documents", async function () {
    const { groupWorkoutSessions } = require("../trainingContext");
    const dayA = "2026-07-10T18:00:00.000Z";
    const dayB = "2026-07-12T18:00:00.000Z";
    // 2 sessions × 3 exercises = 6 docs (the 84/14 bug shape).
    const entries = ["Squat", "RDL", "Leg Press", "Bench", "OHP", "Fly"].map((name, i) => ({
      id: `e${i}`,
      date: i < 3 ? dayA : dayB,
      exerciseName: name,
      muscleGroup: i < 3 ? "Legs" : "Chest",
      sets: [{ reps: 8, weight: 100 }],
    }));

    const grouped = groupWorkoutSessions(entries);
    expect(grouped.exerciseEntryCount).to.equal(6);
    expect(grouped.workoutSessionCount).to.equal(2);
    expect(grouped.muscleGroupSessionFrequency.Legs).to.equal(1);
    expect(grouped.muscleGroupSessionFrequency.Chest).to.equal(1);
  });

  it("14 sessions × 6 exercises = 84 docs reports workoutSessionCount 14", async function () {
    const { loadSharedClientTrainingContext } = require("../trainingContext");
    const clientId = "coach-ai-session-count-client";
    await clearDocTree(db.collection("users").doc(clientId));

    const now = new Date("2026-07-19T12:00:00.000Z");
    const batch = db.batch();
    for (let day = 0; day < 14; day += 1) {
      const date = new Date(now.getTime() - day * 24 * 60 * 60 * 1000);
      const ts = admin.firestore.Timestamp.fromDate(date);
      for (let ex = 0; ex < 6; ex += 1) {
        const ref = db
          .collection("users")
          .doc(clientId)
          .collection("workouts")
          .doc(`d${day}-e${ex}`);
        batch.set(ref, {
          id: `d${day}-e${ex}`,
          date: ts,
          exerciseName: `Exercise ${ex}`,
          muscleGroup: ex % 2 === 0 ? "Legs" : "Chest",
          sets: [{ reps: 8, weight: 100 }],
        });
      }
    }
    await batch.commit();

    const summary = await loadSharedClientTrainingContext(
      clientId,
      { workouts: true, nutrition: false, progress: false },
      { db, now }
    );

    expect(summary.exerciseEntryCount).to.equal(84);
    expect(summary.workoutSessionCount).to.equal(14);
    expect(summary.workoutCount).to.equal(14);
    expect(summary.muscleGroupSessionFrequency.Legs).to.equal(14);
    expect(summary.muscleGroupSessionFrequency.Chest).to.equal(14);
  });
});

describe("generateCoachRoutineDraft", function () {
  this.timeout(20000);

  beforeEach(async function () {
    await clearDocTree(db.collection("coach_clients").doc(connectionDocId(CLIENT, COACH)));
    await clearDocTree(db.collection("users").doc(CLIENT));
    await clearDocTree(db.collection("users").doc(COACH));
    await clearDocTree(db.collection("coaches").doc(COACH));
    await seedClientData(CLIENT);
  });

  it("authorized coach with full sharing gets a draft saved under coaches/{coach}/routine_templates", async function () {
    await seedConnection({
      shareWorkouts: true,
      shareNutrition: true,
      shareProgress: true,
    });

    let capturedSummary = null;
    let claudeCalls = 0;

    const result = await generateCoachRoutineDraftForUid(
      COACH,
      { clientUserID: CLIENT, goal: "strength" },
      {
        db,
        now: new Date("2026-07-19T15:00:00.000Z"),
        onTrainingSummary: (s) => {
          capturedSummary = s;
        },
        callClaude: async ({ model, system, user }) => {
          claudeCalls += 1;
          expect(model).to.equal("claude-sonnet-4-6");
          expect(system).to.match(/human coach/i);
          expect(user).to.include("strength");
          return validProgramJson();
        },
        getApiKey: () => "mock-key",
      }
    );

    expect(claudeCalls).to.equal(1);
    expect(result.status).to.equal("draft");
    expect(result.source).to.equal("ai_draft");
    expect(result.goal).to.equal("strength");
    expect(capturedSummary.sharedCategories).to.deep.equal({
      workouts: true,
      nutrition: true,
      progress: true,
    });
    expect(capturedSummary).to.have.property("recentMeals");
    expect(capturedSummary).to.have.property("recentWeights");

    const saved = await db
      .collection("coaches")
      .doc(COACH)
      .collection("routine_templates")
      .doc(result.programId)
      .get();
    expect(saved.exists).to.equal(true);
    expect(saved.data().status).to.equal("draft");
    expect(saved.data().draftForClientId).to.equal(CLIENT);
  });

  it("rejects unauthorized user before any Claude call", async function () {
    await seedConnection();
    let claudeCalls = 0;

    try {
      await generateCoachRoutineDraftForUid(
        STRANGER,
        { clientUserID: CLIENT, goal: "maintenance" },
        {
          db,
          callClaude: async () => {
            claudeCalls += 1;
            return validProgramJson();
          },
          getApiKey: () => "mock-key",
        }
      );
      expect.fail("expected permission-denied");
    } catch (err) {
      expect(err).to.be.instanceOf(HttpsError);
      expect(err.code).to.equal("permission-denied");
      expect(claudeCalls).to.equal(0);
    }
  });

  it("does not send unshared nutrition/progress data to Claude", async function () {
    await seedConnection({
      shareWorkouts: true,
      shareNutrition: false,
      shareProgress: false,
    });

    let capturedSummary = null;
    let claudeUserPrompt = "";

    await generateCoachRoutineDraftForUid(
      COACH,
      { clientUserID: CLIENT, goal: "progressive_overload" },
      {
        db,
        now: new Date("2026-07-19T16:00:00.000Z"),
        onTrainingSummary: (s) => {
          capturedSummary = s;
        },
        callClaude: async ({ user }) => {
          claudeUserPrompt = user;
          return validProgramJson("Partial Share Draft");
        },
        getApiKey: () => "mock-key",
      }
    );

    expect(capturedSummary).to.not.have.property("recentMeals");
    expect(capturedSummary).to.not.have.property("recentWeights");
    expect(capturedSummary).to.have.property("recentWorkouts");
    expect(claudeUserPrompt).to.include("SECRET_WORKOUT_SQUAT");
    expect(claudeUserPrompt).to.not.include("SECRET_MEAL_CHICKEN");
    expect(claudeUserPrompt).to.not.include("SECRET_WEIGHT_NOTE");
    expect(JSON.stringify(capturedSummary)).to.not.include("SECRET_MEAL_CHICKEN");
  });

  it("enforces daily rate limit", async function () {
    await seedConnection();
    const now = new Date("2026-07-19T18:00:00.000Z");
    const deps = {
      db,
      now,
      dailyLimit: 2,
      callClaude: async () => validProgramJson(),
      getApiKey: () => "mock-key",
    };

    await generateCoachRoutineDraftForUid(
      COACH,
      { clientUserID: CLIENT, goal: "strength" },
      deps
    );
    await generateCoachRoutineDraftForUid(
      COACH,
      { clientUserID: CLIENT, goal: "strength" },
      deps
    );

    try {
      await generateCoachRoutineDraftForUid(
        COACH,
        { clientUserID: CLIENT, goal: "strength" },
        deps
      );
      expect.fail("expected resource-exhausted");
    } catch (err) {
      expect(err).to.be.instanceOf(HttpsError);
      expect(err.code).to.equal("resource-exhausted");
    }

    expect(COACH_ROUTINE_DRAFT_DAILY_LIMIT).to.be.a("number").and.to.be.above(0);
  });
});

describe("generateClientInsights", function () {
  this.timeout(20000);

  beforeEach(async function () {
    await clearDocTree(db.collection("coach_clients").doc(connectionDocId(CLIENT, COACH)));
    await clearDocTree(db.collection("users").doc(CLIENT));
    await clearDocTree(db.collection("users").doc(COACH));
    await clearDocTree(db.collection("coaches").doc(COACH));
    await seedClientData(CLIENT);
  });

  it("authorized coach gets an insight via Haiku and caches it", async function () {
    await seedConnection();
    let claudeCalls = 0;
    const now = new Date("2026-07-19T12:00:00.000Z");

    const first = await generateClientInsightsForUid(
      COACH,
      { clientUserID: CLIENT },
      {
        db,
        now,
        callClaude: async ({ model, maxTokens }) => {
          claudeCalls += 1;
          expect(model).to.equal(COACH_INSIGHTS_MODEL);
          expect(model).to.equal("claude-haiku-4-5-20251001");
          expect(maxTokens).to.equal(450);
          return "Hitting legs 2×/week. Protein looks solid on shared days.";
        },
        getApiKey: () => "mock-key",
      }
    );

    expect(first.cached).to.equal(false);
    expect(first.insight).to.match(/legs/i);
    expect(claudeCalls).to.equal(1);

    const second = await generateClientInsightsForUid(
      COACH,
      { clientUserID: CLIENT },
      {
        db,
        now: new Date("2026-07-19T14:00:00.000Z"),
        callClaude: async () => {
          claudeCalls += 1;
          return "should not run";
        },
        getApiKey: () => "mock-key",
      }
    );

    expect(second.cached).to.equal(true);
    expect(second.insight).to.equal(first.insight);
    expect(claudeCalls).to.equal(1);
  });

  it("rejects unauthorized user before Claude", async function () {
    await seedConnection();
    let claudeCalls = 0;
    try {
      await generateClientInsightsForUid(
        STRANGER,
        { clientUserID: CLIENT },
        {
          db,
          callClaude: async () => {
            claudeCalls += 1;
            return "nope";
          },
          getApiKey: () => "mock-key",
        }
      );
      expect.fail("expected permission-denied");
    } catch (err) {
      expect(err).to.be.instanceOf(HttpsError);
      expect(err.code).to.equal("permission-denied");
      expect(claudeCalls).to.equal(0);
    }
  });

  it("omits unshared nutrition from Claude payload", async function () {
    await seedConnection({
      shareWorkouts: true,
      shareNutrition: false,
      shareProgress: true,
    });

    let capturedSummary = null;
    let prompt = "";

    await generateClientInsightsForUid(
      COACH,
      { clientUserID: CLIENT, forceRefresh: true },
      {
        db,
        now: new Date("2026-07-19T20:00:00.000Z"),
        onTrainingSummary: (s) => {
          capturedSummary = s;
        },
        callClaude: async ({ user }) => {
          prompt = user;
          return "Workouts look consistent; body weight is trending down slightly.";
        },
        getApiKey: () => "mock-key",
      }
    );

    expect(capturedSummary.sharedCategories.nutrition).to.equal(false);
    expect(capturedSummary).to.not.have.property("recentMeals");
    expect(capturedSummary).to.have.property("recentWorkouts");
    expect(capturedSummary).to.have.property("recentWeights");
    expect(prompt).to.not.include("SECRET_MEAL_CHICKEN");
    expect(prompt).to.include("SECRET_WORKOUT_SQUAT");
    expect(prompt).to.include("SECRET_WEIGHT_NOTE");
  });

  it("enforces daily rate limit on fresh generations", async function () {
    await seedConnection();
    const now = new Date("2026-07-19T21:00:00.000Z");
    const deps = {
      db,
      now,
      dailyLimit: 1,
      cacheTtlMs: 0, // force miss so each call tries to generate
      callClaude: async () => "Quick tip: keep the streak going.",
      getApiKey: () => "mock-key",
    };

    await generateClientInsightsForUid(
      COACH,
      { clientUserID: CLIENT, forceRefresh: true },
      deps
    );

    try {
      await generateClientInsightsForUid(
        COACH,
        { clientUserID: CLIENT, forceRefresh: true },
        deps
      );
      expect.fail("expected resource-exhausted");
    } catch (err) {
      expect(err).to.be.instanceOf(HttpsError);
      expect(err.code).to.equal("resource-exhausted");
    }
  });
});
