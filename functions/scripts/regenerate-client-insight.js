#!/usr/bin/env node
/**
 * Regenerate a coach's cached client insight (forceRefresh) against production Firestore.
 *
 * Usage:
 *   ANTHROPIC_API_KEY=sk-... node functions/scripts/regenerate-client-insight.js <coachUid> <clientUid>
 *
 * Requires Application Default Credentials for syncfit-8441f (gcloud auth application-default login).
 */

const admin = require("firebase-admin");
const {
  generateClientInsightsForUid,
} = require("../generateClientInsights");
const { loadSharedClientTrainingContext } = require("../trainingContext");
const { assertActiveCoachForClient } = require("../coachClientAccess");

const projectId = process.env.GCLOUD_PROJECT || "syncfit-8441f";

if (!admin.apps.length) {
  admin.initializeApp({ projectId });
}

const db = admin.firestore();

async function main() {
  const coachUid = process.argv[2];
  const clientUid = process.argv[3];
  if (!coachUid || !clientUid) {
    console.error(
      "Usage: node functions/scripts/regenerate-client-insight.js <coachUid> <clientUid>"
    );
    process.exit(1);
  }

  const { permissions } = await assertActiveCoachForClient(db, coachUid, clientUid);
  const summary = await loadSharedClientTrainingContext(clientUid, permissions, { db });
  console.log("--- Context counts sent to Claude ---");
  console.log(
    JSON.stringify(
      {
        workoutSessionCount: summary.workoutSessionCount,
        workoutCount: summary.workoutCount,
        exerciseEntryCount: summary.exerciseEntryCount,
        muscleGroupSessionFrequency: summary.muscleGroupSessionFrequency,
        mealCount: summary.mealCount,
        weightCount: summary.weightCount,
      },
      null,
      2
    )
  );

  const getApiKey = () => {
    const key = process.env.ANTHROPIC_API_KEY;
    if (!key) {
      throw new Error("Set ANTHROPIC_API_KEY to call Claude.");
    }
    return key;
  };

  const result = await generateClientInsightsForUid(
    coachUid,
    { clientUserID: clientUid, forceRefresh: true },
    { db, getApiKey, cacheTtlMs: 0 }
  );

  console.log("\n--- Regenerated insight ---");
  console.log(result.insight);
  console.log("\n--- Meta ---");
  console.log(JSON.stringify({ cached: result.cached, generatedAt: result.generatedAt }, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
