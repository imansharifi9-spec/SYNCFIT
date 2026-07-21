/**
 * Emulator tests for generateWorkoutProgram.
 * Run via: firebase emulators:exec --only firestore "npm test --prefix functions"
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
  generateWorkoutProgramForUid,
} = require("../generateWorkoutProgram");
const { parseAndValidateCoachRoutineTemplate } = require("../programSchema");

const db = admin.firestore();

function validProgramJson(name = "AI Push Pull Legs") {
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

async function seedEntitledUser(uid) {
  const future = admin.firestore.Timestamp.fromDate(
    new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)
  );
  await db.collection("users").doc(uid).set({
    subscriptionStatus: "active",
    subscriptionExpiresAt: future,
    profileName: "Test Athlete",
  });
}

async function seedUnearnedUser(uid) {
  await db.collection("users").doc(uid).set({
    subscriptionStatus: "none",
  });
}

describe("generateWorkoutProgram", function () {
  this.timeout(20000);

  before(function () {
    if (!process.env.FIRESTORE_EMULATOR_HOST) {
      throw new Error(
        "FIRESTORE_EMULATOR_HOST is not set — run via firebase emulators:exec"
      );
    }
  });

  it("schema validator accepts a well-formed CoachRoutineTemplate", function () {
    const result = parseAndValidateCoachRoutineTemplate(validProgramJson());
    expect(result.ok).to.equal(true);
    expect(result.template.days).to.have.length(7);
    expect(result.template.days[0].exercises[0]).to.include.keys(
      "name",
      "muscleGroup",
      "setCount",
      "reps"
    );
  });

  it("entitled user gets a correctly-structured program saved (Claude mocked)", async function () {
    const uid = "ai-prog-entitled";
    await seedEntitledUser(uid);

    let claudeCalls = 0;
    const result = await generateWorkoutProgramForUid(
      uid,
      { goal: "strength" },
      {
        callClaude: async () => {
          claudeCalls += 1;
          return validProgramJson("Strength Block");
        },
        getApiKey: () => "test-key-not-used-by-mock",
        db,
      }
    );

    expect(claudeCalls).to.equal(1);
    expect(result.source).to.equal("ai_generated");
    expect(result.goal).to.equal("strength");
    expect(result.programId).to.be.a("string");
    expect(result.template.days).to.have.length(7);

    const saved = await db
      .collection("users")
      .doc(uid)
      .collection("routine_templates")
      .doc(result.programId)
      .get();

    expect(saved.exists).to.equal(true);
    const data = saved.data();
    expect(data.source).to.equal("ai_generated");
    expect(data.goal).to.equal("strength");
    expect(data.name).to.equal("Strength Block");
    expect(data.days).to.be.an("array").with.length(7);
    expect(data.days[0].exercises[0].setCount).to.equal(4);
  });

  it("non-entitled user is rejected before any AI call", async function () {
    const uid = "ai-prog-not-entitled";
    await seedUnearnedUser(uid);

    let claudeCalls = 0;
    let thrown = null;
    try {
      await generateWorkoutProgramForUid(
        uid,
        { goal: "maintenance" },
        {
          callClaude: async () => {
            claudeCalls += 1;
            return validProgramJson();
          },
          getApiKey: () => "should-never-be-read",
          db,
        }
      );
    } catch (err) {
      thrown = err;
    }

    expect(thrown).to.be.instanceOf(HttpsError);
    expect(thrown.code).to.equal("permission-denied");
    expect(claudeCalls).to.equal(0);

    const snap = await db
      .collection("users")
      .doc(uid)
      .collection("routine_templates")
      .get();
    expect(snap.empty).to.equal(true);
  });

  it("malformed AI JSON is rejected and not saved", async function () {
    const uid = "ai-prog-bad-json";
    await seedEntitledUser(uid);

    let thrown = null;
    try {
      await generateWorkoutProgramForUid(
        uid,
        { goal: "progressive_overload" },
        {
          callClaude: async () => "Sure! Here's a workout: do some squats.",
          getApiKey: () => "test-key",
          db,
        }
      );
    } catch (err) {
      thrown = err;
    }

    expect(thrown).to.be.instanceOf(HttpsError);
    expect(thrown.code).to.equal("internal");
    expect(String(thrown.message)).to.match(/not valid program JSON/i);

    const snap = await db
      .collection("users")
      .doc(uid)
      .collection("routine_templates")
      .get();
    expect(snap.empty).to.equal(true);
  });

  it("invalid goal is rejected without calling Claude", async function () {
    const uid = "ai-prog-bad-goal";
    await seedEntitledUser(uid);

    let claudeCalls = 0;
    let thrown = null;
    try {
      await generateWorkoutProgramForUid(
        uid,
        { goal: "shredded_abs" },
        {
          callClaude: async () => {
            claudeCalls += 1;
            return validProgramJson();
          },
          getApiKey: () => "test-key",
          db,
        }
      );
    } catch (err) {
      thrown = err;
    }

    expect(thrown).to.be.instanceOf(HttpsError);
    expect(thrown.code).to.equal("invalid-argument");
    expect(claudeCalls).to.equal(0);
  });
});
