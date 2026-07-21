/**
 * Firestore rules tests for AI Companion conversation isolation.
 */

process.env.FIRESTORE_EMULATOR_HOST =
  process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8080";

const fs = require("fs");
const path = require("path");
const { expect } = require("chai");
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require("@firebase/rules-unit-testing");
const {
  collection,
  doc,
  getDoc,
  getDocs,
  setDoc,
  Timestamp,
} = require("firebase/firestore");

describe("aiCompanionConversations Firestore rules", function () {
  this.timeout(20000);

  let testEnv;

  before(async function () {
    const [host, portRaw] = process.env.FIRESTORE_EMULATOR_HOST.split(":");
    testEnv = await initializeTestEnvironment({
      projectId: "syncfit-8441f-ai-companion-rules",
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
  });

  function userDb(uid) {
    return testEnv.authenticatedContext(uid).firestore();
  }

  it("allows a user to read and write their own AI Companion conversation", async function () {
    const db = userDb("user-a");
    const conversation = doc(
      db,
      "users/user-a/aiCompanionConversations/conv-1"
    );
    const message = doc(
      db,
      "users/user-a/aiCompanionConversations/conv-1/messages/msg-1"
    );

    await assertSucceeds(
      setDoc(conversation, {
        id: "conv-1",
        userId: "user-a",
        title: "My plan",
        createdAt: Timestamp.now(),
        updatedAt: Timestamp.now(),
      })
    );

    await assertSucceeds(
      setDoc(message, {
        role: "user",
        text: "How should I train today?",
        userId: "user-a",
        createdAt: Timestamp.now(),
      })
    );

    await assertSucceeds(getDoc(conversation));
    const snap = await assertSucceeds(
      getDocs(collection(db, "users/user-a/aiCompanionConversations/conv-1/messages"))
    );
    expect(snap.docs).to.have.length(1);
  });

  it("denies reading or writing another user's AI Companion conversation", async function () {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const adminDb = context.firestore();
      await setDoc(doc(adminDb, "users/user-a/aiCompanionConversations/conv-1"), {
        id: "conv-1",
        userId: "user-a",
        title: "Private",
      });
      await setDoc(
        doc(adminDb, "users/user-a/aiCompanionConversations/conv-1/messages/msg-1"),
        {
          role: "assistant",
          text: "Private coaching",
          userId: "user-a",
          createdAt: Timestamp.now(),
        }
      );
    });

    const db = userDb("user-b");
    await assertFails(
      getDoc(doc(db, "users/user-a/aiCompanionConversations/conv-1"))
    );
    await assertFails(
      getDocs(collection(db, "users/user-a/aiCompanionConversations/conv-1/messages"))
    );
    await assertFails(
      setDoc(doc(db, "users/user-a/aiCompanionConversations/conv-1/messages/evil"), {
        role: "user",
        text: "cross-account write",
        userId: "user-a",
        createdAt: Timestamp.now(),
      })
    );
    await assertFails(
      setDoc(doc(db, "users/user-b/aiCompanionConversations/conv-evil"), {
        id: "conv-evil",
        userId: "user-a",
        title: "forged owner",
      })
    );
  });
});
