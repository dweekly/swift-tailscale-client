#!/usr/bin/env bash
# watch-mask-probe.sh: probe GET /localapi/v0/watch-ipn-bus?mask=<n> with a fixed
# table of NotifyWatchOpt masks against one disposable tailscaled, and print a TSV
# of what the daemon accepts or rejects.
#
# Usage:
#   watch-mask-probe.sh <socket-path>
#   watch-mask-probe.sh "$(Scripts/disposable-tailscaled.sh v1.104.7 sock)"
#
# Requires: bash 3.2+, curl with --unix-socket, jq. Not run in CI.
#
# Why: upstream changed which watch-option bits it accepts (bits 3 and 8 became
# obsolete and rejected in v1.104.0). This records the real daemon's answer for
# the masks swift-tailscale-client sends and for every newer bit, so the
# library's defaults can be checked against each release.
#
# Output columns: label, mask (decimal), bits set, HTTP status, detail.
#   detail = response body text for non-200, or the JSON keys of the first
#   notification line for 200. A 200 is a stream, so curl stops at the
#   per-request max time (PROBE_MAX_TIME, default 5 s); that is expected.
#
# Safety: refuses any socket whose directory lacks the marker file written by
# disposable-tailscaled.sh, so it cannot be pointed at the system daemon.

set -euo pipefail

readonly MARKER_NAME=".disposable-tailscaled"
MAX_TIME=${PROBE_MAX_TIME:-5}

die() { echo "watch-mask-probe: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: $0 <socket-path>"
SOCK=$1
[[ -S $SOCK ]] || die "not a socket: $SOCK"
[[ -f $(dirname "$SOCK")/$MARKER_NAME ]] ||
  die "$SOCK is not managed by disposable-tailscaled.sh (no marker); refusing"
command -v jq >/dev/null || die "jq is required"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/wmp.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

bits_of() {
  local m=$1 b out=""
  for ((b = 0; b < 64; b++)); do
    if (( (m >> b) & 1 )); then out+="${out:+,}$b"; fi
  done
  echo "${out:-none}"
}

# label:mask. The masks are literals so the probe needs no Swift build. The
# lib.* and cli.* rows copy NotifyWatchOpt.default (bits 0,1,7,8) and
# .allInitial (bits 1,2,3,5,6,7,10) from Sources/TailscaleClient/Models/IPNNotify.swift
# and the CLI defaults from Sources/tailscale-swift/Watch.swift (watch = bits 1,7,8;
# --all-initial = .allInitial | bits 0,8); keep them in step when those change.
MASKS=(
  "lib.default:$(( 1<<0 | 1<<1 | 1<<7 | 1<<8 ))"
  "lib.default-minus-bit8:$(( 1<<0 | 1<<1 | 1<<7 ))"
  "cli.watch-default:$(( 1<<1 | 1<<7 | 1<<8 ))"
  "bit3-only:$(( 1<<3 ))"
  "bit8-only:$(( 1<<8 ))"
  "bits3+8:$(( 1<<3 | 1<<8 ))"
  "lib.allInitial:$(( 1<<1 | 1<<2 | 1<<3 | 1<<5 | 1<<6 | 1<<7 | 1<<10 ))"
  "lib.allInitial-minus-bits3,8:$(( 1<<1 | 1<<2 | 1<<5 | 1<<6 | 1<<7 | 1<<10 ))"
  "cli.watch--all-initial:$(( 1<<0 | 1<<1 | 1<<2 | 1<<3 | 1<<5 | 1<<6 | 1<<7 | 1<<8 | 1<<10 ))"
)
for b in 11 12 13 14 15 16 17 18 19; do MASKS+=("bit$b-only:$(( 1<<b ))"); done
MASKS+=(
  "bits19+1:$(( 1<<19 | 1<<1 ))"
  "bits1+12+14+15:$(( 1<<1 | 1<<12 | 1<<14 | 1<<15 ))"
  # Pre-1.104 daemons reject bit 8 combined with the new-style bits 12-15.
  "bits8+14:$(( 1<<8 | 1<<14 ))"
)

printf 'label\tmask\tbits\thttp\tdetail\n'
for entry in "${MASKS[@]}"; do
  label=${entry%%:*}
  mask=${entry##*:}
  body=$WORK/body
  : >"$body"
  # curl exits 28 when a 200 stream hits max-time; that is the expected success case.
  code=$(curl --unix-socket "$SOCK" -sS -m "$MAX_TIME" -o "$body" -w '%{http_code}' \
    "http://local-tailscaled.sock/localapi/v0/watch-ipn-bus?mask=$mask" 2>/dev/null) || true
  if [[ $code == 200 ]]; then
    first=$(head -n 1 "$body")
    if [[ -z $first ]]; then
      detail="(stream open, no notification within ${MAX_TIME}s)"
    else
      # Notify serializes many fields as explicit null; list only non-null keys.
      detail=$(jq -c '[to_entries[] | select(.value != null) | .key]' <<<"$first" 2>/dev/null ||
        echo "unparsed: ${first:0:120}")
    fi
  else
    detail=$(tr '\n' ' ' <"$body" | sed 's/[[:space:]]*$//')
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$mask" "$(bits_of "$mask")" "${code:-none}" "$detail"
done
