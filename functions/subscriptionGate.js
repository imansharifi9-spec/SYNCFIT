/**
 * Firestore-backed SyncFit+ entitlement gate used by callables and AI features.
 */

const { getFirestore } = require("firebase-admin/firestore");
const { HttpsError } = require("firebase-functions/v2/https");
const { evaluateSubscriptionEntitlement } = require("./entitlement");

/**
 * Reads users/{uid} and evaluates entitlement.
 *
 * @param {string} uid
 * @returns {Promise<{ entitled: boolean, reason: string }>}
 */
async function checkSubscriptionEntitlementForUid(uid) {
  if (!uid || typeof uid !== "string") {
    throw new HttpsError("invalid-argument", "uid is required.");
  }

  const snap = await getFirestore().collection("users").doc(uid).get();
  const data = snap.exists ? snap.data() || {} : {};

  const result = evaluateSubscriptionEntitlement({
    subscriptionStatus: data.subscriptionStatus,
    subscriptionExpiresAt: data.subscriptionExpiresAt,
  });

  if (result.staleActive) {
    const expiresRaw = data.subscriptionExpiresAt;
    const expiresLabel =
      expiresRaw && typeof expiresRaw.toDate === "function"
        ? expiresRaw.toDate().toISOString()
        : String(expiresRaw);
    console.warn(
      `[SubscriptionGate] STALE ACTIVE entitlement uid=${uid} ` +
        `subscriptionStatus=active but subscriptionExpiresAt is in the past ` +
        `(expiresAt=${expiresLabel}) — denying until StoreKit sync corrects the field`
    );
  }

  console.log(
    `[SubscriptionGate] uid=${uid} entitled=${result.entitled} reason=${result.reason}`
  );

  return {
    entitled: result.entitled,
    reason: result.reason,
  };
}

module.exports = {
  checkSubscriptionEntitlementForUid,
};
