#!/usr/bin/env bash
# Publishes firestore.rules (+ storage.rules) to syncfit-8441f.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/tmp/node-v22/bin:${PATH}"
cd "$ROOT"

if ! command -v firebase >/dev/null 2>&1; then
  echo "firebase CLI not found. Install: npm install -g firebase-tools"
  exit 1
fi

if ! firebase projects:list >/dev/null 2>&1; then
  echo "Not logged in. Run: firebase login"
  exit 1
fi

firebase deploy --only firestore:rules,storage --project syncfit-8441f
echo "Deployed. Re-open coach View data in the app to verify."
