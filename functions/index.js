const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp, getApps } = require("firebase-admin/app");
const {
  createCoachStripeAccountForUid,
  createStripeClient,
} = require("./createCoachStripeAccount");
const {
  stripeWebhookHandler,
  createStripeClient: createStripeWebhookClient,
} = require("./stripeWebhook");

if (!getApps().length) {
  initializeApp({
    projectId:
      process.env.GCLOUD_PROJECT ||
      process.env.GOOGLE_CLOUD_PROJECT ||
      "syncfit-8441f",
  });
}

const stripeSecretKey = defineSecret("STRIPE_SECRET_KEY");
const stripeWebhookSecret = defineSecret("STRIPE_WEBHOOK_SECRET");

const createCoachStripeAccount = onCall(
  {
    secrets: [stripeSecretKey],
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in required to connect Stripe."
      );
    }

    return createCoachStripeAccountForUid(request.auth.uid, {
      getStripe: () => createStripeClient(stripeSecretKey.value()),
    });
  }
);

const stripeWebhook = onRequest(
  {
    secrets: [stripeSecretKey, stripeWebhookSecret],
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async (req, res) => {
    await stripeWebhookHandler(req, res, {
      getStripe: () => createStripeWebhookClient(stripeSecretKey.value()),
      getWebhookSecret: () => stripeWebhookSecret.value(),
    });
  }
);

module.exports = {
  createCoachStripeAccount,
  createCoachStripeAccountForUid,
  stripeWebhook,
};
