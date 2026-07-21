/**
 * Emulator demo: 84 exercise docs → 14 sessions insight regeneration.
 * Run: firebase emulators:exec --only firestore "node functions/scripts/demo-regenerate-insight.js"
 */
process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "syncfit-8441f";

const admin = require("firebase-admin");
const { generateClientInsightsForUid } = require("../generateClientInsights");
const { connectionDocId } = require("../coachClientAccess");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "syncfit-8441f" });
}

const db = admin.firestore();
const COACH = "demo-coach";
const CLIENT = "demo-client-84-14";

async function seed() {
  const now = new Date("2026-07-19T12:00:00.000Z");
  await db.collection("coach_clients").doc(connectionDocId(CLIENT, COACH)).set({
    coachId: COACH,
    clientId: CLIENT,
    clientUserID: CLIENT,
    clientName: "Demo Client",
    status: "active",
    permissions: { workouts: true, nutrition: true, progress: true },
    shareWorkouts: true,
    shareNutrition: true,
    shareProgress: true,
  });

  const batch = db.batch();
  for (let day = 0; day < 14; day += 1) {
    const date = new Date(now.getTime() - day * 24 * 60 * 60 * 1000);
    const ts = admin.firestore.Timestamp.fromDate(date);
    for (let ex = 0; ex < 6; ex += 1) {
      const ref = db.collection("users").doc(CLIENT).collection("workouts").doc(`d${day}-e${ex}`);
      batch.set(ref, {
        id: `d${day}-e${ex}`,
        date: ts,
        exerciseName: ex % 2 === 0 ? "Squat" : "Bench Press",
        muscleGroup: ex % 2 === 0 ? "Legs" : "Chest",
        sets: [{ reps: 8, weight: 135 }],
      });
    }
  }
  await batch.commit();
}

async function main() {
  await seed();

  let capturedSummary = null;
  const result = await generateClientInsightsForUid(
    COACH,
    { clientUserID: CLIENT, forceRefresh: true },
    {
      db,
      now: new Date("2026-07-19T12:00:00.000Z"),
      onTrainingSummary: (s) => {
        capturedSummary = s;
      },
      callClaude: async ({ user }) => {
        const sessionCount = capturedSummary?.workoutSessionCount ?? "?";
        const exerciseDocs = capturedSummary?.exerciseEntryCount ?? "?";
        if (String(user).includes(String(exerciseDocs)) && sessionCount !== exerciseDocs) {
          // Claude receives session count in JSON — simulate realistic coach copy.
          return [
            `**Exceptional workout consistency** — ${sessionCount} distinct sessions in the last 30 days (not ${exerciseDocs} exercise logs).`,
            "",
            `- Legs and chest both featured heavily across sessions (${capturedSummary.muscleGroupSessionFrequency?.Legs}/${capturedSummary.muscleGroupSessionFrequency?.Chest} sessions each).`,
            "- Nutrition logging is steady; protein intake looks on track for muscle-building goals.",
            "- No red flags on recovery — consider a small push on lower-body volume next block.",
          ].join("\n");
        }
        return "Insight generation context received.";
      },
      getApiKey: () => "mock-key",
    }
  );

  console.log("CONTEXT_COUNTS", JSON.stringify({
    workoutSessionCount: capturedSummary.workoutSessionCount,
    exerciseEntryCount: capturedSummary.exerciseEntryCount,
    muscleGroupSessionFrequency: capturedSummary.muscleGroupSessionFrequency,
  }, null, 2));
  console.log("REGENERATED_INSIGHT\n" + result.insight);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
