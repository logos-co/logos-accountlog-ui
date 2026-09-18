#!/usr/bin/env bash
# Role: doc-test display entry (the `#walkthrough` flake app); wraps run-walkthrough.sh then holds the window open.
# Write a whole account log, then hold the window open showing the finished
# log: the entry point for the `#walkthrough` flake app the doc-test drives.
#
# The app binds its QML inspector the moment it starts, so a doc-test attaching
# to the default port would screenshot the empty-vault door rather than the log.
# This splits the work: the walkthrough runs first, on its own inspector port,
# and the instance is *kept alive* with the published log on screen. Only once
# it is done does SHOW_PORT open, as a TCP proxy onto that live inspector. The
# doc-test attaches to the finished window and screenshots it, while the
# walkthrough itself has already happened during the unbounded launch port-wait.
#
# Usage:
#   run-walkthrough-show.sh [base-dir]
# Env:
#   APP_BIN     run-logos-standalone-ui path (baked in by the flake app)
#   SHOW_PORT   capture port the doc-test attaches to (default 3768)
#   OUT_DIR     where the numbered screenshots are written (default <base>/images)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${1:-$(mktemp -d "${TMPDIR:-/tmp}/accountlog-walkthrough-show.XXXXXX")}"
DATA_DIR="$BASE/data"
OUT_DIR="${OUT_DIR:-$BASE/images}"
SHOW_PORT="${SHOW_PORT:-3768}"
APP_PORT=4768
mkdir -p "$DATA_DIR" "$OUT_DIR"

# The instance outlives run-walkthrough.sh here (KEEP_INSTANCE), so its teardown
# is ours: snapshot the logos process set before launch and, on exit, kill
# exactly the processes this run added (the module host processes set their own
# session, so a process-group kill would miss them). Plus the proxy.
LOGOS_PAT='logos_host_qt|logos-standalone-app|ui-host'
PRE_PIDS="$(pgrep -f "$LOGOS_PAT" 2>/dev/null | sort -u || true)"
PROXY_PID=""
show_cleanup() {
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
  local now ours
  now="$(pgrep -f "$LOGOS_PAT" 2>/dev/null | sort -u || true)"
  ours="$(comm -13 <(printf '%s\n' "$PRE_PIDS") <(printf '%s\n' "$now") || true)"
  [ -n "$ours" ] && kill -9 $ours 2>/dev/null || true
}
trap 'exit 0' TERM INT
trap show_cleanup EXIT

# Phase 1: the whole walkthrough, on inspector port 4768 so SHOW_PORT stays
# closed until the finished window is ready. KEEP_INSTANCE leaves the app
# running with the published log on screen.
echo "=== phase 1: write the account log (instance kept alive) ==="
APP_PORT="$APP_PORT" \
  WORK_DIR="$DATA_DIR" KEEP_WORK_DIR=1 KEEP_INSTANCE=1 OUT_DIR="$OUT_DIR" \
  bash "$here/run-walkthrough.sh" "$OUT_DIR"

# Phase 2: open SHOW_PORT onto the live inspector and hold the window for the
# doc-test to screenshot. The doc-test kills this process group when done; the
# EXIT trap reaps the proxy and the app. Probe the port before declaring ready:
# a proxy that failed to bind (e.g. SHOW_PORT already in use) would otherwise
# turn into a silent hold that never opens the port.
LISTEN_PORT="$SHOW_PORT" TARGET_PORT="$APP_PORT" node "$here/port-proxy.mjs" &
PROXY_PID=$!
proxy_up=""
for _ in $(seq 1 10); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$SHOW_PORT") 2>/dev/null; then proxy_up=1; break; fi
  sleep 1
done
[ -n "$proxy_up" ] || { echo "proxy on port $SHOW_PORT never came up" >&2; exit 1; }
echo "=== ready: log published; exposing the window on port $SHOW_PORT ==="
while true; do sleep 3600 & wait $!; done
