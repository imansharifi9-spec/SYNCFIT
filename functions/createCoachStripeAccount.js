/**
 * Coach Stripe Connect Express onboarding.
 * Auth uid comes only from request.auth — never trust a client-supplied coachUid.
 */

const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { HttpsError } = require("firebase-functions/v2/https");
const Stripe = require("stripe");

const STRIPE_ONBOARDING_RETURN_URL = "syncfit://stripe-onboarding-return";
const STRIPE_ONBOARDING_REFRESH_URL =
  "syncfit://stripe-onboarding-return?refresh=1";

/**
 * @param {string} secretKey
 * @returns {import("stripe").Stripe}
 */
function createStripeClient(secretKey) {
  if (!secretKey || typeof secretKey !== "string") {
    throw new HttpsError(
      "failed-precondition",
      "Stripe is not configured (missing STRIPE_SECRET_KEY)."
    );
  }
  return new Stripe(secretKey);
}

/**
 * Create or reuse a Stripe Express connected account and return an Account Link URL.
 *
 * @param {string} coachUid Authenticated coach uid (request.auth.uid)
 * @param {object} [deps]
 * @returns {Promise<{ url: string, accountId: string, reused: boolean }>}
 */
async function createCoachStripeAccountForUid(coachUid, deps = {}) {
  if (!coachUid || typeof coachUid !== "string") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const db = deps.db || getFirestore();
  const getStripe =
    deps.getStripe ||
    (() => {
      throw new HttpsError(
        "failed-precondition",
        "Stripe is not configured (missing STRIPE_SECRET_KEY)."
      );
    });

  const coachRef = db.collection("coaches").doc(coachUid);
  const coachSnap = await coachRef.get();
  if (!coachSnap.exists) {
    throw new HttpsError(
      "permission-denied",
      "Only registered coaches can connect Stripe. No coaches/{uid} document found."
    );
  }

  const coachData = coachSnap.data() || {};
  // Defense-in-depth: coachId on the doc must match the auth uid when present.
  if (
    typeof coachData.coachId === "string" &&
    coachData.coachId.length > 0 &&
    coachData.coachId !== coachUid
  ) {
    throw new HttpsError(
      "permission-denied",
      "Coach document does not belong to the signed-in user."
    );
  }

  let accountId =
    typeof coachData.stripeConnectedAccountId === "string"
      ? coachData.stripeConnectedAccountId.trim()
      : "";
  let reused = false;
  const stripe = getStripe();

  if (accountId) {
    reused = true;
  } else {
    const account = await stripe.accounts.create({
      type: "express",
      country: "US",
      capabilities: {
        card_payments: { requested: true },
        transfers: { requested: true },
      },
      metadata: {
        firebaseUid: coachUid,
      },
    });
    accountId = account.id;
    await coachRef.set(
      {
        stripeConnectedAccountId: accountId,
        stripeChargesEnabled: false,
        stripePayoutsEnabled: false,
        stripeUpdatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
  }

  const accountLink = await stripe.accountLinks.create({
    account: accountId,
    refresh_url: STRIPE_ONBOARDING_REFRESH_URL,
    return_url: STRIPE_ONBOARDING_RETURN_URL,
    type: "account_onboarding",
  });

  if (!accountLink || typeof accountLink.url !== "string" || !accountLink.url) {
    throw new HttpsError(
      "internal",
      "Stripe Account Link creation returned no URL."
    );
  }

  return {
    url: accountLink.url,
    accountId,
    reused,
  };
}

module.exports = {
  STRIPE_ONBOARDING_RETURN_URL,
  STRIPE_ONBOARDING_REFRESH_URL,
  createStripeClient,
  createCoachStripeAccountForUid,
};
