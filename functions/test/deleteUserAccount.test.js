/**
 * Emulator tests for authenticated account deletion.
 * Run via: firebase emulators:exec --only firestore "npx mocha test/deleteUserAccount.test.js --exit --timeout 20000"
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "syncfit-8441f";
process.env.GOOGLE_CLOUD_PROJECT =
  process.env.GOOGLE_CLOUD_PROJECT || "syncfit-8441f";

const { expect } = require("chai");
const admin = require("firebase-admin");
const { HttpsError } = require("firebase-functions/v2/https");
const { connectionDocId } = require("../coachClientAccess");
const {
  deleteUserAccountForUid,
  assertSelfOnlyTarget,
} = require("../deleteUserAccount");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "syncfit-8441f" });
}

const db = admin.firestore();

async function clearDocTree(ref) {
  await admin.firestore().recursiveDelete(ref);
}

function makeMockStripe({ failIds } = {}) {
  const state = {
    cancelCalls: [],
  };
  const failSet = new Set(failIds || []);

  return {
    state,
    stripe: {
      subscriptions: {
        cancel: async (id) => {
          state.cancelCalls.push(id);
          if (failSet.has(id)) {
            const err = new Error(`Stripe cancel failed for ${id}`);
            err.code = "stripe_error";
            throw err;
          }
          return { id, status: "canceled" };
        },
      },
    },
  };
}

function makeMockAuth({ missingUids } = {}) {
  const state = {
    deleteCalls: [],
  };
  const missing = new Set(missingUids || []);

  return {
    state,
    auth: {
      deleteUser: async (uid) => {
        state.deleteCalls.push(uid);
        if (missing.has(uid)) {
          const err = new Error("There is no user record corresponding to the provided identifier.");
          err.code = "auth/user-not-found";
          throw err;
        }
        return undefined;
      },
    },
  };
}

function makeMockBucket() {
  const state = {
    deleteFilesCalls: [],
  };
  return {
    state,
    bucket: {
      deleteFiles: async ({ prefix }) => {
        state.deleteFilesCalls.push(prefix);
        return undefined;
      },
      getFiles: async () => [[]],
    },
  };
}

async function seedUserTree(uid) {
  await db.collection("users").doc(uid).set({
    displayName: "Delete Me",
    email: "delete-me@example.com",
  });
  await db.collection("users").doc(uid).collection("workouts").doc("w1").set({
    exerciseName: "Squat",
  });
  await db.collection("users").doc(uid).collection("meals").doc("m1").set({
    name: "Chicken",
  });
  await db.collection("users").doc(uid).collection("weights").doc("wt1").set({
    weightKg: 80,
  });
  await db
    .collection("users")
    .doc(uid)
    .collection("progress_photos")
    .doc("p1")
    .set({ storagePath: `users/${uid}/progress_photos/p1.jpg` });
  await db.collection("users").doc(uid).collection("routines").doc("r1").set({
    name: "Push",
  });
  const convRef = db
    .collection("users")
    .doc(uid)
    .collection("aiCompanionConversations")
    .doc("c1");
  await convRef.set({ userId: uid, title: "Chat" });
  await convRef.collection("messages").doc("msg1").set({
    role: "user",
    text: "hello",
    userId: uid,
  });
}

describe("deleteUserAccount", function () {
  this.timeout(30000);

  const uid = "user-delete-a";
  const coachUid = "coach-delete-a";
  const otherClient = "client-other-a";

  before(function () {
    if (!process.env.FIRESTORE_EMULATOR_HOST) {
      throw new Error(
        "FIRESTORE_EMULATOR_HOST is not set — run via firebase emulators:exec"
      );
    }
  });

  beforeEach(async function () {
    await clearDocTree(db.collection("users").doc(uid));
    await clearDocTree(db.collection("users").doc(otherClient));
    await clearDocTree(db.collection("coaches").doc(uid));
    await clearDocTree(db.collection("coaches").doc(coachUid));
    await clearDocTree(db.collection("coachSubscriptions"));
    await clearDocTree(db.collection("coach_clients"));
    await clearDocTree(db.collection("conversations"));
    await clearDocTree(db.collection("coach_messages"));
  });

  it("removes Firestore user tree, coach_clients, coachSubscriptions, and calls auth.deleteUser", async function () {
    await seedUserTree(uid);
    await db.collection("coaches").doc(coachUid).set({
      coachId: coachUid,
      name: "Other Coach",
    });

    const connectionId = connectionDocId(uid, coachUid);
    await db.collection("coach_clients").doc(connectionId).set({
      coachId: coachUid,
      clientId: uid,
      clientUserID: uid,
      status: "active",
    });

    await db.collection("coachSubscriptions").doc("sub_canceled_old").set({
      clientUid: uid,
      coachUid,
      status: "canceled",
      stripeSubscriptionId: "sub_canceled_old",
    });

    const conversationId = [uid, coachUid].sort().join("_");
    await db.collection("conversations").doc(conversationId).set({
      participants: [uid, coachUid].sort(),
      userId: uid,
      coachId: coachUid,
    });
    await db
      .collection("conversations")
      .doc(conversationId)
      .collection("messages")
      .doc("m1")
      .set({ senderId: uid, text: "hi" });

    const { stripe, state: stripeState } = makeMockStripe();
    const { auth, state: authState } = makeMockAuth();
    const { bucket, state: bucketState } = makeMockBucket();

    const result = await deleteUserAccountForUid(uid, {
      db,
      getStripe: () => stripe,
      getAuth: () => auth,
      getBucket: () => bucket,
      recursiveDelete: (ref) => db.recursiveDelete(ref),
    });

    expect(result.deleted).to.equal(true);
    expect(authState.deleteCalls).to.deep.equal([uid]);
    expect(stripeState.cancelCalls).to.deep.equal([]);
    expect(bucketState.deleteFilesCalls).to.include(`users/${uid}/`);
    expect(bucketState.deleteFilesCalls).to.include(`coaches/${uid}/`);

    expect((await db.collection("users").doc(uid).get()).exists).to.equal(false);
    expect(
      (await db.collection("coach_clients").doc(connectionId).get()).exists
    ).to.equal(false);
    expect(
      (await db.collection("coachSubscriptions").doc("sub_canceled_old").get())
        .exists
    ).to.equal(false);
    expect(
      (await db.collection("conversations").doc(conversationId).get()).exists
    ).to.equal(false);

    const stepNames = result.steps.map((s) => s.name);
    expect(stepNames).to.include("deleteAuthUser");
    expect(
      result.steps.every(
        (s) => s.ok || (s.detail && s.detail.continued === true)
      )
    ).to.equal(true);
  });

  it("cancels active client coachSubscriptions via Stripe before wipe", async function () {
    await seedUserTree(uid);
    await db.collection("coaches").doc(coachUid).set({
      coachId: coachUid,
      name: "Paid Coach",
    });

    await db.collection("coachSubscriptions").doc("sub_active_client").set({
      clientUid: uid,
      coachUid,
      status: "active",
      stripeSubscriptionId: "sub_active_client",
    });
    await db.collection("coachSubscriptions").doc("sub_trialing_client").set({
      clientUid: uid,
      coachUid: "another-coach",
      status: "trialing",
      stripeSubscriptionId: "sub_trialing_client",
    });
    // Terminal — should not cancel.
    await db.collection("coachSubscriptions").doc("sub_already_canceled").set({
      clientUid: uid,
      coachUid,
      status: "canceled",
      stripeSubscriptionId: "sub_already_canceled",
    });

    const connectionId = connectionDocId(uid, coachUid);
    await db.collection("coach_clients").doc(connectionId).set({
      coachId: coachUid,
      clientId: uid,
      clientUserID: uid,
      status: "active",
    });

    const { stripe, state: stripeState } = makeMockStripe();
    const { auth, state: authState } = makeMockAuth();
    const { bucket } = makeMockBucket();

    const result = await deleteUserAccountForUid(uid, {
      db,
      getStripe: () => stripe,
      getAuth: () => auth,
      getBucket: () => bucket,
      recursiveDelete: (ref) => db.recursiveDelete(ref),
    });

    expect(stripeState.cancelCalls.sort()).to.deep.equal(
      ["sub_active_client", "sub_trialing_client"].sort()
    );
    expect(result.cancelledSubscriptions.sort()).to.deep.equal(
      ["sub_active_client", "sub_trialing_client"].sort()
    );
    expect(authState.deleteCalls).to.deep.equal([uid]);

    expect(
      (await db.collection("coachSubscriptions").doc("sub_active_client").get())
        .exists
    ).to.equal(false);
    expect(
      (
        await db.collection("coachSubscriptions").doc("sub_trialing_client").get()
      ).exists
    ).to.equal(false);
    expect(
      (
        await db.collection("coachSubscriptions").doc("sub_already_canceled").get()
      ).exists
    ).to.equal(false);
    expect(
      (await db.collection("coach_clients").doc(connectionId).get()).exists
    ).to.equal(false);
  });

  it("blocks coach with active client subscriptions and does not cancel or delete Auth", async function () {
    await db.collection("users").doc(uid).set({ displayName: "Coach User" });
    await db.collection("coaches").doc(uid).set({
      coachId: uid,
      name: "Blocked Coach",
    });

    await db.collection("coachSubscriptions").doc("sub_client_paying").set({
      clientUid: otherClient,
      coachUid: uid,
      status: "active",
      stripeSubscriptionId: "sub_client_paying",
    });
    await db.collection("coachSubscriptions").doc("sub_client_past_due").set({
      clientUid: "another-client",
      coachUid: uid,
      status: "past_due",
      stripeSubscriptionId: "sub_client_past_due",
    });

    const { stripe, state: stripeState } = makeMockStripe();
    const { auth, state: authState } = makeMockAuth();
    const { bucket } = makeMockBucket();

    try {
      await deleteUserAccountForUid(uid, {
        db,
        getStripe: () => stripe,
        getAuth: () => auth,
        getBucket: () => bucket,
      });
      expect.fail("expected failed-precondition");
    } catch (err) {
      expect(err).to.be.instanceOf(HttpsError);
      expect(err.code).to.equal("failed-precondition");
      expect(err.message).to.include("Active subscriptions: 2");
      expect(err.message).to.include(
        "Cancel or wait until you have 0 active client subscriptions"
      );
    }

    expect(stripeState.cancelCalls).to.deep.equal([]);
    expect(authState.deleteCalls).to.deep.equal([]);
    expect((await db.collection("users").doc(uid).get()).exists).to.equal(true);
    expect((await db.collection("coaches").doc(uid).get()).exists).to.equal(
      true
    );
    expect(
      (await db.collection("coachSubscriptions").doc("sub_client_paying").get())
        .exists
    ).to.equal(true);
  });

  it("throws permission-denied when targetUid differs from auth uid", async function () {
    expect(() =>
      assertSelfOnlyTarget(uid, { targetUid: "someone-else" })
    ).to.throw(HttpsError);

    try {
      assertSelfOnlyTarget(uid, { targetUid: "someone-else" });
      expect.fail("expected permission-denied");
    } catch (err) {
      expect(err).to.be.instanceOf(HttpsError);
      expect(err.code).to.equal("permission-denied");
    }

    // Matching or absent targetUid is fine.
    expect(() => assertSelfOnlyTarget(uid, {})).to.not.throw();
    expect(() => assertSelfOnlyTarget(uid, { targetUid: uid })).to.not.throw();
  });

  it("is idempotent when Firestore is empty and Auth user-not-found", async function () {
    const { stripe, state: stripeState } = makeMockStripe();
    const { auth, state: authState } = makeMockAuth({ missingUids: [uid] });
    const { bucket } = makeMockBucket();

    const result = await deleteUserAccountForUid(uid, {
      db,
      getStripe: () => stripe,
      getAuth: () => auth,
      getBucket: () => bucket,
      recursiveDelete: (ref) => db.recursiveDelete(ref),
    });

    expect(result.deleted).to.equal(true);
    expect(result.cancelledSubscriptions).to.deep.equal([]);
    expect(stripeState.cancelCalls).to.deep.equal([]);
    expect(authState.deleteCalls).to.deep.equal([uid]);

    const authStep = result.steps.find((s) => s.name === "deleteAuthUser");
    expect(authStep.ok).to.equal(true);
    expect(authStep.detail.alreadyDeleted).to.equal(true);

    // Second wipe still succeeds.
    const second = await deleteUserAccountForUid(uid, {
      db,
      getStripe: () => stripe,
      getAuth: () => auth,
      getBucket: () => bucket,
      recursiveDelete: (ref) => db.recursiveDelete(ref),
    });
    expect(second.deleted).to.equal(true);
  });
});
