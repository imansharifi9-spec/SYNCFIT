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
const {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
} = require("firebase/firestore");

const {
  createCoachStripeAccountForUid,
} = require("../createCoachStripeAccount");
const {
  handleStripeEvent,
  stripeWebhookHandler,
} = require("../stripeWebhook");
const {
  createCheckoutSessionForUid,
  DEFAULT_PLATFORM_FEE_PERCENT,
} = require("../createCheckoutSession");
const { connectionDocId } = require("../coachClientAccess");

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

describe("createCheckoutSession", function () {
  this.timeout(20000);

  const coachUid = "coach-checkout";
  const clientUid = "client-checkout";

  beforeEach(async function () {
    await clearDocTree(db.collection("coaches").doc(coachUid));
    await clearDocTree(db.collection("coachSubscriptions"));
    await db.collection("coaches").doc(coachUid).set({
      coachId: coachUid,
      name: "Checkout Coach",
      stripeConnectedAccountId: "acct_checkout123",
      stripeChargesEnabled: true,
      pricePerMonth: 125,
    });
  });

  function checkoutStripe() {
    const state = { payloads: [] };
    return {
      state,
      stripe: {
        checkout: {
          sessions: {
            create: async (payload) => {
              state.payloads.push(payload);
              return {
                id: `cs_test_${state.payloads.length}`,
                url: "https://checkout.stripe.test/session",
              };
            },
          },
        },
      },
    };
  }

  it("requires an authenticated client uid", async function () {
    const { stripe } = checkoutStripe();
    try {
      await createCheckoutSessionForUid("", { coachUid }, {
        db,
        getStripe: () => stripe,
      });
      expect.fail("expected unauthenticated");
    } catch (err) {
      expect(err).to.be.instanceOf(HttpsError);
      expect(err.code).to.equal("unauthenticated");
    }
  });

  it("rejects checkout when coach charges are disabled", async function () {
    await db.collection("coaches").doc(coachUid).set(
      { stripeChargesEnabled: false },
      { merge: true }
    );
    const { stripe, state } = checkoutStripe();
    try {
      await createCheckoutSessionForUid(clientUid, { coachUid }, {
        db,
        getStripe: () => stripe,
      });
      expect.fail("expected failed-precondition");
    } catch (err) {
      expect(err).to.be.instanceOf(HttpsError);
      expect(err.code).to.equal("failed-precondition");
      expect(state.payloads).to.have.length(0);
    }
  });

  it("rejects a duplicate non-terminal client-coach subscription", async function () {
    await db.collection("coachSubscriptions").doc("sub_duplicate").set({
      clientUid,
      coachUid,
      stripeSubscriptionId: "sub_duplicate",
      status: "active",
    });
    const { stripe, state } = checkoutStripe();
    try {
      await createCheckoutSessionForUid(clientUid, { coachUid }, {
        db,
        getStripe: () => stripe,
      });
      expect.fail("expected already-exists");
    } catch (err) {
      expect(err).to.be.instanceOf(HttpsError);
      expect(err.code).to.equal("already-exists");
      expect(state.payloads).to.have.length(0);
    }
  });

  it("ignores caller price/account/fee and defaults the actual Stripe fee to 20", async function () {
    const { stripe, state } = checkoutStripe();
    const result = await createCheckoutSessionForUid(
      clientUid,
      {
        coachUid,
        pricePerMonth: 1,
        monthlyPriceCents: 1,
        stripeConnectedAccountId: "acct_attacker",
        platformFeePercent: 0,
      },
      { db, getStripe: () => stripe }
    );

    expect(result.url).to.equal("https://checkout.stripe.test/session");
    expect(DEFAULT_PLATFORM_FEE_PERCENT).to.equal(20);
    const payload = state.payloads[0];
    expect(payload.line_items[0].price_data.unit_amount).to.equal(12500);
    expect(payload.subscription_data.transfer_data.destination).to.equal(
      "acct_checkout123"
    );
    expect(payload.subscription_data.application_fee_percent).to.equal(20);
    expect(payload.metadata.platformFeePercent).to.equal("20");
    expect(payload.subscription_data.metadata).to.deep.equal(payload.metadata);
    expect(payload.success_url).to.equal(
      "syncfit://coach-checkout-success?session_id={CHECKOUT_SESSION_ID}"
    );
    expect(payload.cancel_url).to.equal("syncfit://coach-checkout-cancel");
  });

  it("uses a custom server-side 15 percent fee in the actual Stripe payload", async function () {
    await db.collection("coaches").doc(coachUid).set(
      { platformFeePercent: 15 },
      { merge: true }
    );
    const { stripe, state } = checkoutStripe();
    await createCheckoutSessionForUid(clientUid, { coachUid }, {
      db,
      getStripe: () => stripe,
    });

    expect(state.payloads[0].subscription_data.application_fee_percent).to.equal(
      15
    );
    expect(state.payloads[0].metadata.platformFeePercent).to.equal("15");
  });

  it("rejects a non-integer or out-of-range server platform fee", async function () {
    const { stripe, state } = checkoutStripe();
    for (const invalidFee of [10.5, -1, 101]) {
      await db.collection("coaches").doc(coachUid).set(
        { platformFeePercent: invalidFee },
        { merge: true }
      );
      try {
        await createCheckoutSessionForUid(clientUid, { coachUid }, {
          db,
          getStripe: () => stripe,
        });
        expect.fail(`expected invalid fee ${invalidFee} to fail`);
      } catch (err) {
        expect(err).to.be.instanceOf(HttpsError);
        expect(err.code).to.equal("failed-precondition");
      }
    }
    expect(state.payloads).to.have.length(0);
  });
});

describe("stripeWebhook — coach subscriptions", function () {
  this.timeout(20000);

  const coachUid = "coach-webhook-sub";
  const clientUid = "client-webhook-sub";
  const stripeSubscriptionId = "sub_webhook123";

  beforeEach(async function () {
    await clearDocTree(db.collection("coachSubscriptions"));
    await clearDocTree(db.collection("stripeWebhookEvents"));
    await clearDocTree(db.collection("coaches").doc(coachUid));
    await clearDocTree(db.collection("users").doc(clientUid));
    await clearDocTree(
      db.collection("coach_clients").doc(connectionDocId(clientUid, coachUid))
    );
    await db.collection("coaches").doc(coachUid).set({
      coachId: coachUid,
      name: "Webhook Coach",
      platformFeePercent: 15,
    });
    await db.collection("users").doc(clientUid).set({
      profileName: "Webhook Client",
    });
  });

  it("creates the completed subscription document with fee snapshot and dedupes redelivery", async function () {
    let retrieveCount = 0;
    const event = {
      id: "evt_checkout_complete",
      type: "checkout.session.completed",
      livemode: false,
      data: {
        object: {
          id: "cs_complete123",
          subscription: stripeSubscriptionId,
          customer: "cus_webhook123",
          metadata: {
            clientUid,
            coachUid,
            platformFeePercent: "15",
          },
        },
      },
    };
    const stripe = {
      subscriptions: {
        retrieve: async (id) => {
          retrieveCount += 1;
          expect(id).to.equal(stripeSubscriptionId);
          return {
            id,
            customer: "cus_webhook123",
            status: "active",
            metadata: {
              clientUid,
              coachUid,
              platformFeePercent: "15",
            },
            items: { data: [{ current_period_end: 1800000000 }] },
          };
        },
      },
    };

    // The checkout was created at 15%; a later admin change must not rewrite
    // the signed signup snapshot.
    await db.collection("coaches").doc(coachUid).set(
      { platformFeePercent: 20 },
      { merge: true }
    );
    const first = await handleStripeEvent(event, {
      db,
      getStripe: () => stripe,
    });
    expect(first).to.deep.include({
      handled: true,
      duplicate: false,
      coachUid,
    });
    const saved = await db
      .collection("coachSubscriptions")
      .doc(stripeSubscriptionId)
      .get();
    expect(saved.data()).to.deep.include({
      clientUid,
      coachUid,
      stripeSubscriptionId,
      stripeCustomerId: "cus_webhook123",
      status: "active",
      platformFeePercentAtSignup: 15,
    });
    expect(saved.data().currentPeriodEnd.toMillis()).to.equal(1800000000000);
    expect(saved.data().createdAt).to.exist;
    expect(saved.data().updatedAt).to.exist;

    const connectionRef = db
      .collection("coach_clients")
      .doc(connectionDocId(clientUid, coachUid));
    const connection = await connectionRef.get();
    expect(connection.data()).to.deep.include({
      coachId: coachUid,
      clientId: clientUid,
      clientUserID: clientUid,
      coachName: "Webhook Coach",
      clientName: "Webhook Client",
      shareWorkouts: true,
      shareNutrition: false,
      shareProgress: false,
      status: "active",
      clientInitiatedContact: true,
    });
    expect(connection.data().permissions).to.deep.equal({
      workouts: true,
      nutrition: false,
      progress: false,
    });
    const connectedAt = connection.data().connectedAt.toMillis();

    const second = await handleStripeEvent(event, {
      db,
      getStripe: () => stripe,
    });
    expect(second).to.deep.include({ handled: false, duplicate: true });
    expect(retrieveCount).to.equal(1);
    const connectionAfterDuplicate = await connectionRef.get();
    expect(connectionAfterDuplicate.data().connectedAt.toMillis()).to.equal(
      connectedAt
    );
    const allConnections = await db.collection("coach_clients").get();
    expect(allConnections.size).to.equal(1);
  });

  it("atomically dedupes concurrent checkout completion deliveries", async function () {
    const event = {
      id: "evt_checkout_concurrent",
      type: "checkout.session.completed",
      livemode: false,
      data: {
        object: {
          id: "cs_concurrent123",
          subscription: stripeSubscriptionId,
          customer: "cus_webhook123",
          metadata: {
            clientUid,
            coachUid,
            platformFeePercent: "15",
          },
        },
      },
    };
    const stripe = {
      subscriptions: {
        retrieve: async () => ({
          id: stripeSubscriptionId,
          customer: "cus_webhook123",
          status: "active",
          metadata: {
            clientUid,
            coachUid,
            platformFeePercent: "15",
          },
          current_period_end: 1800000000,
        }),
      },
    };

    const results = await Promise.all([
      handleStripeEvent(event, { db, getStripe: () => stripe }),
      handleStripeEvent(event, { db, getStripe: () => stripe }),
    ]);
    expect(results.filter((result) => result.handled)).to.have.length(1);
    expect(results.filter((result) => result.duplicate)).to.have.length(1);

    const ledger = await db
      .collection("stripeWebhookEvents")
      .doc(event.id)
      .get();
    expect(ledger.exists).to.equal(true);
    const subscriptions = await db.collection("coachSubscriptions").get();
    const connections = await db.collection("coach_clients").get();
    expect(subscriptions.size).to.equal(1);
    expect(connections.size).to.equal(1);
  });

  it("returns 500 and does not ledger an unmatched lifecycle event", async function () {
    const event = {
      id: "evt_subscription_before_completion",
      type: "customer.subscription.updated",
      livemode: false,
      data: {
        object: {
          id: "sub_notready123",
          status: "active",
          current_period_end: 1810000000,
        },
      },
    };
    const { stripe } = makeMockStripe();
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
    await stripeWebhookHandler(
      {
        method: "POST",
        headers: { "stripe-signature": "valid" },
        rawBody: Buffer.from(JSON.stringify(event)),
      },
      res,
      {
        db,
        getStripe: () => stripe,
        getWebhookSecret: () => "whsec_test",
      }
    );

    expect(res.statusCode).to.equal(500);
    expect(String(res.body)).to.match(/not available yet/i);
    const ledger = await db
      .collection("stripeWebhookEvents")
      .doc(event.id)
      .get();
    expect(ledger.exists).to.equal(false);
    const subscriptions = await db.collection("coachSubscriptions").get();
    expect(subscriptions.empty).to.equal(true);
  });

  async function seedSubscription() {
    await db.collection("coachSubscriptions").doc(stripeSubscriptionId).set({
      clientUid,
      coachUid,
      stripeSubscriptionId,
      stripeCustomerId: "cus_webhook123",
      status: "active",
      currentPeriodEnd: admin.firestore.Timestamp.fromMillis(1700000000000),
      platformFeePercentAtSignup: 15,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  async function expectLedger(eventId) {
    const ledger = await db.collection("stripeWebhookEvents").doc(eventId).get();
    expect(ledger.exists).to.equal(true);
  }

  it("updates status and current period from customer.subscription.updated", async function () {
    await seedSubscription();
    await handleStripeEvent(
      {
        id: "evt_subscription_updated",
        type: "customer.subscription.updated",
        data: {
          object: {
            id: stripeSubscriptionId,
            status: "past_due",
            current_period_end: 1810000000,
          },
        },
      },
      { db }
    );
    const saved = await db
      .collection("coachSubscriptions")
      .doc(stripeSubscriptionId)
      .get();
    expect(saved.data().status).to.equal("past_due");
    expect(saved.data().currentPeriodEnd.toMillis()).to.equal(1810000000000);
    await expectLedger("evt_subscription_updated");
  });

  it("marks customer.subscription.deleted canceled without deleting the document", async function () {
    await seedSubscription();
    await handleStripeEvent(
      {
        id: "evt_subscription_deleted",
        type: "customer.subscription.deleted",
        data: {
          object: {
            id: stripeSubscriptionId,
            status: "canceled",
            current_period_end: 1820000000,
          },
        },
      },
      { db }
    );
    const saved = await db
      .collection("coachSubscriptions")
      .doc(stripeSubscriptionId)
      .get();
    expect(saved.exists).to.equal(true);
    expect(saved.data().status).to.equal("canceled");
    expect(saved.data().endedAt).to.exist;
    await expectLedger("evt_subscription_deleted");
  });

  it("marks invoice.payment_failed past_due without deleting the document", async function () {
    await seedSubscription();
    await handleStripeEvent(
      {
        id: "evt_invoice_failed",
        type: "invoice.payment_failed",
        data: {
          object: {
            id: "in_failed123",
            parent: {
              subscription_details: { subscription: stripeSubscriptionId },
            },
            lines: { data: [{ period: { end: 1830000000 } }] },
          },
        },
      },
      { db }
    );
    const saved = await db
      .collection("coachSubscriptions")
      .doc(stripeSubscriptionId)
      .get();
    expect(saved.exists).to.equal(true);
    expect(saved.data().status).to.equal("past_due");
    expect(saved.data().paymentFailedAt).to.exist;
    expect(saved.data().currentPeriodEnd.toMillis()).to.equal(1830000000000);
    await expectLedger("evt_invoice_failed");
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
        platformFeePercent: 15,
      });
      await setDoc(doc(adminDb, "coachSubscriptions/sub_rules"), {
        clientUid: "client-rules-a",
        coachUid: "coach-rules-a",
        stripeSubscriptionId: "sub_rules",
        status: "active",
      });
      await setDoc(
        doc(
          adminDb,
          `coach_clients/${connectionDocId("client-rules-a", "coach-rules-a")}`
        ),
        {
          coachId: "coach-rules-a",
          clientId: "client-rules-a",
          clientUserID: "client-rules-a",
          coachName: "Rules Coach",
          clientName: "Rules Client",
          connectedAt: new Date("2026-07-21T12:00:00.000Z"),
          permissions: {
            workouts: true,
            nutrition: false,
            progress: false,
          },
          shareWorkouts: true,
          shareNutrition: false,
          shareProgress: false,
          status: "active",
          clientInitiatedContact: true,
          updatedAt: new Date("2026-07-21T12:00:00.000Z"),
        }
      );
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

  it("denies coach create and update attempts for platformFeePercent", async function () {
    const existingCoach =
      testEnv.authenticatedContext("coach-rules-a").firestore();
    await assertFails(
      updateDoc(doc(existingCoach, "coaches/coach-rules-a"), {
        platformFeePercent: 0,
      })
    );

    const newCoach = testEnv.authenticatedContext("coach-rules-fee").firestore();
    await assertFails(
      setDoc(doc(newCoach, "coaches/coach-rules-fee"), {
        coachId: "coach-rules-fee",
        name: "Forged Fee Coach",
        platformFeePercent: 1,
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

  it("denies deleting a payment-configured coach but allows deleting an unconfigured own profile", async function () {
    const configured =
      testEnv.authenticatedContext("coach-rules-a").firestore();
    await assertFails(deleteDoc(doc(configured, "coaches/coach-rules-a")));

    const unconfigured =
      testEnv.authenticatedContext("coach-rules-delete").firestore();
    await assertSucceeds(
      setDoc(doc(unconfigured, "coaches/coach-rules-delete"), {
        coachId: "coach-rules-delete",
        name: "Unconfigured Coach",
      })
    );
    await assertSucceeds(
      deleteDoc(doc(unconfigured, "coaches/coach-rules-delete"))
    );
  });

  it("denies all client access to stripeWebhookEvents", async function () {
    const dbClient = testEnv.authenticatedContext("coach-rules-a").firestore();
    await assertFails(
      setDoc(doc(dbClient, "stripeWebhookEvents/evt_x"), { id: "evt_x" })
    );
  });

  it("allows only subscription participants to get and constrained-list records", async function () {
    const clientDb =
      testEnv.authenticatedContext("client-rules-a").firestore();
    const coachDb = testEnv.authenticatedContext("coach-rules-a").firestore();
    const outsiderDb = testEnv.authenticatedContext("outsider-rules").firestore();

    await assertSucceeds(
      getDoc(doc(clientDb, "coachSubscriptions/sub_rules"))
    );
    await assertSucceeds(
      getDoc(doc(coachDb, "coachSubscriptions/sub_rules"))
    );
    await assertFails(
      getDoc(doc(outsiderDb, "coachSubscriptions/sub_rules"))
    );
    await assertSucceeds(
      getDocs(
        query(
          collection(clientDb, "coachSubscriptions"),
          where("clientUid", "==", "client-rules-a")
        )
      )
    );
    await assertSucceeds(
      getDocs(
        query(
          collection(coachDb, "coachSubscriptions"),
          where("coachUid", "==", "coach-rules-a")
        )
      )
    );
    await assertFails(getDocs(collection(clientDb, "coachSubscriptions")));
    await assertFails(
      getDocs(
        query(
          collection(outsiderDb, "coachSubscriptions"),
          where("clientUid", "==", "client-rules-a")
        )
      )
    );
  });

  it("denies all client create, update, and delete writes to coachSubscriptions", async function () {
    const clientDb =
      testEnv.authenticatedContext("client-rules-a").firestore();
    await assertFails(
      setDoc(doc(clientDb, "coachSubscriptions/sub_forged"), {
        clientUid: "client-rules-a",
        coachUid: "coach-rules-a",
        stripeSubscriptionId: "sub_forged",
        status: "active",
      })
    );
    await assertFails(
      updateDoc(doc(clientDb, "coachSubscriptions/sub_rules"), {
        status: "canceled",
      })
    );
    await assertFails(
      deleteDoc(doc(clientDb, "coachSubscriptions/sub_rules"))
    );
  });

  it("denies client status changes and reactivation", async function () {
    const path = `coach_clients/${connectionDocId(
      "client-rules-a",
      "coach-rules-a"
    )}`;
    const clientDb =
      testEnv.authenticatedContext("client-rules-a").firestore();
    await assertFails(
      updateDoc(doc(clientDb, path), {
        status: "inactive",
      })
    );

    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), path), {
        status: "inactive",
      });
    });
    await assertFails(
      updateDoc(doc(clientDb, path), {
        status: "active",
      })
    );
  });

  it("denies coach status changes", async function () {
    const coachDb = testEnv.authenticatedContext("coach-rules-a").firestore();
    await assertFails(
      updateDoc(
        doc(
          coachDb,
          `coach_clients/${connectionDocId(
            "client-rules-a",
            "coach-rules-a"
          )}`
        ),
        { status: "inactive" }
      )
    );
  });

  it("denies coachId and client identity mutations", async function () {
    const path = `coach_clients/${connectionDocId(
      "client-rules-a",
      "coach-rules-a"
    )}`;
    const clientDb =
      testEnv.authenticatedContext("client-rules-a").firestore();
    await assertFails(
      updateDoc(doc(clientDb, path), { coachId: "coach-attacker" })
    );
    await assertFails(
      updateDoc(doc(clientDb, path), { clientId: "client-attacker" })
    );
    await assertFails(
      updateDoc(doc(clientDb, path), { clientUserID: "client-attacker" })
    );
  });

  it("denies connection timestamp and server metadata mutations", async function () {
    const path = `coach_clients/${connectionDocId(
      "client-rules-a",
      "coach-rules-a"
    )}`;
    const clientDb =
      testEnv.authenticatedContext("client-rules-a").firestore();
    await assertFails(
      updateDoc(doc(clientDb, path), {
        connectedAt: new Date("2030-01-01T00:00:00.000Z"),
      })
    );
    await assertFails(
      updateDoc(doc(clientDb, path), {
        updatedAt: new Date("2030-01-01T00:00:00.000Z"),
      })
    );
    await assertFails(
      updateDoc(doc(clientDb, path), {
        clientInitiatedContact: false,
      })
    );
    await assertFails(
      updateDoc(doc(clientDb, path), {
        coachName: "Forged Coach",
      })
    );
  });

  it("allows only the client participant to update consistent sharing fields", async function () {
    const path = `coach_clients/${connectionDocId(
      "client-rules-a",
      "coach-rules-a"
    )}`;
    const clientDb =
      testEnv.authenticatedContext("client-rules-a").firestore();
    await assertSucceeds(
      updateDoc(doc(clientDb, path), {
        permissions: {
          workouts: false,
          nutrition: true,
          progress: true,
        },
        shareWorkouts: false,
        shareNutrition: true,
        shareProgress: true,
        updatedAt: serverTimestamp(),
      })
    );
    const saved = await getDoc(doc(clientDb, path));
    expect(saved.data().permissions).to.deep.equal({
      workouts: false,
      nutrition: true,
      progress: true,
    });

    const coachDb = testEnv.authenticatedContext("coach-rules-a").firestore();
    await assertFails(
      updateDoc(doc(coachDb, path), {
        permissions: {
          workouts: true,
          nutrition: true,
          progress: true,
        },
        shareWorkouts: true,
        shareNutrition: true,
        shareProgress: true,
        updatedAt: serverTimestamp(),
      })
    );

    const outsiderDb =
      testEnv.authenticatedContext("outsider-rules").firestore();
    await assertFails(
      updateDoc(doc(outsiderDb, path), {
        permissions: {
          workouts: true,
          nutrition: false,
          progress: false,
        },
        shareWorkouts: true,
        shareNutrition: false,
        shareProgress: false,
        updatedAt: serverTimestamp(),
      })
    );
    await assertFails(
      updateDoc(doc(clientDb, path), {
        permissions: {
          workouts: true,
          nutrition: false,
          progress: false,
        },
        shareWorkouts: false,
        shareNutrition: false,
        shareProgress: false,
        updatedAt: serverTimestamp(),
      })
    );
  });

  it("denies client creation of a paid coach connection", async function () {
    const clientDb =
      testEnv.authenticatedContext("client-rules-new").firestore();
    await assertFails(
      setDoc(
        doc(
          clientDb,
          `coach_clients/${connectionDocId("client-rules-new", "coach-rules-a")}`
        ),
        {
          coachId: "coach-rules-a",
          clientId: "client-rules-new",
          clientUserID: "client-rules-new",
          status: "active",
        }
      )
    );
  });
});
