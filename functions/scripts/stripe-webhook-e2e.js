#!/usr/bin/env node
/**
 * Local Stripe webhook e2e (emulator Firestore + signed account.updated).
 *
 * Requires:
 *   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080
 *   STRIPE_SECRET_KEY=sk_test_...   (optional if only verifying signature path with WHSEC)
 *   STRIPE_WEBHOOK_SECRET=whsec_... (from `stripe listen`, or a local test secret)
 *
 * Usage (with Firebase emulator already running firestore):
 *   STRIPE_WEBHOOK_SECRET=whsec_test node functions/scripts/stripe-webhook-e2e.js
 *
 * Or with Stripe CLI:
 *   stripe listen --forward-to http://127.0.0.1:8787/stripeWebhook
 *   # then in another terminal run this script with --serve and trigger:
 *   stripe trigger account.updated
 */

process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "syncfit-8441f";
process.env.GOOGLE_CLOUD_PROJECT =
  process.env.GOOGLE_CLOUD_PROJECT || "syncfit-8441f";

const http = require("http");
const admin = require("firebase-admin");
const Stripe = require("stripe");
const {
  stripeWebhookHandler,
  createStripeClient,
} = require("../stripeWebhook");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "syncfit-8441f" });
}

const db = admin.firestore();
const COACH_UID = process.env.E2E_COACH_UID || "stripe-e2e-coach";
const ACCOUNT_ID = process.env.E2E_ACCOUNT_ID || "acct_e2e_test_account";
const WEBHOOK_SECRET =
  process.env.STRIPE_WEBHOOK_SECRET || "whsec_local_e2e_test_secret";

function signPayload(payload, secret) {
  const stripe = new Stripe("sk_test_dummy_for_signing_only");
  // Prefer Stripe's generateTestHeaderString when available.
  if (
    stripe.webhooks &&
    typeof stripe.webhooks.generateTestHeaderString === "function"
  ) {
    return stripe.webhooks.generateTestHeaderString({
      payload,
      secret,
    });
  }
  const crypto = require("crypto");
  const timestamp = Math.floor(Date.now() / 1000);
  const signed = crypto
    .createHmac("sha256", secret)
    .update(`${timestamp}.${payload}`, "utf8")
    .digest("hex");
  return `t=${timestamp},v1=${signed}`;
}

async function seedCoach() {
  await db.collection("coaches").doc(COACH_UID).set(
    {
      coachId: COACH_UID,
      name: "Stripe E2E Coach",
      stripeConnectedAccountId: ACCOUNT_ID,
      stripeChargesEnabled: false,
      stripePayoutsEnabled: false,
    },
    { merge: true }
  );
}

async function runSignedLocalEvent() {
  await seedCoach();
  const event = {
    id: `evt_e2e_${Date.now()}`,
    object: "event",
    type: "account.updated",
    livemode: false,
    data: {
      object: {
        id: ACCOUNT_ID,
        object: "account",
        charges_enabled: true,
        payouts_enabled: true,
      },
    },
  };
  const payload = JSON.stringify(event);
  const signature = signPayload(payload, WEBHOOK_SECRET);

  const req = {
    method: "POST",
    headers: { "stripe-signature": signature },
    rawBody: Buffer.from(payload, "utf8"),
  };
  const res = {
    statusCode: 200,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    send(b) {
      this.body = b;
      return this;
    },
    json(b) {
      this.body = b;
      return this;
    },
  };

  await stripeWebhookHandler(req, res, {
    db,
    getStripe: () => createStripeClient(process.env.STRIPE_SECRET_KEY || "sk_test_dummy"),
    getWebhookSecret: () => WEBHOOK_SECRET,
  });

  const coach = await db.collection("coaches").doc(COACH_UID).get();
  const ledger = await db.collection("stripeWebhookEvents").doc(event.id).get();

  console.log("HTTP_STATUS", res.statusCode);
  console.log("RESPONSE", JSON.stringify(res.body));
  console.log(
    "COACH_DOC",
    JSON.stringify(
      {
        id: coach.id,
        stripeConnectedAccountId: coach.data()?.stripeConnectedAccountId,
        stripeChargesEnabled: coach.data()?.stripeChargesEnabled,
        stripePayoutsEnabled: coach.data()?.stripePayoutsEnabled,
      },
      null,
      2
    )
  );
  console.log("EVENT_LEDGER_EXISTS", ledger.exists);

  if (res.statusCode !== 200) process.exit(1);
  if (coach.data()?.stripeChargesEnabled !== true) process.exit(2);
  if (!ledger.exists) process.exit(3);
}

async function serve() {
  const port = Number(process.env.PORT || 8787);
  const server = http.createServer(async (req, res) => {
    if (req.method === "POST" && req.url === "/stripeWebhook") {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const rawBody = Buffer.concat(chunks);
      req.rawBody = rawBody;

      const expressResponse = {
        status(code) {
          res.statusCode = code;
          return this;
        },
        send(payload) {
          if (!res.headersSent) {
            res.setHeader("content-type", "text/plain; charset=utf-8");
          }
          res.end(String(payload));
          return this;
        },
        json(payload) {
          if (!res.headersSent) {
            res.setHeader("content-type", "application/json");
          }
          res.end(JSON.stringify(payload));
          return this;
        },
      };

      await stripeWebhookHandler(req, expressResponse, {
        db,
        getStripe: () =>
          createStripeClient(process.env.STRIPE_SECRET_KEY || "sk_test_dummy"),
        getWebhookSecret: () => WEBHOOK_SECRET,
      });
      return;
    }
    res.statusCode = 404;
    res.end("not found");
  });
  server.listen(port, "127.0.0.1", () => {
    console.log(`Listening on http://127.0.0.1:${port}/stripeWebhook`);
    console.log(
      `Forward with: stripe listen --forward-to http://127.0.0.1:${port}/stripeWebhook`
    );
  });
}

async function main() {
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    console.error("Set FIRESTORE_EMULATOR_HOST (e.g. 127.0.0.1:8080)");
    process.exit(1);
  }
  if (process.argv.includes("--serve")) {
    await seedCoach();
    await serve();
    return;
  }
  await runSignedLocalEvent();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
