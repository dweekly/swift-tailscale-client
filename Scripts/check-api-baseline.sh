#!/usr/bin/env bash
# Verifies that no unallowlisted API-breaking changes have been introduced
# against the baseline release (v0.12.0) using SwiftPM's diagnose-api-breaking-changes.
set -euo pipefail

cd "$(dirname "$0")/.."

BASELINE_TAG="v0.12.0"
ALLOWLIST="Scripts/api-breakage-allowlist.txt"

# Ensure git tags exist in shallow clones or container environments
git fetch --tags origin 2>/dev/null || true

if ! git rev-parse --verify "${BASELINE_TAG}^{commit}" >/dev/null 2>&1; then
  echo "ERROR: Baseline tag ${BASELINE_TAG} not found in git history."
  exit 1
fi

if [ ! -f "$ALLOWLIST" ]; then
  echo "ERROR: Allowlist file ${ALLOWLIST} not found."
  exit 1
fi

echo "Checking API compatibility baseline against ${BASELINE_TAG}..."
swift package diagnose-api-breaking-changes "$BASELINE_TAG" \
  --products TailscaleClient TailscaleClientMocks \
  --breakage-allowlist-path "$ALLOWLIST"

echo "API compatibility baseline check passed (against ${BASELINE_TAG})."
