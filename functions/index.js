const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const { initializeApp, getApps } = require("firebase-admin/app");
const {
  checkSubscriptionEntitlementForUid,
} = require("./subscriptionGate");
const { evaluateSubscriptionEntitlement } = require("./entitlement");
const {
  generateWorkoutProgramForUid,
} = require("./generateWorkoutProgram");
const {
  aiCompanionChatForUid,
} = require("./aiCompanionChat");
const {
  generateCoachRoutineDraftForUid,
} = require("./generateCoachRoutineDraft");
const {
  generateClientInsightsForUid,
} = require("./generateClientInsights");
const {
  createCoachStripeAccountForUid,
  createStripeClient,
} = require("./createCoachStripeAccount");
const {
  stripeWebhookHandler,
  createStripeClient: createStripeWebhookClient,
} = require("./stripeWebhook");
const {
  createCheckoutSessionForUid,
} = require("./createCheckoutSession");
const {
  deleteUserAccountForUid,
  assertSelfOnlyTarget,
} = require("./deleteUserAccount");
const {
  resolveExerciseMediaForName,
  cleanupMismatchedExerciseMediaCache,
  MEDIA_LOGIC_VERSION,
  MIN_REASONABLE_SCORE,
} = require("./resolveExerciseMedia");

if (!getApps().length) {
  initializeApp({
    projectId:
      process.env.GCLOUD_PROJECT ||
      process.env.GOOGLE_CLOUD_PROJECT ||
      "syncfit-8441f",
    // Required for Admin Storage wipes (deleteUserAccount). Matches iOS
    // GoogleService-Info.plist STORAGE_BUCKET.
    storageBucket:
      process.env.FIREBASE_STORAGE_BUCKET ||
      "syncfit-8441f.firebasestorage.app",
  });
}

const anthropicApiKey = defineSecret("ANTHROPIC_API_KEY");
const stripeSecretKey = defineSecret("STRIPE_SECRET_KEY");
const stripeWebhookSecret = defineSecret("STRIPE_WEBHOOK_SECRET");

/**
 * Callable used by clients (and at the start of future AI features).
 * Auth uid comes only from request.auth — never from the request body.
 */
const checkSubscriptionEntitlement = onCall(async (request) => {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError(
      "unauthenticated",
      "Sign in required to check SyncFit+ entitlement."
    );
  }

  // Intentionally ignore any client-supplied uid fields.
  const uid = request.auth.uid;
  return checkSubscriptionEntitlementForUid(uid);
});

/**
 * SyncFit+ gated AI weekly workout program generator.
 * Body: { goal: "progressive_overload" | "maintenance" | "strength" }
 */
const generateWorkoutProgram = onCall(
  {
    secrets: [anthropicApiKey],
    timeoutSeconds: 120,
    memory: "512MiB",
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in required to generate a workout program."
      );
    }

    const uid = request.auth.uid;
    const goal = request.data && request.data.goal;

    return generateWorkoutProgramForUid(
      uid,
      { goal },
      {
        getApiKey: () => anthropicApiKey.value(),
      }
    );
  }
);

/**
 * SyncFit+ gated AI Companion chat.
 * Body: { message: string, conversationId?: string }
 */
const aiCompanionChat = onCall(
  {
    secrets: [anthropicApiKey],
    timeoutSeconds: 120,
    memory: "512MiB",
  },
  async (request) => {
    try {
      if (!request.auth || !request.auth.uid) {
        throw new HttpsError(
          "unauthenticated",
          "Sign in required to use AI Coach."
        );
      }

      return await aiCompanionChatForUid(request.auth.uid, request.data || {}, {
        getApiKey: () => anthropicApiKey.value(),
      });
    } catch (err) {
      if (err instanceof HttpsError) {
        // Never let "internal" leave the function — Firebase masks those as bare INTERNAL.
        if (err.code === "internal") {
          console.error("[aiCompanionChat] remapping internal HttpsError", err.message);
          throw new HttpsError(
            "unavailable",
            err.message || "AI Coach is temporarily unavailable. Please try again."
          );
        }
        throw err;
      }
      console.error("[aiCompanionChat] unhandled error", err);
      throw new HttpsError(
        "unavailable",
        (err && err.message) ||
          "AI Coach is temporarily unavailable. Please try again."
      );
    }
  }
);

/**
 * Coach AI: draft a routine for a client (review before send).
 * Free for coaches — auth + data-sharing toggles + daily rate limit.
 * Body: { clientUserID: string, goal: "progressive_overload" | "maintenance" | "strength" }
 */
const generateCoachRoutineDraft = onCall(
  {
    secrets: [anthropicApiKey],
    timeoutSeconds: 120,
    memory: "512MiB",
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in required to draft an AI routine."
      );
    }

    return generateCoachRoutineDraftForUid(
      request.auth.uid,
      request.data || {},
      {
        getApiKey: () => anthropicApiKey.value(),
      }
    );
  }
);

/**
 * Coach AI: quick-scan client insights (Haiku).
 * Free for coaches — auth + data-sharing toggles + daily rate limit + cache.
 * Body: { clientUserID: string, forceRefresh?: boolean }
 */
const generateClientInsights = onCall(
  {
    secrets: [anthropicApiKey],
    timeoutSeconds: 60,
    memory: "512MiB",
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in required to generate client insights."
      );
    }

    return generateClientInsightsForUid(
      request.auth.uid,
      request.data || {},
      {
        getApiKey: () => anthropicApiKey.value(),
      }
    );
  }
);

/**
 * Resolve a demo GIF for an exercise name (ExerciseDB + Firestore cache).
 * Body: { exerciseName: string }
 */
const resolveExerciseMedia = onCall(async (request) => {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError(
      "unauthenticated",
      "Sign in required to resolve exercise media."
    );
  }

  const exerciseName =
    request.data && typeof request.data.exerciseName === "string"
      ? request.data.exerciseName
      : "";

  const result = await resolveExerciseMediaForName(exerciseName);
  return {
    status: result.status,
    gifUrl: result.gifUrl,
    matchedName: result.matchedName,
    targetMuscles: result.targetMuscles,
    // Deploy verification stamp — must match repo MEDIA_LOGIC_VERSION.
    mediaLogicVersion: MEDIA_LOGIC_VERSION,
    minReasonableScore: MIN_REASONABLE_SCORE,
  };
});

/**
 * One-time ops callable: purge exerciseMedia docs with weak/wrong matchedName.
 * Body: {} (auth required). Prefer the Node script for bulk admin use.
 */
const cleanupExerciseMediaCache = onCall(async (request) => {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError(
      "unauthenticated",
      "Sign in required to clean exercise media cache."
    );
  }
  const result = await cleanupMismatchedExerciseMediaCache();
  return {
    ...result,
    mediaLogicVersion: MEDIA_LOGIC_VERSION,
    minReasonableScore: MIN_REASONABLE_SCORE,
  };
});

/**
 * Coach Stripe Connect Express onboarding.
 * Body: {} — coach identity comes only from request.auth.uid.
 */
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

/**
 * Client hires a coach through Stripe subscription Checkout.
 * Body: { coachUid } — all pricing, account, and fee values come from Firestore.
 */
const createCheckoutSession = onCall(
  {
    secrets: [stripeSecretKey],
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in required to hire a coach."
      );
    }

    return createCheckoutSessionForUid(
      request.auth.uid,
      request.data || {},
      {
        getStripe: () => createStripeWebhookClient(stripeSecretKey.value()),
      }
    );
  }
);

/**
 * Stripe webhook (HTTP). Signature-verified; Admin SDK writes coach payout flags.
 * Configure Stripe to POST to this endpoint and set STRIPE_WEBHOOK_SECRET.
 */
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

/**
 * Delete the signed-in user's account (Firestore + Storage + Auth).
 * Body: {} — optional targetUid must match auth.uid or is permission-denied.
 * Coach accounts with non-terminal client subscriptions are blocked.
 */
const deleteUserAccount = onCall(
  {
    secrets: [stripeSecretKey],
    timeoutSeconds: 120,
    memory: "512MiB",
  },
  async (request) => {
    if (!request.auth || !request.auth.uid) {
      throw new HttpsError(
        "unauthenticated",
        "Sign in required to delete your account."
      );
    }

    const uid = request.auth.uid;
    assertSelfOnlyTarget(uid, request.data || {});

    return deleteUserAccountForUid(uid, {
      getStripe: () => createStripeWebhookClient(stripeSecretKey.value()),
    });
  }
);

module.exports = {
  checkSubscriptionEntitlement,
  checkSubscriptionEntitlementForUid,
  evaluateSubscriptionEntitlement,
  generateWorkoutProgram,
  generateWorkoutProgramForUid,
  aiCompanionChat,
  aiCompanionChatForUid,
  generateCoachRoutineDraft,
  generateCoachRoutineDraftForUid,
  generateClientInsights,
  generateClientInsightsForUid,
  createCoachStripeAccount,
  createCoachStripeAccountForUid,
  createCheckoutSession,
  createCheckoutSessionForUid,
  deleteUserAccount,
  deleteUserAccountForUid,
  stripeWebhook,
  resolveExerciseMedia,
  resolveExerciseMediaForName,
  cleanupExerciseMediaCache,
  cleanupMismatchedExerciseMediaCache,
  MEDIA_LOGIC_VERSION,
};
