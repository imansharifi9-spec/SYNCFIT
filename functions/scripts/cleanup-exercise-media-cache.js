/**
 * One-time cleanup for bad exerciseMedia cache entries.
 * Usage:
 *   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 node scripts/cleanup-exercise-media-cache.js
 *   # or against production (requires ADC / firebase login):
 *   node scripts/cleanup-exercise-media-cache.js
 */

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "syncfit-8441f";
process.env.GOOGLE_CLOUD_PROJECT =
  process.env.GOOGLE_CLOUD_PROJECT || "syncfit-8441f";

const admin = require("firebase-admin");
const {
  cleanupMismatchedExerciseMediaCache,
  MEDIA_LOGIC_VERSION,
  MIN_REASONABLE_SCORE,
} = require("../resolveExerciseMedia");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "syncfit-8441f" });
}

async function main() {
  const db = admin.firestore();
  const faceRef = db.collection("exerciseMedia").doc("face_pull");
  const before = await faceRef.get();
  console.log(
    JSON.stringify({
      facePullBefore: before.exists ? before.data() : null,
      mediaLogicVersion: MEDIA_LOGIC_VERSION,
      minReasonableScore: MIN_REASONABLE_SCORE,
    })
  );

  // Force-clear the known-bad Face Pull entry for end-to-end verification.
  await faceRef.delete().catch(() => {});

  const result = await cleanupMismatchedExerciseMediaCache({ db });
  const after = await faceRef.get();
  console.log(
    JSON.stringify(
      {
        cleanup: result,
        facePullAfterExists: after.exists,
        mediaLogicVersion: MEDIA_LOGIC_VERSION,
        minReasonableScore: MIN_REASONABLE_SCORE,
      },
      null,
      2
    )
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
