#!/usr/bin/env bash
# Load STRIPE_SECRET_KEY from Firebase Secret Manager into the environment
# without printing it. Usage: source functions/scripts/load-stripe-secret.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT
npx -y firebase-tools@latest functions:secrets:access STRIPE_SECRET_KEY --project syncfit-8441f >"$TMP" 2>/dev/null
# Strip possible trailing newline only
KEY="$(tr -d '\r\n' <"$TMP")"
if [[ -z "$KEY" || "$KEY" != sk_test_* ]]; then
  echo "Failed to load STRIPE_SECRET_KEY (expected sk_test_…)." >&2
  return 1 2>/dev/null || exit 1
fi
export STRIPE_SECRET_KEY="$KEY"
echo "STRIPE_SECRET_KEY loaded (sk_test_…, len=${#STRIPE_SECRET_KEY})"
