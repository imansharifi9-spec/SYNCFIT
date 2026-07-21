/**
 * Coach↔client authorization for Cloud Functions.
 * Mirrors firestore.rules: isActiveCoachForClient + coachHasSharePermission.
 * Admin SDK bypasses rules — this is the server-side enforcement for AI tools.
 */

const { HttpsError } = require("firebase-functions/v2/https");

/**
 * Canonical connection doc id — same as CoachClientConnection.makeDocumentID /
 * firestore.rules connectionDocId.
 * @param {string} clientId
 * @param {string} coachId
 * @returns {string}
 */
function connectionDocId(clientId, coachId) {
  return clientId <= coachId
    ? `${clientId}_${coachId}`
    : `${coachId}_${clientId}`;
}

/**
 * Resolve share toggles from a coach_clients doc.
 * Prefers permissions map; falls back to legacy flat flags. Missing → false.
 * @param {object|null|undefined} data
 * @returns {{ workouts: boolean, nutrition: boolean, progress: boolean }}
 */
function resolveSharePermissions(data) {
  const raw = data && typeof data === "object" ? data : {};
  const permissions =
    raw.permissions && typeof raw.permissions === "object" && !Array.isArray(raw.permissions)
      ? raw.permissions
      : null;

  return {
    workouts:
      (permissions && permissions.workouts === true) ||
      raw.shareWorkouts === true,
    nutrition:
      (permissions && permissions.nutrition === true) ||
      raw.shareNutrition === true,
    progress:
      (permissions && permissions.progress === true) ||
      raw.shareProgress === true,
  };
}

/**
 * Verify the signed-in coach is an active coach for clientUid.
 * Throws permission-denied / not-found on failure.
 *
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} coachUid request.auth.uid
 * @param {string} clientUid
 * @returns {Promise<{
 *   connectionId: string,
 *   connection: object,
 *   permissions: { workouts: boolean, nutrition: boolean, progress: boolean }
 * }>}
 */
async function assertActiveCoachForClient(db, coachUid, clientUid) {
  if (!coachUid || typeof coachUid !== "string") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  if (!clientUid || typeof clientUid !== "string" || !clientUid.trim()) {
    throw new HttpsError("invalid-argument", "clientUserID is required.");
  }
  const trimmedClient = clientUid.trim();
  if (trimmedClient === coachUid) {
    throw new HttpsError(
      "invalid-argument",
      "clientUserID must refer to a client, not the coach."
    );
  }

  const connectionId = connectionDocId(trimmedClient, coachUid);
  const snap = await db.collection("coach_clients").doc(connectionId).get();
  if (!snap.exists) {
    throw new HttpsError(
      "permission-denied",
      "Not an authorized coach for this client."
    );
  }

  const connection = snap.data() || {};
  if (connection.coachId !== coachUid) {
    throw new HttpsError(
      "permission-denied",
      "Not an authorized coach for this client."
    );
  }

  const status = connection.status;
  if (status != null && status !== "active") {
    throw new HttpsError(
      "permission-denied",
      "Coach connection is not active for this client."
    );
  }

  const clientMatches =
    connection.clientUserID === trimmedClient ||
    connection.clientId === trimmedClient;
  if (!clientMatches) {
    throw new HttpsError(
      "permission-denied",
      "Not an authorized coach for this client."
    );
  }

  return {
    connectionId,
    connection,
    permissions: resolveSharePermissions(connection),
  };
}

module.exports = {
  connectionDocId,
  resolveSharePermissions,
  assertActiveCoachForClient,
};
