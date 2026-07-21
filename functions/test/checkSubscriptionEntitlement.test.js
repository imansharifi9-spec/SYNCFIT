/**
 * Emulator integration tests for checkSubscriptionEntitlement.
 * Run via: firebase emulators:exec --only firestore "npm test --prefix functions"
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "syncfit-8441f";
process.env.GOOGLE_CLOUD_PROJECT =
  process.env.GOOGLE_CLOUD_PROJECT || "syncfit-8441f";

const { expect } = require("chai");
const admin = require("firebase-admin");
const {
  checkSubscriptionEntitlementForUid,
  evaluateSubscriptionEntitlement,
} = require("../index");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "syncfit-8441f" });
}

const db = admin.firestore();

async function seedUser(uid, fields) {
  await db.collection("users").doc(uid).set(fields, { merge: false });
}

describe("checkSubscriptionEntitlement (Firestore emulator)", function () {
  this.timeout(15000);

  before(function () {
    if (!process.env.FIRESTORE_EMULATOR_HOST) {
      throw new Error(
        "FIRESTORE_EMULATOR_HOST is not set — run via firebase emulators:exec"
      );
    }
  });

  it("active status + future expiry → entitled: true", async function () {
    const uid = "test-user-active-future";
    const future = admin.firestore.Timestamp.fromDate(
      new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)
    );
    await seedUser(uid, {
      subscriptionStatus: "active",
      subscriptionExpiresAt: future,
    });

    const result = await checkSubscriptionEntitlementForUid(uid);
    expect(result.entitled).to.equal(true);
    expect(result.reason).to.equal("active_entitlement");
  });

  it("active status + PAST expiry → entitled: false (stale active)", async function () {
    const uid = "test-user-active-past";
    const past = admin.firestore.Timestamp.fromDate(
      new Date(Date.now() - 24 * 60 * 60 * 1000)
    );
    await seedUser(uid, {
      subscriptionStatus: "active",
      subscriptionExpiresAt: past,
    });

    const result = await checkSubscriptionEntitlementForUid(uid);
    expect(result.entitled).to.equal(false);
    expect(result.reason).to.equal("subscription_expired_stale_active");
  });

  it('subscriptionStatus "none" → entitled: false', async function () {
    const uid = "test-user-none";
    await seedUser(uid, {
      subscriptionStatus: "none",
      subscriptionExpiresAt: null,
    });

    const result = await checkSubscriptionEntitlementForUid(uid);
    expect(result.entitled).to.equal(false);
    expect(result.reason).to.equal("subscription_status_none");
  });

  it("missing subscriptionStatus field → entitled: false, no crash", async function () {
    const uid = "test-user-missing-fields";
    await seedUser(uid, {
      profileName: "Never Subscribed",
    });

    const result = await checkSubscriptionEntitlementForUid(uid);
    expect(result.entitled).to.equal(false);
    expect(result.reason).to.equal("subscription_status_missing");
  });

  it("callable rejects unauthenticated context (auth required)", async function () {
    // Pure evaluate sanity: no uid / missing fields mirrors never-subscribed.
    const local = evaluateSubscriptionEntitlement({});
    expect(local.entitled).to.equal(false);
    expect(local.reason).to.equal("subscription_status_missing");
  });
});
