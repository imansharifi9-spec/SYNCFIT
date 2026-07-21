/**
 * Emulator tests for resolveExerciseMedia.
 * Run via: firebase emulators:exec --only firestore "npm test --prefix functions"
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "syncfit-8441f";
process.env.GOOGLE_CLOUD_PROJECT =
  process.env.GOOGLE_CLOUD_PROJECT || "syncfit-8441f";

const { expect } = require("chai");
const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "syncfit-8441f" });
}

const {
  resolveExerciseMediaForName,
  cacheDocId,
  normalizeExerciseName,
  scoreNameMatch,
  pickBestMatch,
  isWeakOrMismatchedCache,
  cleanupMismatchedExerciseMediaCache,
  lookupExerciseMediaOverride,
  EXERCISE_MEDIA_OVERRIDES,
  MIN_REASONABLE_SCORE,
} = require("../resolveExerciseMedia");

const db = admin.firestore();

/** Representative names from ios/SyncFit/Models/ExerciseLibrary.swift */
const APP_LIBRARY_CASES = [
  {
    query: "Face Pull",
    // Override maps to cable rear delt row (with rope) — API mock is ignored.
    apiResults: [
      { exerciseId: "za9Ni4z", name: "barbell rack pull", gifUrl: "https://static.exercisedb.dev/media/za9Ni4z.gif" },
      { exerciseId: "dead", name: "barbell deadlift", gifUrl: "https://static.exercisedb.dev/media/dead.gif" },
    ],
    expectStatus: "found",
    expectMatchedContains: "rear delt",
    expectMatchSource: "override",
  },
  {
    query: "Lateral Raise",
    apiResults: [
      { exerciseId: "noise", name: "cable rear delt fly", gifUrl: "https://static.exercisedb.dev/media/noise.gif" },
      { exerciseId: "DsgkuIt", name: "dumbbell lateral raise", gifUrl: "https://static.exercisedb.dev/media/DsgkuIt.gif" },
    ],
    expectStatus: "found",
    expectMatchedContains: "lateral raise",
    expectMatchSource: "override",
  },
  {
    query: "Bench Press",
    apiResults: [
      { exerciseId: "EIeI8Vf", name: "barbell bench press", gifUrl: "https://static.exercisedb.dev/media/EIeI8Vf.gif" },
      { exerciseId: "wrist", name: "dumbbell over bench revers wrist curl", gifUrl: "https://static.exercisedb.dev/media/wrist.gif" },
    ],
    expectStatus: "found",
    expectMatchedContains: "bench press",
    expectMatchSource: "override",
  },
  {
    query: "Push-Up",
    apiResults: [
      { exerciseId: "CMAxnsG", name: "clock push-up", gifUrl: "https://static.exercisedb.dev/media/CMAxnsG.gif" },
      { exerciseId: "press", name: "barbell bench press", gifUrl: "https://static.exercisedb.dev/media/press.gif" },
    ],
    expectStatus: "found",
    expectMatchedContains: "push up",
    expectMatchSource: "override",
  },
  {
    query: "Romanian Deadlift",
    apiResults: [
      { exerciseId: "rdl", name: "barbell romanian deadlift", gifUrl: "https://static.exercisedb.dev/media/rdl.gif" },
      { exerciseId: "dl", name: "barbell deadlift", gifUrl: "https://static.exercisedb.dev/media/dl.gif" },
    ],
    expectStatus: "found",
    expectMatchedContains: "romanian deadlift",
    expectMatchSource: "fuzzy",
  },
  {
    query: "Skull Crusher",
    apiResults: [
      { exerciseId: "x", name: "ez barbell close grip preacher curl", gifUrl: "https://static.exercisedb.dev/media/x.gif" },
      { exerciseId: "y", name: "barbell lying triceps extension skull crusher", gifUrl: "https://static.exercisedb.dev/media/y.gif" },
    ],
    expectStatus: "found",
    expectMatchedContains: "skull crusher",
    expectMatchSource: "fuzzy",
  },
  {
    query: "Cable Fly",
    apiResults: [
      { exerciseId: "a", name: "cable cross-over variation", gifUrl: "https://static.exercisedb.dev/media/a.gif" },
      { exerciseId: "b", name: "cable fly", gifUrl: "https://static.exercisedb.dev/media/b.gif" },
    ],
    expectStatus: "found",
    expectMatchedContains: "cable middle fly",
    expectMatchSource: "override",
  },
  {
    query: "Treadmill Run",
    apiResults: [
      { exerciseId: "z", name: "walk elliptical cross trainer", gifUrl: "https://static.exercisedb.dev/media/z.gif" },
    ],
    expectStatus: "found",
    expectMatchedContains: "run",
    expectMatchSource: "override",
  },
  {
    query: "Seated Cable Row",
    apiResults: [
      { exerciseId: "calf", name: "lever seated calf raise", gifUrl: "https://static.exercisedb.dev/media/calf.gif" },
    ],
    expectStatus: "found",
    expectMatchedContains: "cable seated row",
    expectMatchSource: "override",
  },
];

describe("resolveExerciseMedia", function () {
  this.timeout(20000);

  before(function () {
    if (!process.env.FIRESTORE_EMULATOR_HOST) {
      throw new Error(
        "FIRESTORE_EMULATOR_HOST is not set — run via firebase emulators:exec"
      );
    }
  });

  it("scores exact matches above phrase containment", function () {
    expect(scoreNameMatch("bench press", "bench press")).to.equal(1000);
    expect(scoreNameMatch("bench press", "barbell bench press")).to.be.greaterThan(
      MIN_REASONABLE_SCORE
    );
    expect(scoreNameMatch("bench press", "barbell bench press")).to.be.greaterThan(
      scoreNameMatch("bench press", "dumbbell over bench revers wrist curl")
    );
  });

  it("rejects weak single-token overlap (Face Pull must not match rack pull / deadlift)", function () {
    expect(scoreNameMatch("face pull", "barbell rack pull")).to.be.below(
      MIN_REASONABLE_SCORE
    );
    expect(scoreNameMatch("face pull", "barbell deadlift")).to.equal(-1);
    expect(scoreNameMatch("face pull", "deadlift")).to.equal(-1);

    const picked = pickBestMatch("face pull", [
      { name: "barbell rack pull", exerciseId: "za9Ni4z" },
      { name: "barbell deadlift", exerciseId: "dead" },
    ]);
    expect(picked).to.equal(null);
  });

  it("accepts contiguous phrase matches like cable face pull", function () {
    expect(scoreNameMatch("face pull", "cable face pull")).to.be.at.least(
      MIN_REASONABLE_SCORE
    );
    const picked = pickBestMatch("face pull", [
      { name: "barbell rack pull", exerciseId: "bad" },
      { name: "cable face pull", exerciseId: "good" },
    ]);
    expect(picked).to.not.equal(null);
    expect(picked.exercise.exerciseId).to.equal("good");
  });

  APP_LIBRARY_CASES.forEach((testCase) => {
    it(`library case "${testCase.query}" → ${testCase.expectStatus}`, async function () {
      const normalized = normalizeExerciseName(testCase.query);
      const docId = cacheDocId(normalized);
      await db.collection("exerciseMedia").doc(docId).delete().catch(() => {});

      const result = await resolveExerciseMediaForName(testCase.query, {
        db,
        fetchExercisesByName: async () => testCase.apiResults,
      });

      expect(result.status).to.equal(testCase.expectStatus);
      if (testCase.expectStatus === "found") {
        expect(result.gifUrl).to.be.a("string");
        expect(normalizeExerciseName(result.matchedName)).to.include(
          testCase.expectMatchedContains
        );
        if (testCase.expectMatchSource) {
          expect(result.matchSource).to.equal(testCase.expectMatchSource);
        }
        // Never accept a clearly unrelated match
        expect(normalizeExerciseName(result.matchedName)).to.not.equal(
          "barbell deadlift"
        );
        expect(normalizeExerciseName(result.matchedName)).to.not.equal(
          "barbell rack pull"
        );
      } else {
        expect(result.gifUrl).to.equal(null);
      }
    });
  });

  it("manual overrides resolve before fuzzy search and ignore bad API results", async function () {
    expect(lookupExerciseMediaOverride("squat")).to.not.equal(null);
    expect(Object.keys(EXERCISE_MEDIA_OVERRIDES).length).to.be.at.least(50);

    const name = "Squat";
    const docId = cacheDocId(normalizeExerciseName(name));
    await db.collection("exerciseMedia").doc(docId).delete().catch(() => {});

    let apiCalls = 0;
    const result = await resolveExerciseMediaForName(name, {
      db,
      fetchExercisesByName: async () => {
        apiCalls += 1;
        return [
          {
            exerciseId: "75Bgtjy",
            name: "potty squat",
            gifUrl: "https://static.exercisedb.dev/media/75Bgtjy.gif",
          },
        ];
      },
    });

    expect(apiCalls).to.equal(0);
    expect(result.status).to.equal("found");
    expect(result.matchSource).to.equal("override");
    expect(result.exerciseId).to.equal("qXTaZnJ");
    expect(result.gifUrl).to.equal(
      "https://static.exercisedb.dev/media/qXTaZnJ.gif"
    );
    expect(normalizeExerciseName(result.matchedName)).to.include("squat");
  });

  it("cache hit skips the external API call for a strong match", async function () {
    // Use a name that is NOT in EXERCISE_MEDIA_OVERRIDES so cache path is exercised.
    const name = "Hammer Curl";
    const normalized = normalizeExerciseName(name);
    const docId = cacheDocId(normalized);

    await db.collection("exerciseMedia").doc(docId).set({
      status: "found",
      queryName: normalized,
      gifUrl: "https://static.exercisedb.dev/media/CACHED.gif",
      matchedName: "dumbbell hammer curl",
      targetMuscles: ["biceps"],
      matchSource: "fuzzy",
    });

    let apiCalls = 0;
    const result = await resolveExerciseMediaForName(name, {
      db,
      fetchExercisesByName: async () => {
        apiCalls += 1;
        return [];
      },
    });

    expect(apiCalls).to.equal(0);
    expect(result.cached).to.equal(true);
    expect(result.status).to.equal("found");
    expect(result.gifUrl).to.equal(
      "https://static.exercisedb.dev/media/CACHED.gif"
    );
  });

  it("override wins over a previously cached wrong Face Pull match", async function () {
    const name = "Face Pull";
    const normalized = normalizeExerciseName(name);
    const docId = cacheDocId(normalized);

    await db.collection("exerciseMedia").doc(docId).set({
      status: "found",
      queryName: normalized,
      gifUrl: "https://static.exercisedb.dev/media/DEADLIFT.gif",
      matchedName: "barbell rack pull",
      targetMuscles: ["glutes"],
    });

    let apiCalls = 0;
    const result = await resolveExerciseMediaForName(name, {
      db,
      fetchExercisesByName: async () => {
        apiCalls += 1;
        return [
          {
            exerciseId: "za9Ni4z",
            name: "barbell rack pull",
            gifUrl: "https://static.exercisedb.dev/media/za9Ni4z.gif",
          },
        ];
      },
    });

    expect(apiCalls).to.equal(0);
    expect(result.status).to.equal("found");
    expect(result.matchSource).to.equal("override");
    expect(result.exerciseId).to.equal("wqNPGCg");
    expect(result.gifUrl).to.equal(
      "https://static.exercisedb.dev/media/wqNPGCg.gif"
    );
  });

  it("self-heals weak cached matches by deleting and re-resolving", async function () {
    // Custom name with no override — weak cache must purge + re-query.
    const name = "Custom Face Drag XYZ";
    const normalized = normalizeExerciseName(name);
    const docId = cacheDocId(normalized);

    await db.collection("exerciseMedia").doc(docId).set({
      status: "found",
      queryName: normalized,
      gifUrl: "https://static.exercisedb.dev/media/DEADLIFT.gif",
      matchedName: "barbell rack pull",
      targetMuscles: ["glutes"],
      matchSource: "fuzzy",
    });

    expect(isWeakOrMismatchedCache(normalized, "barbell rack pull")).to.equal(
      true
    );

    let apiCalls = 0;
    const result = await resolveExerciseMediaForName(name, {
      db,
      fetchExercisesByName: async () => {
        apiCalls += 1;
        return [
          {
            exerciseId: "za9Ni4z",
            name: "barbell rack pull",
            gifUrl: "https://static.exercisedb.dev/media/za9Ni4z.gif",
          },
        ];
      },
    });

    expect(apiCalls).to.equal(1);
    expect(result.status).to.equal("not_found");
    expect(result.gifUrl).to.equal(null);

    const cached = await db.collection("exerciseMedia").doc(docId).get();
    expect(cached.data().status).to.equal("not_found");
  });

  it("cache miss calls external API once and writes to cache", async function () {
    const name = "Hammer Curl";
    const normalized = normalizeExerciseName(name);
    const docId = cacheDocId(normalized);

    await db.collection("exerciseMedia").doc(docId).delete().catch(() => {});

    let apiCalls = 0;
    const result = await resolveExerciseMediaForName(name, {
      db,
      fetchExercisesByName: async (query) => {
        apiCalls += 1;
        expect(query).to.equal(normalized);
        return [
          {
            exerciseId: "2NpxjC1",
            name: "dumbbell hammer curl",
            gifUrl: "https://static.exercisedb.dev/media/2NpxjC1.gif",
            targetMuscles: ["biceps"],
          },
          {
            exerciseId: "noise",
            name: "cable rear delt fly",
            gifUrl: "https://static.exercisedb.dev/media/noise.gif",
            targetMuscles: ["delts"],
          },
        ];
      },
    });

    expect(apiCalls).to.equal(1);
    expect(result.cached).to.equal(false);
    expect(result.status).to.equal("found");
    expect(result.gifUrl).to.equal(
      "https://static.exercisedb.dev/media/2NpxjC1.gif"
    );
    expect(result.matchedName).to.equal("dumbbell hammer curl");

    const second = await resolveExerciseMediaForName(name, {
      db,
      fetchExercisesByName: async () => {
        apiCalls += 1;
        return [];
      },
    });
    expect(apiCalls).to.equal(1);
    expect(second.cached).to.equal(true);
  });

  it("caches not_found and does not re-query", async function () {
    const name = "My Custom Made Up Lift XYZ";
    const normalized = normalizeExerciseName(name);
    const docId = cacheDocId(normalized);

    await db.collection("exerciseMedia").doc(docId).delete().catch(() => {});

    let apiCalls = 0;
    const first = await resolveExerciseMediaForName(name, {
      db,
      fetchExercisesByName: async () => {
        apiCalls += 1;
        return [];
      },
    });

    expect(apiCalls).to.equal(1);
    expect(first.status).to.equal("not_found");

    const second = await resolveExerciseMediaForName(name, {
      db,
      fetchExercisesByName: async () => {
        apiCalls += 1;
        return [
          {
            exerciseId: "should-not-be-used",
            name: "bench press",
            gifUrl: "https://static.exercisedb.dev/media/x.gif",
          },
        ];
      },
    });

    expect(apiCalls).to.equal(1);
    expect(second.cached).to.equal(true);
    expect(second.status).to.equal("not_found");
  });

  it("cleanupMismatchedExerciseMediaCache purges weak found entries", async function () {
    const badId = cacheDocId("custom face drag xyz");
    const goodId = cacheDocId("hammer curl");

    await db.collection("exerciseMedia").doc(badId).set({
      status: "found",
      queryName: "custom face drag xyz",
      matchedName: "barbell rack pull",
      gifUrl: "https://static.exercisedb.dev/media/bad.gif",
      matchSource: "fuzzy",
    });
    await db.collection("exerciseMedia").doc(goodId).set({
      status: "found",
      queryName: "hammer curl",
      matchedName: "dumbbell hammer curl",
      gifUrl: "https://static.exercisedb.dev/media/good.gif",
      matchSource: "fuzzy",
    });

    const result = await cleanupMismatchedExerciseMediaCache({ db });
    expect(result.purged).to.be.at.least(1);
    expect(result.purgedIds).to.include(badId);

    const badDoc = await db.collection("exerciseMedia").doc(badId).get();
    const goodDoc = await db.collection("exerciseMedia").doc(goodId).get();
    expect(badDoc.exists).to.equal(false);
    expect(goodDoc.exists).to.equal(true);
  });

  it("cleanup keeps override-backed entries even if scorer would call them weak", async function () {
    const faceId = cacheDocId("face pull");
    await db.collection("exerciseMedia").doc(faceId).set({
      status: "found",
      queryName: "face pull",
      matchedName: "cable rear delt row (with rope)",
      gifUrl: "https://static.exercisedb.dev/media/wqNPGCg.gif",
      matchSource: "override",
      exerciseId: "wqNPGCg",
    });

    const result = await cleanupMismatchedExerciseMediaCache({ db });
    expect(result.purgedIds).to.not.include(faceId);
    const faceDoc = await db.collection("exerciseMedia").doc(faceId).get();
    expect(faceDoc.exists).to.equal(true);
  });
});
