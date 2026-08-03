#!/usr/bin/env bash
# Fails when the version the docs advertise disagrees with itself — or,
# when a tag is passed ($1 = vX.Y.Z, from the release workflow), with the
# tag being released. This is the guard against the drift class where the
# README says one version, DocC another, and the coverage matrix a third.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
declare -A versions

extract() {
  local label="$1" file="$2" pattern="$3"
  local v
  v=$(grep -oE "$pattern" "$file" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  if [ -z "$v" ]; then
    echo "MISSING  $label: no version found in $file (pattern: $pattern)"
    fail=1
    return
  fi
  versions["$label"]="$v"
  printf '%-22s %s\n' "$label:" "$v"
}

extract "README pin" README.md 'from: "[0-9]+\.[0-9]+\.[0-9]+"'
extract "SKILL pin" .claude/skills/swift-tailscale-client/SKILL.md 'from: "[0-9]+\.[0-9]+\.[0-9]+"'
extract "DocC GettingStarted" Sources/TailscaleClient/TailscaleClient.docc/GettingStarted.md \
  'from: "[0-9]+\.[0-9]+\.[0-9]+"'
extract "Coverage matrix" Documentation/LOCALAPI-COVERAGE.md \
  'swift-tailscale-client version:\*\* [0-9]+\.[0-9]+\.[0-9]+'
extract "CLAUDE.md status" CLAUDE.md 'Project Status \(v[0-9]+\.[0-9]+\.[0-9]+\)'
extract "packageVersion const" Sources/TailscaleClient/Configuration/TailscaleClientConfiguration.swift \
  'packageVersion = "[0-9]+\.[0-9]+\.[0-9]+"'
extract "CHANGELOG top entry" CHANGELOG.md '## \[[0-9]+\.[0-9]+\.[0-9]+\]'

reference="${versions[CHANGELOG top entry]:-}"
for label in "${!versions[@]}"; do
  if [ "${versions[$label]}" != "$reference" ]; then
    echo "DRIFT    $label (${versions[$label]}) != CHANGELOG top entry ($reference)"
    fail=1
  fi
done

if [ $# -ge 1 ]; then
  tag="${1#v}"
  if [ "$tag" != "$reference" ]; then
    echo "DRIFT    release tag (v$tag) != documented version ($reference)"
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "Release consistency check FAILED — align the files above before tagging."
  exit 1
fi
echo "Release consistency check passed (version $reference)."
