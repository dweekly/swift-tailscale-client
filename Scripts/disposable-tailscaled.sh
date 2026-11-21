#!/usr/bin/env bash
# disposable-tailscaled.sh: build, start, locate and stop a throwaway userspace
# tailscaled of a given upstream version, for testing LocalAPI behavior against
# real daemon binaries without touching the system Tailscale. See
# Documentation/TESTING.md ("Testing against a specific daemon version").
#
# Requires: bash 3.2+, go (to build the daemon), ps. Not run in CI.
#
# Usage:
#   disposable-tailscaled.sh <version> start   # build if needed, start, wait, report
#   disposable-tailscaled.sh <version> sock    # print the socket path (must be running)
#   disposable-tailscaled.sh <version> stop    # stop the daemon this script started
#
# <version> is an upstream tag such as v1.102.2 or v1.104.7.
#
# Safety model (why it is shaped this way):
#   * Every daemon runs with --tun=userspace-networking (no utun, no root),
#     its own --socket, --statedir, --state=mem:, --port=0, and log upload
#     disabled. It is never logged in to a tailnet, so it sits in NeedsLogin.
#   * All files live under TSD_HOME (default: .build/disposable-tailscaled in
#     the repository, which is gitignored):
#       $TSD_HOME/bin/<ver>/         tailscaled + tailscale built by `go install`
#       $TSD_HOME/run/<ver>/         state, logs, pid file, daemon output
#   * Unix socket paths are limited to ~104 bytes on macOS, and TSD_HOME is often
#     too deep. So the socket goes in a short directory made by `mktemp -d` under
#     TSD_SOCK_ROOT (default: $TMPDIR, then /tmp). That directory holds a marker
#     file naming the run directory that owns it; both this script and
#     watch-mask-probe.sh refuse to touch a socket whose directory lacks a
#     matching marker. That is what keeps them away from the system daemon.
#   * `stop` only signals the PID it recorded, and only if that process's
#     command line still contains the managed socket path.
#
# Environment:
#   TSD_HOME       work root (default: <repo>/.build/disposable-tailscaled)
#   TSD_SOCK_ROOT  parent for the short socket directory (default: $TMPDIR or /tmp)
#   GO             go binary (default: go on PATH)

set -euo pipefail

readonly MARKER_NAME=".disposable-tailscaled"

die() { echo "disposable-tailscaled: $*" >&2; exit 1; }

script_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P; }

[[ $# -eq 2 ]] || die "usage: $0 <version> start|stop|sock"
VER=$1
CMD=$2
[[ $VER =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || die "version must look like v1.104.7, got '$VER'"

TSD_HOME=${TSD_HOME:-$(script_dir)/../.build/disposable-tailscaled}
mkdir -p "$TSD_HOME"
TSD_HOME=$(cd "$TSD_HOME" && pwd -P)
BIN_DIR=$TSD_HOME/bin/$VER
RUN_DIR=$TSD_HOME/run/$VER
PID_FILE=$RUN_DIR/tailscaled.pid
SOCKDIR_FILE=$RUN_DIR/sockdir
GO=${GO:-go}

# Print the managed socket path for this version, or fail if there is none.
# Validates the marker so a tampered or stale sockdir file cannot point us at
# some other socket.
managed_sock() {
  [[ -f $SOCKDIR_FILE ]] || return 1
  local d
  d=$(cat "$SOCKDIR_FILE")
  [[ -n $d && -d $d ]] || return 1
  [[ -f $d/$MARKER_NAME && $(cat "$d/$MARKER_NAME") == "$RUN_DIR" ]] ||
    die "socket dir $d has no marker for $RUN_DIR; refusing"
  echo "$d/tailscaled.sock"
}

pid_alive() { [[ -n ${1:-} ]] && kill -0 "$1" 2>/dev/null; }

# True if the PID is a tailscaled using our socket (guards against PID reuse
# and against ever signalling the system daemon).
pid_is_ours() {
  local pid=$1 sock=$2 cmdline
  cmdline=$(ps -o command= -p "$pid" 2>/dev/null || true)
  [[ $cmdline == *tailscaled* && $cmdline == *"--socket=$sock"* ]]
}

build() {
  if [[ -x $BIN_DIR/tailscaled && -x $BIN_DIR/tailscale ]]; then
    return 0
  fi
  mkdir -p "$BIN_DIR" "$RUN_DIR"
  echo "building tailscaled + tailscale $VER into $BIN_DIR" >&2
  if ! GOBIN=$BIN_DIR "$GO" install "tailscale.com/cmd/tailscaled@$VER" "tailscale.com/cmd/tailscale@$VER" \
    >"$RUN_DIR/build.log" 2>&1; then
    echo "build failed with default toolchain; retrying with GOTOOLCHAIN=auto" >&2
    GOTOOLCHAIN=auto GOBIN=$BIN_DIR "$GO" install "tailscale.com/cmd/tailscaled@$VER" "tailscale.com/cmd/tailscale@$VER" \
      >>"$RUN_DIR/build.log" 2>&1 || die "build failed twice; see $RUN_DIR/build.log"
  fi
}

start() {
  build
  mkdir -p "$RUN_DIR/state" "$RUN_DIR/logs" "$RUN_DIR/home"

  if [[ -f $PID_FILE ]]; then
    local old sock
    old=$(cat "$PID_FILE")
    sock=$(managed_sock || true)
    if [[ -n $sock ]] && pid_alive "$old" && pid_is_ours "$old" "$sock"; then
      echo "already running: pid $old socket $sock" >&2
      report "$sock"
      return 0
    fi
    rm -f "$PID_FILE"
  fi

  # Flags we rely on must exist in this version (checked before creating anything).
  local help f
  help=$("$BIN_DIR/tailscaled" --help 2>&1 || true)
  for f in -tun -socket -statedir -state -port -no-logs-no-support; do
    grep -Eq -- "^  $f( |\$)" <<<"$help" || die "tailscaled $VER lacks flag $f"
  done

  # Fresh short socket directory, tagged with the run dir that owns it.
  local root d sock
  root=${TSD_SOCK_ROOT:-${TMPDIR:-/tmp}}
  root=${root%/}
  d=$(mktemp -d "$root/tsd.XXXXXX")
  sock=$d/tailscaled.sock
  if (( ${#sock} >= 100 )); then
    rmdir "$d"
    die "socket path too long (${#sock} bytes): $sock; set TSD_SOCK_ROOT shorter"
  fi
  echo "$RUN_DIR" >"$d/$MARKER_NAME"
  echo "$d" >"$SOCKDIR_FILE"

  # HOME/XDG/TS_LOGS_DIR are redirected so nothing lands in the real home dir.
  HOME=$RUN_DIR/home XDG_CACHE_HOME=$RUN_DIR/home/.cache XDG_CONFIG_HOME=$RUN_DIR/home/.config \
    TS_LOGS_DIR=$RUN_DIR/logs TS_NO_LOGS_NO_SUPPORT=true \
    nohup "$BIN_DIR/tailscaled" \
    --tun=userspace-networking \
    --socket="$sock" \
    --statedir="$RUN_DIR/state" \
    --state=mem: \
    --port=0 \
    --no-logs-no-support \
    >"$RUN_DIR/tailscaled.out" 2>&1 </dev/null &
  local pid=$!
  echo "$pid" >"$PID_FILE"

  local i
  for ((i = 0; i < 60; i++)); do
    [[ -S $sock ]] && break
    pid_alive "$pid" || die "tailscaled exited early; see $RUN_DIR/tailscaled.out"
    sleep 0.5
  done
  [[ -S $sock ]] || die "socket never appeared: $sock"
  echo "started tailscaled $VER pid $pid socket $sock" >&2
  report "$sock"
}

# Print version and backend state through the matching CLI.
report() {
  local sock=$1
  echo "--- tailscale version"
  "$BIN_DIR/tailscale" --socket="$sock" version || true
  echo "--- BackendState"
  "$BIN_DIR/tailscale" --socket="$sock" status --json 2>/dev/null |
    sed -n 's/^[[:space:]]*"BackendState":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true
}

stop() {
  local sock pid
  sock=$(managed_sock || true)
  if [[ ! -f $PID_FILE ]]; then
    echo "no pid file for $VER; nothing to stop" >&2
  else
    pid=$(cat "$PID_FILE")
    if pid_alive "$pid"; then
      if [[ -z $sock ]] || ! pid_is_ours "$pid" "$sock"; then
        die "pid $pid is not a tailscaled on our socket; refusing to signal it"
      fi
      kill -TERM "$pid"
      local i
      for ((i = 0; i < 20; i++)); do pid_alive "$pid" || break; sleep 0.5; done
      if pid_alive "$pid"; then kill -KILL "$pid"; fi
      echo "stopped pid $pid" >&2
    else
      echo "pid $pid not running" >&2
    fi
    rm -f "$PID_FILE"
  fi
  # Remove only the socket directory we created (marker checked in managed_sock).
  if [[ -n $sock ]]; then
    local d
    d=$(dirname "$sock")
    rm -f "$d/tailscaled.sock" "$d/$MARKER_NAME"
    rmdir "$d" 2>/dev/null || echo "left non-empty $d" >&2
  fi
  rm -f "$SOCKDIR_FILE"
}

case $CMD in
  start) start ;;
  stop) stop ;;
  sock)
    s=$(managed_sock) || die "$VER is not running (no managed socket)"
    [[ -S $s ]] || die "socket $s does not exist"
    echo "$s"
    ;;
  *) die "unknown command '$CMD' (start|stop|sock)" ;;
esac
