/**
 * Stripe Checkout for hiring a coach.
 * Pricing, destination account, and platform fee are always resolved server-side.
 */

const { getFirestore } = require("firebase-admin/firestore");
const { HttpsError } = require("firebase-functions/v2/https");

const DEFAULT_PLATFORM_FEE_PERCENT = 20;
const CHECKOUT_SUCCESS_URL =
  "syncfit://coach-checkout-success?session_id={CHECKOUT_SESSION_ID}";
const CHECKOUT_CANCEL_URL = "syncfit://coach-checkout-cancel";
const NON_TERMINAL_SUBSCRIPTION_STATUSES = new Set([
  "active",
  "trialing",
  "past_due",
  "unpaid",
  "incomplete",
  "paused",
]);

function resolvePlatformFeePercent(coachData) {
  const value =
    coachData && coachData.platformFeePercent !== undefined
      ? coachData.platformFeePercent
      : DEFAULT_PLATFORM_FEE_PERCENT;
  if (!Number.isInteger(value) || value < 0 || value > 100) {
    throw new HttpsError(
      "failed-precondition",
      "Coach platform fee must be an integer from 0 through 100."
    );
  }
  return value;
}

function validStripeAccountId(value) {
  return typeof value === "string" && /^acct_[A-Za-z0-9]+$/.test(value);
}

function validMonthlyPriceCents(value) {
  return Number.isInteger(value) && value > 0 && value <= 99999999;
}

/**
 * Coach docs store `pricePerMonth` as whole dollars (UI: "$75/month").
 * Stripe Checkout needs cents.
 */
function resolveMonthlyPriceCents(coachData) {
  const dollars = coachData && coachData.pricePerMonth;
  if (!Number.isInteger(dollars) || dollars <= 0 || dollars > 9999) {
    throw new HttpsError(
      "failed-precondition",
      "Coach monthly price is invalid."
    );
  }
  const cents = dollars * 100;
  if (!validMonthlyPriceCents(cents)) {
    throw new HttpsError(
      "failed-precondition",
      "Coach monthly price is invalid."
    );
  }
  return cents;
}

async function hasDuplicateActiveSubscription(db, clientUid, coachUid) {
  const snapshot = await db
    .collection("coachSubscriptions")
    .where("clientUid", "==", clientUid)
    .get();
  return snapshot.docs.some((doc) => {
    const subscription = doc.data();
    return (
      subscription.coachUid === coachUid &&
      NON_TERMINAL_SUBSCRIPTION_STATUSES.has(subscription.status)
    );
  });
}

/**
 * @param {string} clientUid authenticated client uid
 * @param {object} data callable request data; only coachUid is consumed
 * @param {object} [deps]
 */
async function createCheckoutSessionForUid(clientUid, data, deps = {}) {
  if (!clientUid || typeof clientUid !== "string") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const coachUid =
    data && typeof data.coachUid === "string" ? data.coachUid.trim() : "";
  if (!coachUid) {
    throw new HttpsError("invalid-argument", "coachUid is required.");
  }
  if (clientUid === coachUid) {
    throw new HttpsError(
      "failed-precondition",
      "A coach cannot hire their own coaching profile."
    );
  }

  const db = deps.db || getFirestore();
  const coachSnap = await db.collection("coaches").doc(coachUid).get();
  if (!coachSnap.exists) {
    throw new HttpsError("not-found", "Coach not found.");
  }

  const coachData = coachSnap.data() || {};
  if (coachData.stripeChargesEnabled !== true) {
    throw new HttpsError(
      "failed-precondition",
      "This coach is not ready to accept payments."
    );
  }
  if (!validStripeAccountId(coachData.stripeConnectedAccountId)) {
    throw new HttpsError(
      "failed-precondition",
      "Coach Stripe account is not configured."
    );
  }
  const monthlyPriceCents = resolveMonthlyPriceCents(coachData);

  const platformFeePercent = resolvePlatformFeePercent(coachData);
  if (await hasDuplicateActiveSubscription(db, clientUid, coachUid)) {
    throw new HttpsError(
      "already-exists",
      "You already have an active subscription with this coach."
    );
  }

  const getStripe =
    deps.getStripe ||
    (() => {
      throw new HttpsError(
        "failed-precondition",
        "Stripe is not configured (missing STRIPE_SECRET_KEY)."
      );
    });
  const stripe = getStripe();
  const metadata = {
    clientUid,
    coachUid,
    platformFeePercent: String(platformFeePercent),
  };
  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    line_items: [
      {
        quantity: 1,
        price_data: {
          currency: "usd",
          unit_amount: monthlyPriceCents,
          recurring: { interval: "month" },
          product_data: {
            name:
              typeof coachData.name === "string" && coachData.name.trim()
                ? `${coachData.name.trim()} Coaching`
                : "SyncFit Coaching",
          },
        },
      },
    ],
    subscription_data: {
      application_fee_percent: platformFeePercent,
      transfer_data: {
        destination: coachData.stripeConnectedAccountId,
      },
      metadata,
    },
    success_url: CHECKOUT_SUCCESS_URL,
    cancel_url: CHECKOUT_CANCEL_URL,
    metadata,
  });

  if (!session || typeof session.url !== "string" || !session.url) {
    throw new HttpsError("internal", "Stripe Checkout returned no URL.");
  }
  return { url: session.url, sessionId: session.id };
}

module.exports = {
  DEFAULT_PLATFORM_FEE_PERCENT,
  CHECKOUT_SUCCESS_URL,
  CHECKOUT_CANCEL_URL,
  resolvePlatformFeePercent,
  validStripeAccountId,
  validMonthlyPriceCents,
  resolveMonthlyPriceCents,
  createCheckoutSessionForUid,
};
