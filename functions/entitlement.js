/**
 * Pure subscription entitlement evaluation — used by the callable Cloud Function
 * and covered by emulator/unit tests. Keeps AI feature gating consistent.
 */

/**
 * @param {object} input
 * @param {string|undefined|null} input.subscriptionStatus
 * @param {FirebaseFirestore.Timestamp|Date|string|number|null|undefined} input.subscriptionExpiresAt
 * @param {Date} [input.now]
 * @returns {{ entitled: boolean, reason: string, staleActive?: boolean }}
 */
function evaluateSubscriptionEntitlement({ subscriptionStatus, subscriptionExpiresAt, now = new Date() }) {
  const status =
    typeof subscriptionStatus === "string" ? subscriptionStatus.trim() : "";

  if (!status || status === "none") {
    return {
      entitled: false,
      reason: status === "none"
        ? "subscription_status_none"
        : "subscription_status_missing",
    };
  }

  if (status !== "active") {
    return {
      entitled: false,
      reason: `subscription_status_${status}`,
    };
  }

  const expiresAt = coerceToDate(subscriptionExpiresAt);
  if (!expiresAt) {
    return {
      entitled: false,
      reason: "subscription_expires_at_missing",
    };
  }

  if (expiresAt.getTime() <= now.getTime()) {
    return {
      entitled: false,
      reason: "subscription_expired_stale_active",
      staleActive: true,
    };
  }

  return {
    entitled: true,
    reason: "active_entitlement",
  };
}

/**
 * @param {unknown} value
 * @returns {Date|null}
 */
function coerceToDate(value) {
  if (value == null) return null;
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? null : value;
  }
  // Firestore Timestamp
  if (typeof value === "object" && typeof value.toDate === "function") {
    const d = value.toDate();
    return d instanceof Date && !Number.isNaN(d.getTime()) ? d : null;
  }
  if (typeof value === "object" && typeof value.seconds === "number") {
    const d = new Date(value.seconds * 1000);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  if (typeof value === "number") {
    // Treat as ms if large, otherwise seconds
    const ms = value > 1e12 ? value : value * 1000;
    const d = new Date(ms);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  if (typeof value === "string") {
    const d = new Date(value);
    return Number.isNaN(d.getTime()) ? null : d;
  }
  return null;
}

module.exports = {
  evaluateSubscriptionEntitlement,
  coerceToDate,
};
