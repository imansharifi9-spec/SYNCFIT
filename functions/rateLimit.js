/**
 * Shared Firestore-backed rate limiting (hourly or daily windows).
 * Pattern mirrors aiCompanionChat.reserveRateLimit.
 */

const { FieldValue, Timestamp } = require("firebase-admin/firestore");
const { HttpsError } = require("firebase-functions/v2/https");

/**
 * @param {Date} date
 * @param {"hour"|"day"} window
 * @returns {string}
 */
function windowKey(date, window) {
  if (window === "day") {
    return date.toISOString().slice(0, 10).replace(/-/g, "");
  }
  return date.toISOString().slice(0, 13).replace(/[-T:]/g, "");
}

/**
 * @param {Date} date
 * @param {"hour"|"day"} window
 * @returns {Date}
 */
function windowStart(date, window) {
  if (window === "day") {
    return new Date(
      Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), 0, 0, 0, 0)
    );
  }
  return new Date(
    Date.UTC(
      date.getUTCFullYear(),
      date.getUTCMonth(),
      date.getUTCDate(),
      date.getUTCHours(),
      0,
      0,
      0
    )
  );
}

/**
 * Atomically reserve one unit in a rate-limit bucket.
 *
 * @param {object} args
 * @param {FirebaseFirestore.Firestore} args.db
 * @param {FirebaseFirestore.DocumentReference} args.ref Bucket document ref
 * @param {Date} args.now
 * @param {number} args.limit
 * @param {"hour"|"day"} [args.window="hour"]
 * @param {string} args.message Client-facing exhausted message
 * @param {string} [args.logLabel="rateLimit"]
 * @returns {Promise<{ allowed: true, count: number, key: string }>}
 */
async function reserveRateLimit({
  db,
  ref,
  now,
  limit,
  window = "hour",
  message,
  logLabel = "rateLimit",
}) {
  const key = windowKey(now, window);
  const result = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = snap.exists ? Number(snap.data().count || 0) : 0;
    if (current >= limit) {
      return { allowed: false, count: current, key };
    }
    tx.set(
      ref,
      {
        count: current + 1,
        windowKey: key,
        windowStartedAt: Timestamp.fromDate(windowStart(now, window)),
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true }
    );
    return { allowed: true, count: current + 1, key };
  });

  if (!result.allowed) {
    console.warn(
      `[${logLabel}] Rate limit hit path=${ref.path} window=${key} count=${result.count} limit=${limit}`
    );
    throw new HttpsError("resource-exhausted", message);
  }
  return result;
}

module.exports = {
  windowKey,
  windowStart,
  reserveRateLimit,
};
