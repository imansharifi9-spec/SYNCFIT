/**
 * Stripe Connect webhook — signature-verified account.updated → coach flags.
 */

const {
  getFirestore,
  FieldValue,
  Timestamp,
} = require("firebase-admin/firestore");
const Stripe = require("stripe");
const { resolvePlatformFeePercent } = require("./createCheckoutSession");
const { connectionDocId } = require("./coachClientAccess");

const TRANSACTIONAL_SUBSCRIPTION_EVENT_TYPES = new Set([
  "checkout.session.completed",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "invoice.payment_failed",
]);

/**
 * @param {string} secretKey
 * @returns {import("stripe").Stripe}
 */
function createStripeClient(secretKey) {
  return new Stripe(secretKey);
}

function stripeId(value) {
  if (typeof value === "string") return value;
  return value && typeof value.id === "string" ? value.id : "";
}

function validUid(value) {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= 128 &&
    !value.includes("/")
  );
}

function subscriptionPeriodEndSeconds(subscription) {
  const candidates = [];
  if (Number.isInteger(subscription && subscription.current_period_end)) {
    candidates.push(subscription.current_period_end);
  }
  const items =
    subscription &&
    subscription.items &&
    Array.isArray(subscription.items.data)
      ? subscription.items.data
      : [];
  for (const item of items) {
    if (Number.isInteger(item.current_period_end)) {
      candidates.push(item.current_period_end);
    }
  }
  return candidates.length ? Math.max(...candidates) : null;
}

function invoicePeriodEndSeconds(invoice) {
  const lines =
    invoice && invoice.lines && Array.isArray(invoice.lines.data)
      ? invoice.lines.data
      : [];
  const candidates = lines
    .map((line) => line && line.period && line.period.end)
    .filter(Number.isInteger);
  return candidates.length ? Math.max(...candidates) : null;
}

async function findSubscriptionRefInTransaction(
  db,
  transaction,
  stripeSubscriptionId
) {
  const preferred = db.collection("coachSubscriptions").doc(stripeSubscriptionId);
  const preferredSnap = await transaction.get(preferred);
  if (preferredSnap.exists) return preferred;

  const fallbackQuery = db
    .collection("coachSubscriptions")
    .where("stripeSubscriptionId", "==", stripeSubscriptionId)
    .limit(1);
  const fallback = await transaction.get(fallbackQuery);
  return fallback.empty ? null : fallback.docs[0].ref;
}

async function prepareCheckoutCompleted(session, getStripe) {
  const metadata = session && session.metadata;
  const clientUid = metadata && metadata.clientUid;
  const coachUid = metadata && metadata.coachUid;
  if (!validUid(clientUid) || !validUid(coachUid) || clientUid === coachUid) {
    throw Object.assign(
      new Error("checkout.session.completed has invalid participant metadata."),
      { statusCode: 400 }
    );
  }

  const stripeSubscriptionId = stripeId(session.subscription);
  if (!/^sub_[A-Za-z0-9]+$/.test(stripeSubscriptionId)) {
    throw Object.assign(
      new Error("checkout.session.completed missing subscription id."),
      { statusCode: 400 }
    );
  }
  if (typeof getStripe !== "function") {
    throw new Error("Stripe client is required to retrieve the subscription.");
  }
  const subscription = await getStripe().subscriptions.retrieve(
    stripeSubscriptionId
  );
  if (stripeId(subscription) !== stripeSubscriptionId) {
    throw Object.assign(
      new Error("Checkout and retrieved subscription ids do not match."),
      { statusCode: 400 }
    );
  }
  const stripeCustomerId =
    stripeId(session.customer) || stripeId(subscription && subscription.customer);
  if (!/^cus_[A-Za-z0-9]+$/.test(stripeCustomerId)) {
    throw Object.assign(
      new Error("checkout.session.completed missing customer id."),
      { statusCode: 400 }
    );
  }

  const rawFee = metadata && metadata.platformFeePercent;
  const numericFee =
    typeof rawFee === "string" && rawFee.trim() !== "" ? Number(rawFee) : NaN;
  const platformFeePercentAtSignup = resolvePlatformFeePercent({
    platformFeePercent: numericFee,
  });
  const subscriptionMetadata = subscription && subscription.metadata;
  if (
    !subscriptionMetadata ||
    subscriptionMetadata.clientUid !== clientUid ||
    subscriptionMetadata.coachUid !== coachUid ||
    String(subscriptionMetadata.platformFeePercent) !== String(rawFee)
  ) {
    throw Object.assign(
      new Error("Checkout and subscription metadata do not match."),
      { statusCode: 400 }
    );
  }

  const subscriptionCustomerId = stripeId(subscription.customer);
  if (
    subscriptionCustomerId &&
    subscriptionCustomerId !== stripeCustomerId
  ) {
    throw Object.assign(
      new Error("Checkout and subscription customer ids do not match."),
      { statusCode: 400 }
    );
  }
  const periodEnd = subscriptionPeriodEndSeconds(subscription);
  if (!periodEnd) {
    throw new Error("Stripe subscription missing current period end.");
  }

  return {
    clientUid,
    coachUid,
    stripeSubscriptionId,
    stripeCustomerId,
    status:
      subscription && typeof subscription.status === "string"
        ? subscription.status
        : "active",
    currentPeriodEnd: Timestamp.fromMillis(periodEnd * 1000),
    platformFeePercentAtSignup,
  };
}

function subscriptionUpdatePayload(subscription, deleted) {
  const periodEnd = subscriptionPeriodEndSeconds(subscription);
  const update = {
    status:
      deleted === true
        ? "canceled"
        : typeof subscription.status === "string"
          ? subscription.status
          : "active",
    updatedAt: FieldValue.serverTimestamp(),
  };
  if (periodEnd) {
    update.currentPeriodEnd = Timestamp.fromMillis(periodEnd * 1000);
  }
  if (deleted === true) {
    update.endedAt = FieldValue.serverTimestamp();
  }
  return update;
}

function invoiceSubscriptionId(invoice) {
  return (
    stripeId(invoice && invoice.subscription) ||
    stripeId(
      invoice &&
        invoice.parent &&
        invoice.parent.subscription_details &&
        invoice.parent.subscription_details.subscription
    )
  );
}

function eventLedgerData(event, coachUid) {
  return {
    id: event.id,
    type: event.type || null,
    processedAt: FieldValue.serverTimestamp(),
    livemode: event.livemode === true,
    coachUid,
  };
}

function displayName(data, fields, fallback) {
  for (const field of fields) {
    if (data && typeof data[field] === "string" && data[field].trim()) {
      return data[field].trim();
    }
  }
  return fallback;
}

function connectionPermissions(connection) {
  const permissions =
    connection &&
    connection.permissions &&
    typeof connection.permissions === "object" &&
    !Array.isArray(connection.permissions)
      ? connection.permissions
      : {};
  const present =
    connection &&
    (connection.permissions !== undefined ||
      connection.shareWorkouts !== undefined ||
      connection.shareNutrition !== undefined ||
      connection.shareProgress !== undefined);
  return {
    workouts: present
      ? permissions.workouts === true || connection.shareWorkouts === true
      : true,
    nutrition:
      permissions.nutrition === true ||
      (connection && connection.shareNutrition === true),
    progress:
      permissions.progress === true ||
      (connection && connection.shareProgress === true),
  };
}

async function handleTransactionalSubscriptionEvent(event, deps) {
  const db = deps.db;
  const eventRef = db.collection("stripeWebhookEvents").doc(event.id);
  const existing = await eventRef.get();
  if (existing.exists) {
    return { handled: false, duplicate: true };
  }
  let completed = null;
  if (event.type === "checkout.session.completed") {
    completed = await prepareCheckoutCompleted(
      event.data && event.data.object,
      deps.getStripe
    );
  }

  return db.runTransaction(async (transaction) => {
    const eventSnap = await transaction.get(eventRef);
    if (eventSnap.exists) {
      return { handled: false, duplicate: true };
    }

    let coachUid = null;
    if (completed) {
      coachUid = completed.coachUid;
      const subscriptionRef = db
        .collection("coachSubscriptions")
        .doc(completed.stripeSubscriptionId);
      const coachRef = db.collection("coaches").doc(completed.coachUid);
      const clientRef = db.collection("users").doc(completed.clientUid);
      const connectionRef = db
        .collection("coach_clients")
        .doc(connectionDocId(completed.clientUid, completed.coachUid));
      const [subscriptionSnap, coachSnap, clientSnap, connectionSnap] =
        await Promise.all([
          transaction.get(subscriptionRef),
          transaction.get(coachRef),
          transaction.get(clientRef),
          transaction.get(connectionRef),
        ]);
      if (!coachSnap.exists) {
        throw Object.assign(new Error("Checkout coach no longer exists."), {
          statusCode: 400,
        });
      }

      const subscriptionData = {
        ...completed,
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (!subscriptionSnap.exists) {
        subscriptionData.createdAt = FieldValue.serverTimestamp();
      }
      transaction.set(subscriptionRef, subscriptionData, { merge: true });

      const existingConnection = connectionSnap.exists
        ? connectionSnap.data() || {}
        : {};
      const permissions = connectionPermissions(existingConnection);
      transaction.set(
        connectionRef,
        {
          coachId: completed.coachUid,
          clientId: completed.clientUid,
          clientUserID: completed.clientUid,
          coachName: displayName(
            coachSnap.data(),
            ["name", "profileName"],
            "Coach"
          ),
          clientName: displayName(
            clientSnap.exists ? clientSnap.data() : null,
            ["profileName", "name", "displayName"],
            displayName(existingConnection, ["clientName"], "Client")
          ),
          connectedAt:
            existingConnection.connectedAt || FieldValue.serverTimestamp(),
          permissions,
          shareWorkouts: permissions.workouts,
          shareNutrition: permissions.nutrition,
          shareProgress: permissions.progress,
          status: "active",
          clientInitiatedContact: true,
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
    } else {
      const object = event.data && event.data.object;
      const stripeSubscriptionId =
        event.type === "invoice.payment_failed"
          ? invoiceSubscriptionId(object)
          : stripeId(object);
      if (!/^sub_[A-Za-z0-9]+$/.test(stripeSubscriptionId)) {
        throw Object.assign(
          new Error(`${event.type} missing subscription id.`),
          { statusCode: 400 }
        );
      }
      const subscriptionRef = await findSubscriptionRefInTransaction(
        db,
        transaction,
        stripeSubscriptionId
      );
      if (!subscriptionRef) {
        throw new Error(
          `Coach subscription ${stripeSubscriptionId} is not available yet; retry event.`
        );
      }

      let update;
      if (event.type === "invoice.payment_failed") {
        update = {
          status: "past_due",
          paymentFailedAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        };
        const periodEnd = invoicePeriodEndSeconds(object);
        if (periodEnd) {
          update.currentPeriodEnd = Timestamp.fromMillis(periodEnd * 1000);
        }
      } else {
        update = subscriptionUpdatePayload(
          object,
          event.type === "customer.subscription.deleted"
        );
      }
      transaction.set(subscriptionRef, update, { merge: true });
    }

    transaction.set(eventRef, eventLedgerData(event, coachUid));
    return { handled: true, duplicate: false, coachUid };
  });
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
  if (TRANSACTIONAL_SUBSCRIPTION_EVENT_TYPES.has(event.type)) {
    return handleTransactionalSubscriptionEvent(event, {
      ...deps,
      db,
      logger,
    });
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
  } else if (typeof logger.info === "function") {
    logger.info(`[stripeWebhook] Ignoring unsupported event type=${event.type}`);
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
  subscriptionPeriodEndSeconds,
  invoiceSubscriptionId,
  handleStripeEvent,
  stripeWebhookHandler,
};
