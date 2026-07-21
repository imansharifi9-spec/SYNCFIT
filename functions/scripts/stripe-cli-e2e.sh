#!/usr/bin/env bash
# End-to-end: Stripe CLI listen → local webhook → Firestore emulator.
# Does not print secret values.
set -eu
export PATH="$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [ -z "${STRIPE_SECRET_KEY:-}" ]; then
  TMP_KEY="$(mktemp)"
  npx -y firebase-tools@latest functions:secrets:access STRIPE_SECRET_KEY --project syncfit-8441f >"$TMP_KEY" 2>/dev/null
  STRIPE_SECRET_KEY="$(tr -d '\r\n' <"$TMP_KEY")"
  rm -f "$TMP_KEY"
fi
export STRIPE_SECRET_KEY
case "$STRIPE_SECRET_KEY" in
  sk_test_*) echo "STRIPE_SECRET_KEY loaded (len=${#STRIPE_SECRET_KEY})" ;;
  *) echo "Failed to load STRIPE_SECRET_KEY"; exit 1 ;;
esac

export FIRESTORE_EMULATOR_HOST="${FIRESTORE_EMULATOR_HOST:-127.0.0.1:8080}"
export GCLOUD_PROJECT=syncfit-8441f
export GOOGLE_CLOUD_PROJECT=syncfit-8441f
export PORT=8787
COACH_UID="${E2E_COACH_UID:-stripe-cli-e2e-coach}"
export E2E_COACH_UID="$COACH_UID"

LISTEN_LOG="$(mktemp)"
SERVER_LOG="$(mktemp)"
cleanup() {
  [ -n "${LISTEN_PID:-}" ] && kill "$LISTEN_PID" 2>/dev/null || true
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "${LISTEN_PID:-}" ] && wait "$LISTEN_PID" 2>/dev/null || true
  [ -n "${SERVER_PID:-}" ] && wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$LISTEN_LOG" "$SERVER_LOG" "${TMP_KEY:-}"
}
trap cleanup EXIT

if ! nc -z 127.0.0.1 8080 2>/dev/null; then
  echo "Firestore emulator not running on 8080 — start it first"
  exit 1
fi
echo "Firestore emulator ready on 8080"

echo "COMMAND: stripe listen --api-key \$STRIPE_SECRET_KEY --events account.updated --forward-to http://127.0.0.1:${PORT}/stripeWebhook"
stripe listen \
  --api-key "$STRIPE_SECRET_KEY" \
  --events account.updated \
  --forward-to "http://127.0.0.1:${PORT}/stripeWebhook" \
  >"$LISTEN_LOG" 2>&1 &
LISTEN_PID=$!

WHSEC=""
i=0
while [ "$i" -lt 45 ]; do
  if WHSEC="$(rg -o 'whsec_[A-Za-z0-9]+' "$LISTEN_LOG" | head -1)"; then
    [ -n "$WHSEC" ] && break
  fi
  i=$((i + 1))
  sleep 1
done
if [ -z "$WHSEC" ]; then
  echo "Failed to capture whsec from stripe listen log:"
  cat "$LISTEN_LOG"
  exit 1
fi
export STRIPE_WEBHOOK_SECRET="$WHSEC"
echo "STRIPE_WEBHOOK_SECRET captured from listen session (len=${#STRIPE_WEBHOOK_SECRET})"

# Start webhook server with the SAME signing secret as this listen session.
if [ -z "${E2E_ACCOUNT_ID:-}" ]; then
  echo "Set E2E_ACCOUNT_ID to an already-enabled test connected account."
  exit 1
fi
ACCOUNT_ID="$E2E_ACCOUNT_ID"
export E2E_ACCOUNT_ID="$ACCOUNT_ID"
echo "E2E_ACCOUNT_ID=$E2E_ACCOUNT_ID"
node "$ROOT/functions/scripts/stripe-webhook-e2e.js" --serve >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
sleep 2

cd "$ROOT/functions"
node <<'NODE'
const admin = require("firebase-admin");
const Stripe = require("stripe");
if (!admin.apps.length) admin.initializeApp({ projectId: "syncfit-8441f" });
const db = admin.firestore();
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const coachUid = process.env.E2E_COACH_UID || "stripe-cli-e2e-coach";
const accountId = process.env.E2E_ACCOUNT_ID;
const json = (value) =>
  JSON.stringify(
    value,
    (key, item) =>
      item && typeof item.toDate === "function"
        ? item.toDate().toISOString()
        : item,
    2
  );

(async () => {
  const account = await stripe.accounts.retrieve(accountId);
  console.log(
    "STRIPE_ACCOUNT_BEFORE",
    json({
      id: account.id,
      charges_enabled: account.charges_enabled,
      payouts_enabled: account.payouts_enabled,
      details_submitted: account.details_submitted,
    })
  );
  if (account.id !== accountId || account.charges_enabled !== true) {
    throw new Error(
      "E2E account must exist in test mode and already have charges_enabled=true"
    );
  }

  const staleEvents = await db
    .collection("stripeWebhookEvents")
    .where("coachUid", "==", coachUid)
    .get();
  await Promise.all(staleEvents.docs.map((doc) => doc.ref.delete()));

  await db.collection("coaches").doc(coachUid).set({
    coachId: coachUid,
    name: "Stripe CLI E2E Coach",
    stripeConnectedAccountId: accountId,
    stripeChargesEnabled: false,
    stripePayoutsEnabled: false,
  });
  console.log("SEEDED_COACH", coachUid);
  const before = await db.collection("coaches").doc(coachUid).get();
  console.log("RAW_FIRESTORE_BEFORE", json({ id: before.id, ...before.data() }));

  const { spawnSync } = require("child_process");
  const nonce = String(Date.now());
  const trigger = spawnSync(
    process.env.HOME + "/.local/bin/stripe",
    [
      "accounts",
      "update",
      accountId,
      "--data",
      `metadata[syncfit_e2e_nonce]=${nonce}`,
      "--confirm",
      "--api-key",
      process.env.STRIPE_SECRET_KEY,
    ],
    { encoding: "utf8" }
  );
  if (trigger.status !== 0) {
    console.error(trigger.stderr || trigger.stdout);
    process.exit(trigger.status || 1);
  }
  const updatedAccount = JSON.parse(trigger.stdout);
  if (updatedAccount.error) {
    throw new Error(
      `Stripe account update failed: ${updatedAccount.error.message || "unknown error"}`
    );
  }
  console.log(
    "COMMAND: stripe accounts update " +
      accountId +
      " " +
      "--data metadata[syncfit_e2e_nonce]=<timestamp> --confirm " +
      "--api-key $STRIPE_SECRET_KEY"
  );
  console.log(
    "CLI_ACCOUNT_UPDATE",
    json({
      exitStatus: trigger.status,
      id: updatedAccount.id,
      charges_enabled: updatedAccount.charges_enabled,
      payouts_enabled: updatedAccount.payouts_enabled,
      syncfit_e2e_nonce: updatedAccount.metadata?.syncfit_e2e_nonce,
    })
  );

  for (let i = 0; i < 45; i++) {
    await new Promise((r) => setTimeout(r, 1000));
    const doc = await db.collection("coaches").doc(coachUid).get();
    const data = doc.data() || {};
    const events = await db
      .collection("stripeWebhookEvents")
      .where("coachUid", "==", coachUid)
      .limit(5)
      .get();
    if (!events.empty) {
      console.log("WEBHOOK_EVENTS_FOR_COACH", events.size);
      console.log("RAW_FIRESTORE_AFTER", json({ id: doc.id, ...data }));
      console.log(
        "EVENT_IDS",
        JSON.stringify(events.docs.map((d) => ({ id: d.id, type: d.data().type })))
      );
      if (
        data.stripeConnectedAccountId !== accountId ||
        data.stripeChargesEnabled !== true
      ) {
        throw new Error(
          "Webhook evidence failed: account ID changed or charges flag did not become true"
        );
      }
      process.exit(0);
    }
  }
  console.error("Timed out waiting for stripe listen → webhook → Firestore");
  console.error("--- listen log ---");
  process.exit(1);
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
NODE
