#!/usr/bin/env bash
# Role: headless walkthrough test driver (CI); see run-walkthrough-show.sh for the doc-test display variant.
# Regenerate the account-log walkthrough screenshots in doctests/images.
#
# Launches one logos-accountlog-ui instance offscreen on an empty vault and an
# in-process store, drives the whole walkthrough through its own QML surface via
# the logos-qt-mcp inspector protocol (run-walkthrough.mjs), and writes the
# numbered screenshots to OUT_DIR. Exits non-zero if any checkpoint is missed,
# so this doubles as an end-to-end integration check.
#
# Usage:
#   doctests/walkthrough/run-walkthrough.sh [out-dir]
# Env:
#   FLAKE          flake ref to build the app from (default ".")
#   APP_BIN        run-logos-standalone-ui path; if unset, built from FLAKE
#   OUT_DIR        screenshot dir (default arg1, else doctests/images)
#   WORK_DIR       vault/log dir; if unset, a fresh mktemp is used
#   KEEP_WORK_DIR  if set, WORK_DIR is left in place on exit (e.g. to keep the
#                  app log); the process is still torn down
#   KEEP_INSTANCE  if set, a *successful* run leaves the app running (and its
#                  WORK_DIR in place) and the caller owns its teardown; a failed
#                  run still tears everything down
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
OUT_DIR="${OUT_DIR:-${1:-$repo_root/doctests/images}}"
FLAKE="${FLAKE:-$repo_root}"
APP_PORT="${APP_PORT:-3768}"
WORK_DIR="${WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/accountlog-walkthrough.XXXXXX")}"
mkdir -p "$OUT_DIR" "$WORK_DIR"

if [ -z "${APP_BIN:-}" ]; then
  echo "resolving the standalone app launcher from $FLAKE ..."
  system="$(nix eval --raw --impure --expr builtins.currentSystem)"
  APP_BIN="$(nix eval --raw "$FLAKE#apps.$system.default.program")"
  # Build the launcher's *derivation*, not its output path. `nix build
  # /nix/store/<out>` has no .drv to build from and can only substitute, so a
  # binary-cache miss fails with "no substituter that can build it". Recover the
  # drv from the SAME flake eval as APP_BIN (getContext over its program string)
  # so the build target matches the launch target and a miss builds from source.
  app_drv="$(nix eval --raw --apply \
    'p: builtins.head (builtins.attrNames (builtins.getContext p))' \
    "$FLAKE#apps.$system.default.program")"
  nix build --no-link "$app_drv^*"
fi
echo "app: $APP_BIN"

# The app fans out into one host process per module (logos_host_qt for the
# plugin, plus ui-host), each in its own session, so killing the launched PID's
# process group misses them. Snapshot the logos process set before launch and,
# on exit, kill exactly the processes our run added (the set difference), which
# never touches pre-existing instances.
LOGOS_PAT='logos_host_qt|logos-standalone-app|ui-host'
PRE_PIDS="$(pgrep -f "$LOGOS_PAT" 2>/dev/null | sort -u || true)"
walkthrough_done=""
# Surface the instance's boot/runtime output. The app runs headless, so app.log
# is the only window into why a run failed: inspector never bound, the module
# never came ready, or the store refused the update.
dump_app_log() {
  [ -f "$WORK_DIR/app.log" ] || return 0
  echo "::group::app log" >&2
  cat "$WORK_DIR/app.log" >&2
  echo "::endgroup::" >&2
}
cleanup() {
  if [ -n "${KEEP_INSTANCE:-}" ] && [ -n "$walkthrough_done" ]; then
    return  # the caller owns the still-running app and its WORK_DIR
  fi
  # A run that never set walkthrough_done failed partway; surface the log first.
  [ -n "$walkthrough_done" ] || dump_app_log
  local now ours
  now="$(pgrep -f "$LOGOS_PAT" 2>/dev/null | sort -u || true)"
  ours="$(comm -13 <(printf '%s\n' "$PRE_PIDS") <(printf '%s\n' "$now") || true)"
  [ -n "$ours" ] && kill -9 $ours 2>/dev/null || true
  [ -n "${KEEP_WORK_DIR:-}" ] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

wait_for_port() {
  local port="$1"
  for _ in $(seq 1 120); do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && return 0
    sleep 1
  done
  # The app log is surfaced by cleanup on the way out (see dump_app_log).
  echo "inspector on port $port never came up" >&2
  return 1
}

# An empty vault and the in-process store: the walkthrough always starts from
# no account, needs no network, and leaves nothing on devnet.
mkdir -p "$WORK_DIR/vault"
QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
  QML_INSPECTOR_PORT="$APP_PORT" \
  LOGOS_ACCOUNTLOG_VAULT_DIR="$WORK_DIR/vault" \
  LOGOS_ACCOUNTLOG_STORE_URL=memory \
  setsid "$APP_BIN" -platform offscreen --user-dir "$WORK_DIR/host" \
    > "$WORK_DIR/app.log" 2>&1 &
echo "launched accountlog-ui (inspector $APP_PORT)"
wait_for_port "$APP_PORT"

OUT_DIR="$OUT_DIR" APP_PORT="$APP_PORT" node "$here/run-walkthrough.mjs"
walkthrough_done=1
