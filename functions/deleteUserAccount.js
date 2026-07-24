/**
 * Authenticated account deletion: cancel client Stripe coach subscriptions,
 * wipe Firestore + Storage for the caller, then delete Auth last.
 */

const { getFirestore } = require("firebase-admin/firestore");
const { getAuth } = require("firebase-admin/auth");
const { getStorage } = require("firebase-admin/storage");
const { HttpsError } = require("firebase-functions/v2/https");

/** Must match createCheckoutSession non-terminal statuses. */
const NON_TERMINAL_SUBSCRIPTION_STATUSES = new Set([
  "active",
  "trialing",
  "past_due",
  "unpaid",
  "incomplete",
  "paused",
]);

const USER_SUBCOLLECTIONS = [
  "workouts",
  "meals",
  "weights",
  "progress_photos",
  "routines",
  "routine_templates",
  "aiCompanionConversations",
  "aiCompanionRateLimits",
  "coachAiRoutineDraftRateLimits",
];

const COACH_SUBCOLLECTIONS = ["routine_templates", "clientInsights"];

function isNonTerminalStatus(status) {
  return NON_TERMINAL_SUBSCRIPTION_STATUSES.has(status);
}

function assertAuthenticatedUid(uid) {
  if (!uid || typeof uid !== "string") {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
}

/**
 * Prefer permission-denied when a client tries to pass another user's uid.
 * @param {string} authUid
 * @param {object|null|undefined} data
 */
function assertSelfOnlyTarget(authUid, data) {
  if (!data || typeof data !== "object") return;
  if (!Object.prototype.hasOwnProperty.call(data, "targetUid")) return;
  const targetUid = data.targetUid;
  if (targetUid === undefined || targetUid === null || targetUid === "") return;
  if (typeof targetUid !== "string" || targetUid !== authUid) {
    throw new HttpsError(
      "permission-denied",
      "You can only delete your own account."
    );
  }
}

function makeStep(name, ok, detail) {
  const step = { name, ok: !!ok };
  if (detail !== undefined) step.detail = detail;
  return step;
}

function logStep(logger, step) {
  const msg = `[deleteUserAccount] ${step.name} ok=${step.ok}`;
  if (step.ok) {
    logger.info(msg, step.detail || "");
  } else {
    logger.error(msg, step.detail || "");
  }
}

async function deleteQueryDocs(db, querySnap) {
  const refs = [];
  for (const doc of querySnap.docs) {
    refs.push(doc.ref);
  }
  await deleteRefs(db, refs);
  return refs.length;
}

async function deleteRefs(db, refs) {
  const unique = [];
  const seen = new Set();
  for (const ref of refs) {
    const path = ref.path;
    if (seen.has(path)) continue;
    seen.add(path);
    unique.push(ref);
  }
  const batchSize = 400;
  for (let i = 0; i < unique.length; i += batchSize) {
    const chunk = unique.slice(i, i + batchSize);
    const batch = db.batch();
    for (const ref of chunk) {
      batch.delete(ref);
    }
    await batch.commit();
  }
  return unique.length;
}

/**
 * Delete a document and known nested subcollections (messages under AI chats).
 * Prefer recursiveDelete when available (Admin SDK).
 */
async function wipeDocumentTree(db, docRef, knownSubcollections, deps = {}) {
  const recursiveDelete = deps.recursiveDelete;
  if (typeof recursiveDelete === "function") {
    try {
      await recursiveDelete(docRef);
      return { method: "recursiveDelete" };
    } catch (err) {
      // Fall through to manual wipe if recursiveDelete unavailable in tests.
      if (err && err.code !== "unimplemented") {
        // Still try manual for emulator quirks; only rethrow if both fail later.
      }
    }
  }

  for (const name of knownSubcollections) {
    const subSnap = await docRef.collection(name).get();
    for (const subDoc of subSnap.docs) {
      // Nested messages under AI companion conversations.
      if (name === "aiCompanionConversations") {
        const messagesSnap = await subDoc.ref.collection("messages").get();
        await deleteRefs(
          db,
          messagesSnap.docs.map((d) => d.ref)
        );
      }
      await subDoc.ref.delete();
    }
  }
  const snap = await docRef.get();
  if (snap.exists) {
    await docRef.delete();
  }
  return { method: "manual" };
}

async function cancelClientSubscriptions(db, stripe, uid, logger) {
  const snapshot = await db
    .collection("coachSubscriptions")
    .where("clientUid", "==", uid)
    .get();

  const toCancel = snapshot.docs.filter((doc) =>
    isNonTerminalStatus((doc.data() || {}).status)
  );

  const cancelledSubscriptions = [];
  const failures = [];

  for (const doc of toCancel) {
    const data = doc.data() || {};
    const stripeId =
      (typeof data.stripeSubscriptionId === "string" &&
        data.stripeSubscriptionId) ||
      doc.id;
    try {
      await stripe.subscriptions.cancel(stripeId);
      cancelledSubscriptions.push(stripeId);
      try {
        await doc.ref.set(
          {
            status: "canceled",
            canceledAt: new Date().toISOString(),
            updatedAt: new Date().toISOString(),
          },
          { merge: true }
        );
      } catch (writeErr) {
        logger.warn(
          `[deleteUserAccount] Firestore status update after cancel failed for ${stripeId}`,
          writeErr && writeErr.message
        );
      }
      logger.info(`[deleteUserAccount] Canceled Stripe subscription ${stripeId}`);
    } catch (err) {
      failures.push({
        subscriptionId: stripeId,
        message: (err && err.message) || String(err),
      });
      logger.error(
        `[deleteUserAccount] Stripe cancel failed for ${stripeId}`,
        err && err.message
      );
    }
  }

  return { cancelledSubscriptions, failures, examined: toCancel.length };
}

async function assertCoachHasNoActiveClientSubscriptions(db, uid) {
  const coachSnap = await db.collection("coaches").doc(uid).get();
  if (!coachSnap.exists) {
    return { isCoach: false, activeCount: 0 };
  }

  const snapshot = await db
    .collection("coachSubscriptions")
    .where("coachUid", "==", uid)
    .get();

  const activeCount = snapshot.docs.filter((doc) =>
    isNonTerminalStatus((doc.data() || {}).status)
  ).length;

  if (activeCount > 0) {
    throw new HttpsError(
      "failed-precondition",
      `Cancel or wait until you have 0 active client subscriptions before deleting your coach account. Active subscriptions: ${activeCount}`
    );
  }

  return { isCoach: true, activeCount: 0 };
}

async function collectCoachClientRefs(db, uid) {
  const queries = [
    db.collection("coach_clients").where("clientId", "==", uid),
    db.collection("coach_clients").where("clientUserID", "==", uid),
    db.collection("coach_clients").where("coachId", "==", uid),
  ];
  const refs = [];
  for (const q of queries) {
    const snap = await q.get();
    for (const doc of snap.docs) {
      refs.push(doc.ref);
    }
  }
  return refs;
}

async function collectCoachSubscriptionRefs(db, uid) {
  const queries = [
    db.collection("coachSubscriptions").where("clientUid", "==", uid),
    db.collection("coachSubscriptions").where("coachUid", "==", uid),
  ];
  const refs = [];
  for (const q of queries) {
    const snap = await q.get();
    for (const doc of snap.docs) {
      refs.push(doc.ref);
    }
  }
  return refs;
}

async function wipeConversationsForUid(db, uid, deps = {}) {
  const snap = await db
    .collection("conversations")
    .where("participants", "array-contains", uid)
    .get();

  let deleted = 0;
  for (const doc of snap.docs) {
    await wipeDocumentTree(db, doc.ref, ["messages"], deps);
    deleted += 1;
  }
  return deleted;
}

async function wipeLegacyCoachMessages(db, uid) {
  const queries = [
    db.collection("coach_messages").where("coachId", "==", uid),
    db.collection("coach_messages").where("clientUserID", "==", uid),
  ];
  let deleted = 0;
  for (const q of queries) {
    deleted += await deleteQueryDocs(db, await q.get());
  }
  return deleted;
}

async function deleteStoragePrefix(bucket, prefix, logger) {
  if (!bucket) {
    return { deleted: 0, skipped: true };
  }

  try {
    if (typeof bucket.deleteFiles === "function") {
      await bucket.deleteFiles({ prefix, force: true });
      logger.info(`[deleteUserAccount] Storage deleteFiles prefix=${prefix}`);
      return { deleted: "all", prefix };
    }
  } catch (err) {
    // Fall through to list+delete; missing objects are fine.
    logger.warn(
      `[deleteUserAccount] deleteFiles failed for ${prefix}, trying list`,
      err && err.message
    );
  }

  try {
    const listResult = await bucket.getFiles({ prefix });
    const files = Array.isArray(listResult) ? listResult[0] : listResult;
    let deleted = 0;
    for (const file of files || []) {
      try {
        await file.delete({ ignoreNotFound: true });
        deleted += 1;
      } catch (err) {
        logger.warn(
          `[deleteUserAccount] Storage file delete failed ${file.name}`,
          err && err.message
        );
      }
    }
    return { deleted, prefix };
  } catch (err) {
    logger.warn(
      `[deleteUserAccount] Storage list failed for ${prefix}`,
      err && err.message
    );
    return {
      deleted: 0,
      prefix,
      error: (err && err.message) || String(err),
    };
  }
}

const DEFAULT_STORAGE_BUCKET = "syncfit-8441f.firebasestorage.app";

/**
 * Resolve the Storage bucket explicitly so wipes work even when Admin was
 * initialized without storageBucket (common when only projectId is set).
 */
function resolveStorageBucket(deps = {}) {
  if (typeof deps.getBucket === "function") {
    return deps.getBucket();
  }
  const name =
    process.env.FIREBASE_STORAGE_BUCKET ||
    process.env.GCLOUD_STORAGE_BUCKET ||
    DEFAULT_STORAGE_BUCKET;
  return getStorage().bucket(name);
}

/**
 * Core wipe for an authenticated uid. Injectable deps for unit tests.
 *
 * @param {string} uid
 * @param {object} [deps]
 * @param {FirebaseFirestore.Firestore} [deps.db]
 * @param {() => import('stripe').Stripe} [deps.getStripe]
 * @param {() => import('firebase-admin/auth').Auth} [deps.getAuth]
 * @param {() => import('@google-cloud/storage').Bucket} [deps.getBucket]
 * @param {(ref) => Promise<void>} [deps.recursiveDelete]
 * @param {Console} [deps.logger]
 */
async function deleteUserAccountForUid(uid, deps = {}) {
  assertAuthenticatedUid(uid);

  const logger = deps.logger || console;
  const db = deps.db || getFirestore();
  const steps = [];
  const cancelledSubscriptions = [];

  const pushStep = (step) => {
    steps.push(step);
    logStep(logger, step);
  };

  // Coach gate — block if any non-terminal client subscriptions.
  try {
    const coachCheck = await assertCoachHasNoActiveClientSubscriptions(db, uid);
    pushStep(
      makeStep("coachSubscriptionGate", true, {
        isCoach: coachCheck.isCoach,
        activeCount: coachCheck.activeCount,
      })
    );
  } catch (err) {
    pushStep(
      makeStep("coachSubscriptionGate", false, {
        code: err.code,
        message: err.message,
      })
    );
    throw err;
  }

  // Cancel caller's non-terminal client subscriptions in Stripe first.
  const getStripe = deps.getStripe;
  if (typeof getStripe !== "function") {
    throw new HttpsError(
      "failed-precondition",
      "Stripe client is not configured."
    );
  }
  const stripe = getStripe();
  if (!stripe || !stripe.subscriptions || typeof stripe.subscriptions.cancel !== "function") {
    throw new HttpsError(
      "failed-precondition",
      "Stripe client is not configured."
    );
  }

  const cancelResult = await cancelClientSubscriptions(db, stripe, uid, logger);
  cancelledSubscriptions.push(...cancelResult.cancelledSubscriptions);
  if (cancelResult.failures.length > 0) {
    pushStep(
      makeStep("cancelClientSubscriptions", false, {
        cancelledSubscriptions,
        failures: cancelResult.failures,
        examined: cancelResult.examined,
      })
    );
    throw new HttpsError(
      "internal",
      `Failed to cancel ${cancelResult.failures.length} Stripe subscription(s) before account deletion. Cancelled so far: ${cancelledSubscriptions.length}.`
    );
  }
  pushStep(
    makeStep("cancelClientSubscriptions", true, {
      cancelledSubscriptions: [...cancelledSubscriptions],
      examined: cancelResult.examined,
    })
  );

  // Firestore wipe
  try {
    const subRefs = await collectCoachSubscriptionRefs(db, uid);
    const subDeleted = await deleteRefs(db, subRefs);
    pushStep(makeStep("deleteCoachSubscriptions", true, { deleted: subDeleted }));

    const clientRefs = await collectCoachClientRefs(db, uid);
    const clientsDeleted = await deleteRefs(db, clientRefs);
    pushStep(makeStep("deleteCoachClients", true, { deleted: clientsDeleted }));

    const conversationsDeleted = await wipeConversationsForUid(db, uid, deps);
    pushStep(
      makeStep("deleteConversations", true, { deleted: conversationsDeleted })
    );

    const legacyMessagesDeleted = await wipeLegacyCoachMessages(db, uid);
    pushStep(
      makeStep("deleteLegacyCoachMessages", true, {
        deleted: legacyMessagesDeleted,
      })
    );

    const recursiveDelete =
      deps.recursiveDelete ||
      (typeof db.recursiveDelete === "function"
        ? (ref) => db.recursiveDelete(ref)
        : undefined);

    await wipeDocumentTree(db, db.collection("users").doc(uid), USER_SUBCOLLECTIONS, {
      recursiveDelete,
    });
    pushStep(makeStep("deleteUserDoc", true, { path: `users/${uid}` }));

    await wipeDocumentTree(
      db,
      db.collection("coaches").doc(uid),
      COACH_SUBCOLLECTIONS,
      { recursiveDelete }
    );
    pushStep(makeStep("deleteCoachDoc", true, { path: `coaches/${uid}` }));
  } catch (err) {
    pushStep(
      makeStep("deleteFirestore", false, {
        message: (err && err.message) || String(err),
      })
    );
    throw new HttpsError(
      "internal",
      `Firestore wipe failed: ${(err && err.message) || String(err)}`
    );
  }

  // Storage wipe — tolerate missing files / buckets.
  try {
    let bucket = null;
    try {
      bucket = resolveStorageBucket(deps);
    } catch (err) {
      logger.warn(
        "[deleteUserAccount] Storage bucket unavailable (tolerated)",
        err && err.message
      );
    }

    const userStorage = await deleteStoragePrefix(
      bucket,
      `users/${uid}/`,
      logger
    );
    pushStep(makeStep("deleteUserStorage", true, userStorage));

    const coachStorage = await deleteStoragePrefix(
      bucket,
      `coaches/${uid}/`,
      logger
    );
    pushStep(makeStep("deleteCoachStorage", true, coachStorage));
  } catch (err) {
    // Storage failures are non-fatal once Auth is still pending — log and continue.
    pushStep(
      makeStep("deleteStorage", false, {
        message: (err && err.message) || String(err),
        continued: true,
      })
    );
    logger.error(
      "[deleteUserAccount] Storage wipe error (continuing to Auth delete)",
      err && err.message
    );
  }

  // Auth delete LAST.
  try {
    const auth =
      typeof deps.getAuth === "function" ? deps.getAuth() : getAuth();
    await auth.deleteUser(uid);
    pushStep(makeStep("deleteAuthUser", true, { uid }));
  } catch (err) {
    const code = err && err.code;
    if (code === "auth/user-not-found") {
      pushStep(
        makeStep("deleteAuthUser", true, {
          uid,
          alreadyDeleted: true,
        })
      );
    } else {
      pushStep(
        makeStep("deleteAuthUser", false, {
          uid,
          code,
          message: (err && err.message) || String(err),
        })
      );
      throw new HttpsError(
        "internal",
        `Auth delete failed: ${(err && err.message) || String(err)}`
      );
    }
  }

  return {
    deleted: true,
    cancelledSubscriptions,
    steps,
  };
}

module.exports = {
  NON_TERMINAL_SUBSCRIPTION_STATUSES,
  USER_SUBCOLLECTIONS,
  COACH_SUBCOLLECTIONS,
  isNonTerminalStatus,
  assertAuthenticatedUid,
  assertSelfOnlyTarget,
  cancelClientSubscriptions,
  assertCoachHasNoActiveClientSubscriptions,
  collectCoachClientRefs,
  collectCoachSubscriptionRefs,
  wipeConversationsForUid,
  wipeLegacyCoachMessages,
  wipeDocumentTree,
  deleteStoragePrefix,
  deleteUserAccountForUid,
};
