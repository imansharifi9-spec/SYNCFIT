/**
 * Emulator tests for aiCompanionChat.
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";
process.env.GCLOUD_PROJECT = process.env.GCLOUD_PROJECT || "syncfit-8441f";
process.env.GOOGLE_CLOUD_PROJECT =
  process.env.GOOGLE_CLOUD_PROJECT || "syncfit-8441f";

const { expect } = require("chai");
const admin = require("firebase-admin");
const { HttpsError } = require("firebase-functions/v2/https");

if (!admin.apps.length) {
  admin.initializeApp({ projectId: "syncfit-8441f" });
}

const {
  aiCompanionChatForUid,
  AI_COMPANION_HISTORY_LIMIT,
  AI_COMPANION_MAX_TOKENS,
  AI_COMPANION_MODEL,
} = require("../aiCompanionChat");

const db = admin.firestore();

async function clearUser(uid) {
  await admin.firestore().recursiveDelete(db.collection("users").doc(uid));
}

function activeEntitlement() {
  return { entitled: true, reason: "active_entitlement" };
}

function inactiveEntitlement() {
  return { entitled: false, reason: "subscription_status_none" };
}

describe("aiCompanionChat", function () {
  this.timeout(20000);

  before(function () {
    if (!process.env.FIRESTORE_EMULATOR_HOST) {
      throw new Error(
        "FIRESTORE_EMULATOR_HOST is not set — run via firebase emulators:exec"
      );
    }
  });

  beforeEach(async function () {
    await Promise.all([
      clearUser("ai-companion-entitled"),
      clearUser("ai-companion-free"),
      clearUser("ai-companion-rate"),
      clearUser("ai-companion-history"),
      clearUser("ai-companion-claude-fail"),
    ]);
  });

  it("entitled user's message succeeds and is saved under their uid", async function () {
    const uid = "ai-companion-entitled";
    let claudeCalls = 0;

    const result = await aiCompanionChatForUid(
      uid,
      { conversationId: "conv-1", message: "How is my training trending?" },
      {
        db,
        checkEntitlement: async () => activeEntitlement(),
        loadContext: async (seenUid) => {
          expect(seenUid).to.equal(uid);
          return { workoutCount: 3, mealCount: 8, recentWorkouts: [] };
        },
        callClaude: async ({ messages, maxTokens, model }) => {
          claudeCalls += 1;
          expect(maxTokens).to.equal(AI_COMPANION_MAX_TOKENS);
          expect(model).to.equal(AI_COMPANION_MODEL);
          expect(model).to.equal("claude-haiku-4-5-20251001");
          expect(messages[messages.length - 1]).to.deep.equal({
            role: "user",
            content: "How is my training trending?",
          });
          return "Your consistency is improving. Keep protein steady and progress one lift this week.";
        },
        getApiKey: () => "mock-key",
        now: new Date("2026-07-16T12:00:00.000Z"),
      }
    );

    expect(claudeCalls).to.equal(1);
    expect(result.conversationId).to.equal("conv-1");
    expect(result.response).to.match(/consistency/i);

    const messages = await db
      .collection("users")
      .doc(uid)
      .collection("aiCompanionConversations")
      .doc("conv-1")
      .collection("messages")
      .orderBy("createdAt")
      .get();

    expect(messages.docs).to.have.length(2);
    expect(messages.docs[0].data()).to.include({
      role: "user",
      text: "How is my training trending?",
      userId: uid,
    });
    expect(messages.docs[1].data()).to.include({
      role: "assistant",
      userId: uid,
    });

    const otherUserMessages = await db
      .collection("users")
      .doc("some-other-user")
      .collection("aiCompanionConversations")
      .get();
    expect(otherUserMessages.empty).to.equal(true);
  });

  it("non-entitled user is rejected before any AI call", async function () {
    const uid = "ai-companion-free";
    let claudeCalls = 0;
    let contextCalls = 0;
    let thrown = null;

    try {
      await aiCompanionChatForUid(
        uid,
        { conversationId: "conv-1", message: "Help me." },
        {
          db,
          checkEntitlement: async () => inactiveEntitlement(),
          loadContext: async () => {
            contextCalls += 1;
            return {};
          },
          callClaude: async () => {
            claudeCalls += 1;
            return "should not happen";
          },
          getApiKey: () => "should-not-be-read",
        }
      );
    } catch (err) {
      thrown = err;
    }

    expect(thrown).to.be.instanceOf(HttpsError);
    expect(thrown.code).to.equal("permission-denied");
    expect(contextCalls).to.equal(0);
    expect(claudeCalls).to.equal(0);
  });

  it("rate limit blocks further calls with resource-exhausted", async function () {
    const uid = "ai-companion-rate";
    let claudeCalls = 0;
    const deps = {
      db,
      checkEntitlement: async () => activeEntitlement(),
      loadContext: async () => ({}),
      callClaude: async () => {
        claudeCalls += 1;
        return "ok";
      },
      getApiKey: () => "mock-key",
      now: new Date("2026-07-16T12:10:00.000Z"),
      hourlyLimit: 2,
    };

    await aiCompanionChatForUid(uid, { conversationId: "conv-rate", message: "one" }, deps);
    await aiCompanionChatForUid(uid, { conversationId: "conv-rate", message: "two" }, deps);

    let thrown = null;
    try {
      await aiCompanionChatForUid(uid, { conversationId: "conv-rate", message: "three" }, deps);
    } catch (err) {
      thrown = err;
    }

    expect(thrown).to.be.instanceOf(HttpsError);
    expect(thrown.code).to.equal("resource-exhausted");
    expect(String(thrown.message)).to.match(/limit/i);
    expect(claudeCalls).to.equal(2);
  });

  it("conversation history sent to Claude is capped", async function () {
    const uid = "ai-companion-history";
    const conversationId = "conv-history";
    const base = db
      .collection("users")
      .doc(uid)
      .collection("aiCompanionConversations")
      .doc(conversationId);

    await base.set({ userId: uid, id: conversationId });
    const batch = db.batch();
    const totalHistory = AI_COMPANION_HISTORY_LIMIT + 10;
    for (let i = 0; i < totalHistory; i += 1) {
      batch.set(base.collection("messages").doc(`m-${String(i).padStart(3, "0")}`), {
        role: i % 2 === 0 ? "user" : "assistant",
        text: `history ${i}`,
        userId: uid,
        createdAt: admin.firestore.Timestamp.fromMillis(1_000_000 + i),
      });
    }
    await batch.commit();

    let sentMessages = null;
    await aiCompanionChatForUid(
      uid,
      { conversationId, message: "new message" },
      {
        db,
        checkEntitlement: async () => activeEntitlement(),
        loadContext: async () => ({}),
        callClaude: async ({ messages }) => {
          sentMessages = messages;
          return "capped";
        },
        getApiKey: () => "mock-key",
        now: new Date("2026-07-16T13:00:00.000Z"),
      }
    );

    expect(sentMessages).to.have.length(AI_COMPANION_HISTORY_LIMIT + 1);
    expect(sentMessages[0].content).to.equal("history 10");
    expect(sentMessages[sentMessages.length - 1]).to.deep.equal({
      role: "user",
      content: "new message",
    });
  });

  it("passes Claude Haiku 4.5 model string through on every chat call", async function () {
    const uid = "ai-companion-entitled";
    const seenModels = [];

    await aiCompanionChatForUid(
      uid,
      { conversationId: "conv-haiku", message: "What should I focus on this week?" },
      {
        db,
        checkEntitlement: async () => activeEntitlement(),
        loadContext: async () => ({ workoutCount: 2, mealCount: 4 }),
        callClaude: async ({ model, messages, maxTokens }) => {
          seenModels.push(model);
          expect(model).to.equal("claude-haiku-4-5-20251001");
          expect(maxTokens).to.equal(AI_COMPANION_MAX_TOKENS);
          expect(messages[messages.length - 1].content).to.match(/focus/i);
          return "Prioritize protein consistency and one progressive overload lift.";
        },
        getApiKey: () => "mock-key",
        now: new Date("2026-07-16T15:00:00.000Z"),
      }
    );

    await aiCompanionChatForUid(
      uid,
      { conversationId: "conv-haiku", message: "Am I eating enough protein?" },
      {
        db,
        checkEntitlement: async () => activeEntitlement(),
        loadContext: async () => ({ workoutCount: 2, mealCount: 4 }),
        callClaude: async ({ model }) => {
          seenModels.push(model);
          return "Bump protein toward your daily target — you're a bit short based on recent meals.";
        },
        getApiKey: () => "mock-key",
        now: new Date("2026-07-16T15:01:00.000Z"),
      }
    );

    expect(seenModels).to.deep.equal([
      "claude-haiku-4-5-20251001",
      "claude-haiku-4-5-20251001",
    ]);
    expect(AI_COMPANION_MODEL).to.equal("claude-haiku-4-5-20251001");

    const messages = await db
      .collection("users")
      .doc(uid)
      .collection("aiCompanionConversations")
      .doc("conv-haiku")
      .collection("messages")
      .orderBy("createdAt")
      .get();
    expect(messages.docs).to.have.length(4);
    expect(messages.docs[1].data().role).to.equal("assistant");
    expect(messages.docs[3].data().text).to.match(/protein/i);
  });

  it("Claude provider credit-balance failure surfaces failed-precondition, not INTERNAL", async function () {
    const uid = "ai-companion-claude-fail";
    await clearUser(uid);

    let thrown = null;
    try {
      await aiCompanionChatForUid(
        uid,
        { conversationId: "conv-billing", message: "How is my progress?" },
        {
          db,
          checkEntitlement: async () => activeEntitlement(),
          loadContext: async () => ({ workoutCount: 1 }),
          callClaude: async () => {
            // Mirrors what claudeClient throws after Anthropic returns
            // "Your credit balance is too low..." — previously this became
            // HttpsError("internal", ...) and the client only saw INTERNAL.
            const err = new Error(
              "AI Coach is temporarily unavailable: the AI provider account needs billing credits. Please try again after credits are added."
            );
            err.code = "failed-precondition";
            err.raw = JSON.stringify({
              type: "error",
              error: {
                type: "invalid_request_error",
                message:
                  "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits.",
              },
            });
            throw err;
          },
          getApiKey: () => "mock-key",
          now: new Date("2026-07-16T14:00:00.000Z"),
        }
      );
    } catch (err) {
      thrown = err;
    }

    expect(thrown).to.be.instanceOf(HttpsError);
    expect(thrown.code).to.equal("failed-precondition");
    expect(thrown.code).to.not.equal("internal");
    expect(String(thrown.message)).to.match(/billing credits/i);

    const messages = await db
      .collection("users")
      .doc(uid)
      .collection("aiCompanionConversations")
      .doc("conv-billing")
      .collection("messages")
      .get();
    expect(messages.empty).to.equal(true);
  });

  it("unclassified Claude failures become unavailable (never bare internal)", async function () {
    const uid = "ai-companion-claude-fail";
    await clearUser(uid);

    let thrown = null;
    try {
      await aiCompanionChatForUid(
        uid,
        { conversationId: "conv-mystery", message: "Hello" },
        {
          db,
          checkEntitlement: async () => activeEntitlement(),
          loadContext: async () => ({}),
          callClaude: async () => {
            const err = new Error("something exploded");
            err.code = "internal"; // legacy path that used to mask as INTERNAL
            throw err;
          },
          getApiKey: () => "mock-key",
          now: new Date("2026-07-16T14:05:00.000Z"),
        }
      );
    } catch (err) {
      thrown = err;
    }

    expect(thrown).to.be.instanceOf(HttpsError);
    expect(thrown.code).to.equal("unavailable");
    expect(String(thrown.message)).to.match(/something exploded/i);
  });
});
