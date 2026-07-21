/**
 * Stripe Connect webhook — signature-verified account.updated → coach flags.
 */

const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const Stripe = require("stripe");

/**
 * @param {string} secretKey
 * @returns {import("stripe").Stripe}
 */
function createStripeClient(secretKey) {
  return new Stripe(secretKey);
}

/**
 * Process a verified Stripe event.
 *
 * @param {import("stripe").Stripe.Event} event
 * @param {object} [deps]
 * @returns {Promise<{ handled: boolean, duplicate?: boolean, coachUid?: string|null }>}
 */
async function handleStripeEvent(event, deps = {}) {
  const db = deps.db || getFirestore();
  const logger = deps.logger || console;
  if (!event || typeof event.id !== "string" || !event.id) {
    const err = new Error("Stripe event missing id.");
    err.statusCode = 400;
    throw err;
  }

  const eventRef = db.collection("stripeWebhookEvents").doc(event.id);
  const existing = await eventRef.get();
  if (existing.exists) {
    return { handled: false, duplicate: true };
  }

  let coachUid = null;

  if (event.type === "account.updated") {
    const account = event.data && event.data.object;
    const accountId = account && typeof account.id === "string" ? account.id : "";
    if (!accountId) {
      const err = new Error("account.updated missing account id.");
      err.statusCode = 400;
      throw err;
    }

    const chargesEnabled = account.charges_enabled === true;
    const payoutsEnabled = account.payouts_enabled === true;

    const snap = await db
      .collection("coaches")
      .where("stripeConnectedAccountId", "==", accountId)
      .limit(1)
      .get();

    if (!snap.empty) {
      const coachDoc = snap.docs[0];
      coachUid = coachDoc.id;
      await coachDoc.ref.set(
        {
          stripeChargesEnabled: chargesEnabled,
          stripePayoutsEnabled: payoutsEnabled,
          stripeUpdatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    } else {
      logger.warn(
        `[stripeWebhook] No coach found for stripeConnectedAccountId=${accountId}`
      );
    }
  }

  await eventRef.set({
    id: event.id,
    type: event.type || null,
    processedAt: FieldValue.serverTimestamp(),
    livemode: event.livemode === true,
    coachUid: coachUid,
  });

  return { handled: true, duplicate: false, coachUid };
}

/**
 * Express/Cloud Functions request handler.
 * Expects req.rawBody (Buffer) for signature verification.
 *
 * @param {object} req
 * @param {object} res
 * @param {object} [deps]
 */
async function stripeWebhookHandler(req, res, deps = {}) {
  if (req.method !== "POST") {
    res.status(405).send("Method Not Allowed");
    return;
  }

  const getStripe =
    deps.getStripe ||
    (() => {
      throw Object.assign(new Error("Stripe is not configured."), {
        statusCode: 500,
      });
    });
  const getWebhookSecret =
    deps.getWebhookSecret ||
    (() => {
      throw Object.assign(new Error("Stripe webhook secret is not configured."), {
        statusCode: 500,
      });
    });

  const signature = req.headers["stripe-signature"];
  if (!signature) {
    res.status(400).send("Missing Stripe-Signature header.");
    return;
  }

  const rawBody = req.rawBody;
  if (!rawBody) {
    res.status(400).send("Missing raw request body.");
    return;
  }

  let event;
  try {
    const stripe = getStripe();
    const webhookSecret = getWebhookSecret();
    event = stripe.webhooks.constructEvent(rawBody, signature, webhookSecret);
  } catch (err) {
    console.warn("[stripeWebhook] Signature verification failed:", err.message);
    res.status(400).send(`Webhook Error: ${err.message}`);
    return;
  }

  try {
    const result = await handleStripeEvent(event, deps);
    res.status(200).json({
      received: true,
      duplicate: Boolean(result.duplicate),
      handled: Boolean(result.handled),
    });
  } catch (err) {
    console.error("[stripeWebhook] Handler failed:", err);
    const status = err.statusCode || 500;
    res.status(status).send(err.message || "Webhook handler failed.");
  }
}

module.exports = {
  createStripeClient,
  handleStripeEvent,
  stripeWebhookHandler,
};
