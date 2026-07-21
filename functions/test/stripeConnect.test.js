/**
 * Emulator tests for Stripe Connect Express coach onboarding + webhook.
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "syncfit-8441f";
process.env.GOOGLE_CLOUD_PROJECT =
  process.env.GOOGLE_CLOUD_PROJECT || "syncfit-8441f";

const fs = require("fs");
const path = require("path");
const { expect } = require("chai");
const admin = require("firebase-admin");
const { HttpsError } = require("firebase-functions/v2/https");
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require("@firebase/rules-unit-testing");
const { doc, setDoc, updateDoc } = require("firebase/firestore");

const {
  createCoachStripeAccountForUid,
} = require("../createCoachStripeAccount");
const {
  handleStripeEvent,
  stripeWebhookHandler,
} = require("../stripeWebhook");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "syncfit-8441f" });
}

const db = admin.firestore();

async function clearDocTree(ref) {
  await admin.firestore().recursiveDelete(ref);
}

function makeMockStripe({ existingAccountId } = {}) {
  const state = {
    accountsCreated: 0,
    linksCreated: 0,
    lastAccountCreate: null,
  };

  return {
    state,
    stripe: {
      accounts: {
        create: async (params) => {
          state.accountsCreated += 1;
          state.lastAccountCreate = params;
          return {
            id: existingAccountId || `acct_test_${state.accountsCreated}`,
            type: "express",
            country: params.country,
          };
        },
      },
      accountLinks: {
        create: async (params) => {
          state.linksCreated += 1;
          return {
            url: `https://connect.stripe.com/setup/test/${params.account}`,
            object: "account_link",
          };
        },
      },
      webhooks: {
        constructEvent: (rawBody, signature, secret) => {
          if (!signature || signature === "bad") {
            throw new Error("Invalid signature");
          }
          if (secret !== "whsec_test") {
            throw new Error("Invalid webhook secret");
          }
          return JSON.parse(
            Buffer.isBuffer(rawBody) ? rawBody.toString("utf8") : String(rawBody)
          );
        },
      },
    },
  };
}

describe("createCoachStripeAccount", function () {
  this.timeout(20000);

  before(function () {
    if (!process.env.FIRESTORE_EMULATOR_HOST) {
      throw new Error("FIRESTORE_EMULATOR_HOST is not set");
    }
  });

  beforeEach(async function () {
    await clearDocTree(db.collection("coaches").doc("coach-stripe-a"));
    await clearDocTree(db.collection("coaches").doc("not-a-coach"));
  });

  it("rejects a caller whose uid has no coaches/{uid} document", async function () {
    const { stripe, state } = makeMockStripe();
    try {
      await createCoachStripeAccountForUid("not-a-coach", {
        db,
        getStripe: () => stripe,
      });
      expect.fail("expected permission-denied");
    } catch (err) {
      expect(err).to.be.instanceOf(HttpsError);
      expect(err.code).to.equal("permission-denied");
      expect(state.accountsCreated).to.equal(0);
    }
  });

  it("creates a Stripe Express account and returns an Account Link URL", async function () {
    await db.collection("coaches").doc("coach-stripe-a").set({
      coachId: "coach-stripe-a",
      name: "Test Coach",
    });

    const { stripe, state } = makeMockStripe();
    const result = await createCoachStripeAccountForUid("coach-stripe-a", {
      db,
      getStripe: () => stripe,
    });

    expect(state.accountsCreated).to.equal(1);
    expect(state.lastAccountCreate).to.deep.include({
      type: "express",
      country: "US",
    });
    expect(state.lastAccountCreate.capabilities).to.deep.equal({
      card_payments: { requested: true },
      transfers: { requested: true },
    });
    expect(result.reused).to.equal(false);
    expect(result.accountId).to.match(/^acct_test_/);
    expect(result.url).to.include(result.accountId);

    const saved = await db.collection("coaches").doc("coach-stripe-a").get();
    expect(saved.data().stripeConnectedAccountId).to.equal(result.accountId);
    expect(saved.data().stripeChargesEnabled).to.equal(false);
  });

  it("is idempotent — second call reuses existing account ID", async function () {
    await db.collection("coaches").doc("coach-stripe-a").set({
      coachId: "coach-stripe-a",
      name: "Test Coach",
      stripeConnectedAccountId: "acct_existing_123",
    });

    const { stripe, state } = makeMockStripe();
    const first = await createCoachStripeAccountForUid("coach-stripe-a", {
      db,
      getStripe: () => stripe,
    });
    const second = await createCoachStripeAccountForUid("coach-stripe-a", {
      db,
      getStripe: () => stripe,
    });

    expect(state.accountsCreated).to.equal(0);
    expect(state.linksCreated).to.equal(2);
    expect(first.accountId).to.equal("acct_existing_123");
    expect(second.accountId).to.equal("acct_existing_123");
    expect(first.reused).to.equal(true);
    expect(second.reused).to.equal(true);
  });
});

describe("stripeWebhook", function () {
  this.timeout(20000);

  beforeEach(async function () {
    await clearDocTree(db.collection("coaches").doc("coach-stripe-b"));
    await clearDocTree(db.collection("stripeWebhookEvents").doc("evt_test_1"));
    await clearDocTree(db.collection("stripeWebhookEvents").doc("evt_test_dup"));
    await clearDocTree(db.collection("stripeWebhookEvents").doc("evt_test_unknown"));
  });

  function mockRes() {
    const res = {
      statusCode: 200,
      body: null,
      status(code) {
        this.statusCode = code;
        return this;
      },
      send(payload) {
        this.body = payload;
        return this;
      },
      json(payload) {
        this.body = payload;
        return this;
      },
    };
    return res;
  }

  it("rejects a request with an invalid/missing signature", async function () {
    const { stripe } = makeMockStripe();
    const res = mockRes();
    await stripeWebhookHandler(
      {
        method: "POST",
        headers: {},
        rawBody: Buffer.from("{}"),
      },
      res,
      {
        db,
        getStripe: () => stripe,
        getWebhookSecret: () => "whsec_test",
      }
    );
    expect(res.statusCode).to.equal(400);
    expect(String(res.body)).to.match(/Stripe-Signature/i);

    const res2 = mockRes();
    await stripeWebhookHandler(
      {
        method: "POST",
        headers: { "stripe-signature": "bad" },
        rawBody: Buffer.from("{}"),
      },
      res2,
      {
        db,
        getStripe: () => stripe,
        getWebhookSecret: () => "whsec_test",
      }
    );
    expect(res2.statusCode).to.equal(400);
  });

  it("updates stripeChargesEnabled on a valid account.updated event", async function () {
    await db.collection("coaches").doc("coach-stripe-b").set({
      coachId: "coach-stripe-b",
      stripeConnectedAccountId: "acct_live_test_b",
      stripeChargesEnabled: false,
      stripePayoutsEnabled: false,
    });

    const event = {
      id: "evt_test_1",
      type: "account.updated",
      livemode: false,
      data: {
        object: {
          id: "acct_live_test_b",
          charges_enabled: true,
          payouts_enabled: true,
        },
      },
    };

    const result = await handleStripeEvent(event, { db });
    expect(result.handled).to.equal(true);
    expect(result.coachUid).to.equal("coach-stripe-b");

    const coach = await db.collection("coaches").doc("coach-stripe-b").get();
    expect(coach.data().stripeChargesEnabled).to.equal(true);
    expect(coach.data().stripePayoutsEnabled).to.equal(true);

    const ledger = await db.collection("stripeWebhookEvents").doc("evt_test_1").get();
    expect(ledger.exists).to.equal(true);
  });

  it("logs and ignores account.updated for an unmatched account without writing a coach connection", async function () {
    await db.collection("coaches").doc("coach-stripe-b").set({
      coachId: "coach-stripe-b",
      stripeConnectedAccountId: "acct_known_unchanged",
      stripeChargesEnabled: false,
      stripePayoutsEnabled: false,
    });
    const coachesBefore = await db.collection("coaches").get();
    const warnings = [];
    const event = {
      id: "evt_test_unknown",
      type: "account.updated",
      livemode: false,
      data: {
        object: {
          id: "acct_unmatched_never_map",
          charges_enabled: true,
          payouts_enabled: true,
        },
      },
    };

    const result = await handleStripeEvent(event, {
      db,
      logger: { warn: (message) => warnings.push(message) },
    });

    expect(result).to.deep.include({
      handled: true,
      duplicate: false,
      coachUid: null,
    });
    expect(warnings).to.deep.equal([
      "[stripeWebhook] No coach found for stripeConnectedAccountId=acct_unmatched_never_map",
    ]);

    const coachesAfter = await db.collection("coaches").get();
    expect(coachesAfter.size).to.equal(coachesBefore.size);
    const unmatched = await db
      .collection("coaches")
      .where("stripeConnectedAccountId", "==", "acct_unmatched_never_map")
      .get();
    expect(unmatched.empty).to.equal(true);

    const knownCoach = await db.collection("coaches").doc("coach-stripe-b").get();
    expect(knownCoach.data()).to.deep.include({
      stripeConnectedAccountId: "acct_known_unchanged",
      stripeChargesEnabled: false,
      stripePayoutsEnabled: false,
    });
  });

  it("ignores a duplicate event.id on redelivery", async function () {
    await db.collection("coaches").doc("coach-stripe-b").set({
      coachId: "coach-stripe-b",
      stripeConnectedAccountId: "acct_live_test_b",
      stripeChargesEnabled: false,
      stripePayoutsEnabled: false,
    });

    const event = {
      id: "evt_test_dup",
      type: "account.updated",
      livemode: false,
      data: {
        object: {
          id: "acct_live_test_b",
          charges_enabled: true,
          payouts_enabled: false,
        },
      },
    };

    const first = await handleStripeEvent(event, { db });
    expect(first.handled).to.equal(true);

    // Flip flags so a re-process would be visible if not deduped.
    await db.collection("coaches").doc("coach-stripe-b").set(
      {
        stripeChargesEnabled: false,
        stripePayoutsEnabled: false,
      },
      { merge: true }
    );

    const second = await handleStripeEvent(event, { db });
    expect(second.duplicate).to.equal(true);
    expect(second.handled).to.equal(false);

    const coach = await db.collection("coaches").doc("coach-stripe-b").get();
    expect(coach.data().stripeChargesEnabled).to.equal(false);
  });
});

describe("Firestore rules — Stripe fields", function () {
  this.timeout(20000);

  let testEnv;

  before(async function () {
    const [host, portRaw] = process.env.FIRESTORE_EMULATOR_HOST.split(":");
    testEnv = await initializeTestEnvironment({
      projectId: "syncfit-8441f-stripe-rules",
      firestore: {
        host,
        port: Number(portRaw),
        rules: fs.readFileSync(
          path.join(__dirname, "../../firestore.rules"),
          "utf8"
        ),
      },
    });
  });

  after(async function () {
    await testEnv.cleanup();
  });

  beforeEach(async function () {
    await testEnv.clearFirestore();
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const adminDb = context.firestore();
      await setDoc(doc(adminDb, "coaches/coach-rules-a"), {
        coachId: "coach-rules-a",
        name: "Rules Coach",
        stripeConnectedAccountId: "acct_rules",
        stripeChargesEnabled: false,
        stripePayoutsEnabled: false,
      });
    });
  });

  it("denies a client-side write to stripeChargesEnabled", async function () {
    const dbClient = testEnv.authenticatedContext("coach-rules-a").firestore();
    await assertFails(
      updateDoc(doc(dbClient, "coaches/coach-rules-a"), {
        stripeChargesEnabled: true,
      })
    );
  });

  it("denies client create that includes stripeConnectedAccountId", async function () {
    const dbClient = testEnv.authenticatedContext("coach-rules-b").firestore();
    await assertFails(
      setDoc(doc(dbClient, "coaches/coach-rules-b"), {
        coachId: "coach-rules-b",
        name: "New Coach",
        stripeConnectedAccountId: "acct_forged",
      })
    );
  });

  it("allows a coach to update non-Stripe profile fields", async function () {
    const dbClient = testEnv.authenticatedContext("coach-rules-a").firestore();
    await assertSucceeds(
      updateDoc(doc(dbClient, "coaches/coach-rules-a"), {
        name: "Updated Name",
      })
    );
  });

  it("denies all client access to stripeWebhookEvents", async function () {
    const dbClient = testEnv.authenticatedContext("coach-rules-a").firestore();
    await assertFails(
      setDoc(doc(dbClient, "stripeWebhookEvents/evt_x"), { id: "evt_x" })
    );
  });
});
