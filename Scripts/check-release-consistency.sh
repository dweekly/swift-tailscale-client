#!/usr/bin/env bash
# Fails when the version the docs advertise disagrees with itself — or,
# when a tag is passed ($1 = vX.Y.Z, from the release workflow), with the
# tag being released. This is the guard against the drift class where the
# README says one version, DocC another, and the coverage matrix a third.
#
# Bash 3.2 compatible on purpose: the release workflow runs this on macOS
# runners, whose system bash is 3.2 (no associative arrays, no mapfile).
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
labels=()
versions=()

extract() {
  local label="$1" file="$2" pattern="$3"
  local v
  v=$(grep -oE "$pattern" "$file" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  if [ -z "$v" ]; then
    echo "MISSING  $label: no version found in $file (pattern: $pattern)"
    fail=1
    return
  fi
  labels+=("$label")
  versions+=("$v")
  printf '%-22s %s\n' "$label:" "$v"
}

extract "README pin" README.md 'from: "[0-9]+\.[0-9]+\.[0-9]+"'
extract "SKILL pin" .claude/skills/swift-tailscale-client/SKILL.md 'from: "[0-9]+\.[0-9]+\.[0-9]+"'
extract "AGENTS.md pin" AGENTS.md 'from: "[0-9]+\.[0-9]+\.[0-9]+"'
extract "llms.txt pin" llms.txt 'from: "[0-9]+\.[0-9]+\.[0-9]+"'
extract "INTEGRATING pin" Documentation/INTEGRATING.md 'from: "[0-9]+\.[0-9]+\.[0-9]+"'
extract "Recipes example pin" Examples/Recipes/Package.swift 'from: "[0-9]+\.[0-9]+\.[0-9]+"'
extract "DocC GettingStarted" Sources/TailscaleClient/TailscaleClient.docc/GettingStarted.md \
  'from: "[0-9]+\.[0-9]+\.[0-9]+"'
extract "Coverage matrix" Documentation/LOCALAPI-COVERAGE.md \
  'swift-tailscale-client version:\*\* [0-9]+\.[0-9]+\.[0-9]+'
# CLAUDE.md deliberately states no version: it indexes authoritative
# sources (CHANGELOG for versions) instead of duplicating them.
extract "packageVersion const" Sources/TailscaleClient/Configuration/TailscaleClientConfiguration.swift \
  'packageVersion = "[0-9]+\.[0-9]+\.[0-9]+"'
extract "CHANGELOG top entry" CHANGELOG.md '## \[[0-9]+\.[0-9]+\.[0-9]+\]'

reference=""
i=0
while [ $i -lt ${#labels[@]} ]; do
  if [ "${labels[$i]}" = "CHANGELOG top entry" ]; then
    reference="${versions[$i]}"
  fi
  i=$((i + 1))
done
i=0
while [ $i -lt ${#labels[@]} ]; do
  if [ "${versions[$i]}" != "$reference" ]; then
    echo "DRIFT    ${labels[$i]} (${versions[$i]}) != CHANGELOG top entry ($reference)"
    fail=1
  fi
  i=$((i + 1))
done

if [ $# -ge 1 ]; then
  tag="${1#v}"
  if [ "$tag" != "$reference" ]; then
    echo "DRIFT    release tag (v$tag) != documented version ($reference)"
    fail=1
  fi
fi

# Capability default: the Swift constant is the source of truth; every doc
# that states a number must state the same one. (The constant itself is
# verified against the pinned upstream revision by
# Scripts/verify-upstream-maturity.py.)
capability=$(grep -oE 'defaultCapabilityVersion = [0-9]+' \
  Sources/TailscaleClient/Configuration/TailscaleClientConfiguration.swift \
  | grep -oE '[0-9]+' || true)
if [ -z "$capability" ]; then
  echo "MISSING  defaultCapabilityVersion constant not found in Swift source"
  fail=1
else
  printf '%-22s %s\n' "capability default:" "$capability"
  check_capability() {
    local label="$1" file="$2" pattern="$3"
    local documented
    documented=$(grep -oE "$pattern" "$file" | head -1 | grep -oE '[0-9]+' || true)
    if [ -z "$documented" ]; then
      echo "MISSING  $label: no capability default found in $file"
      fail=1
    elif [ "$documented" != "$capability" ]; then
      echo "DRIFT    $label documents capability $documented, source says $capability"
      fail=1
    fi
  }
  check_capability "README env table" README.md \
    'TAILSCALE_LOCALAPI_CAPABILITY. \| Capability version \(defaults to .[0-9]+'
  check_capability "DocC VersionCompatibility" \
    Sources/TailscaleClient/TailscaleClient.docc/VersionCompatibility.md \
    'Tailscale-Cap: [0-9]+'
  check_capability "endpoints.json provenance" Documentation/endpoints.json \
    '"capability_version": [0-9]+'
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "Release consistency check FAILED — align the files above before tagging."
  exit 1
fi
echo "Release consistency check passed (version $reference)."
