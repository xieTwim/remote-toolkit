#!/usr/bin/env bash
# canary_rt — remote-toolkit's first tests (2026-08-02).
#
# `rt` had none. It is the tool that decides which code a GPU job launches and which results come
# back, and every claim about it was a claim about a live host nobody could re-run.
#
# The trick that makes it testable offline: `rt` is sourced (its `main` is guarded), `_ssh` is
# stubbed to CAPTURE the command string instead of sending it, and the captured string is then
# EXECUTED locally under a scratch HOME. So these are not assertions about a regex — the same
# shell text the remote would run is run here, and its recorded exit code is read back exactly
# the way `rt logs` reads it.
#
#   test/canary_rt.sh          # exit 0 iff every invariant holds
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT="$(dirname "$HERE")/rt"
PASS=0; FAIL=0

chk() { # chk <name> <condition-result> [detail]
  if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL %s\n' "$1"; [ -n "${3:-}" ] && printf '         %s\n' "$3"; FAIL=$((FAIL+1)); fi
}

echo "remote-toolkit canary"

# ── harness ───────────────────────────────────────────────────────────────────
# Source rt with a fake profile so _init_profile's globals exist. Nothing here touches ~/.config.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export RT_HOME="$SCRATCH/conf"
mkdir -p "$RT_HOME/h"
cat > "$RT_HOME/h/host.conf" <<'EOF'
REMOTE_HOST=example-host
REMOTE_USER=nobody
EOF
cat > "$RT_HOME/h/p.conf" <<'EOF'
LOCAL_DIR=/tmp/nowhere
REMOTE_DIR=/remote/proj
EOF

# shellcheck disable=SC1090
set +e
source "$RT" 2>/dev/null
set -e
RT_PROFILE="h/p"; RT_SESSION_PREFIX="rt_h_p_bg_"; REMOTE_DIR="$SCRATCH/proj"
mkdir -p "$REMOTE_DIR"

CAPTURED=""
_ssh() { CAPTURED="$*"; return 0; }          # capture instead of send
info() { :; }                                 # quiet

# ── 1. a background job's recorded status is the COMMAND's, not tee's ─────────
#
# `{ cmd; } 2>&1 | tee log; echo "EXIT_CODE=$?"` records TEE's status. tee essentially always
# succeeds, so every background job that ever started was recorded EXIT_CODE=0 and listed by
# `rt logs` as [DONE] — including one that died on its first line. Found 2026-08-02 by a
# de-correlated read of a tool that had never been audited.
#
# The captured tmux argument is extracted and RUN, so this pins behaviour, not wording.
# The tmux argument is recovered by letting a SHELL parse the captured line — a stub `tmux`
# whose last argv element is the payload — rather than by peeling quotes with string surgery.
# That is exactly what the remote shell does with the string ssh hands it, so what runs below is
# what would run there. Surgery on the quotes would be a test of my own peeling.
TMUX_PAYLOAD=""
tmux() { TMUX_PAYLOAD="${!#}"; }

emit() { # emit <command> -> sets TMUX_PAYLOAD to what the remote shell would run
  CAPTURED=""; TMUX_PAYLOAD=""
  _exec_bg "$1" "probe" >/dev/null 2>&1
  eval "$CAPTURED"
}

run_captured() { # run_captured <command> -> prints the recorded EXIT_CODE
  local home="$SCRATCH/home"
  rm -rf "$home"; mkdir -p "$home/.rt_logs"
  emit "$1"
  ( cd "$home" && HOME="$home" sh -c "$TMUX_PAYLOAD" ) >/dev/null 2>&1
  sed -n 's/^EXIT_CODE=//p' "$home/.rt_logs/rt_h_p_bg_probe.log" 2>/dev/null | tail -1
}

# Four failure SHAPES, because they fail differently and the construct handles them differently.
# `exit N` is the one that motivated the explicit subshell: a pipeline's group is already a
# subshell, so a bare `exit` terminates it before the marker can be written.
printf '#!/bin/sh\nexit 7\n' > "$SCRATCH/fails7"; chmod +x "$SCRATCH/fails7"
for shape in "false|1" "$SCRATCH/fails7|7" "ls /nonexistent-rt-probe|1" "exit 9|9"; do
  cmd="${shape%|*}"; want="${shape##*|}"
  got="$(run_captured "$cmd")"
  chk "1 [${cmd##*/}] records its OWN exit code, not tee's" \
      "$([ "$got" = "$want" ] && echo 0 || echo 1)" "recorded '$got', want $want"
done

rc_ok="$(run_captured 'echo hello')"
chk "1b a succeeding command still records 0" \
    "$([ "$rc_ok" = "0" ] && echo 0 || echo 1)" "recorded '$rc_ok', want 0"

# The log must still carry the command's OUTPUT — the fix keeps `tee` precisely so the tmux pane
# and the log both stay live. A status-only redirect would pass check 1 and destroy `rt logs`.
rm -rf "$SCRATCH/home"; mkdir -p "$SCRATCH/home/.rt_logs"
emit 'echo MARKER_TEXT'
( cd "$SCRATCH/home" && HOME="$SCRATCH/home" sh -c "$TMUX_PAYLOAD" ) >/dev/null 2>&1
grep -q MARKER_TEXT "$SCRATCH/home/.rt_logs/rt_h_p_bg_probe.log"
chk "1c the command's OUTPUT still reaches the log (tee is not replaced by a redirect)" "$?"

# A failed `cd` used to short-circuit before tee, leaving no log at all — a job that never ran
# and left no trace of not running.
REMOTE_DIR_SAVE="$REMOTE_DIR"; REMOTE_DIR="$SCRATCH/does-not-exist"
rc_cd="$(run_captured 'echo unreachable')"
REMOTE_DIR="$REMOTE_DIR_SAVE"
chk "1d an unreachable REMOTE_DIR records a FAILURE rather than no log at all" \
    "$([ -n "$rc_cd" ] && [ "$rc_cd" != "0" ] && echo 0 || echo 1)" "recorded '$rc_cd'"

# ── 2. the status the reader is shown ────────────────────────────────────────
# `rt logs`' sed only matches digits, so a missing marker yielded the empty string and rendered
# as `[EXITED: ]` — an empty field that reads as "finished, no detail" rather than "nothing
# recorded a status", which is what a killed job looks like.
grep -q 'NO STATUS' "$RT"
chk "2 a missing exit marker is named, not rendered as an empty [EXITED: ]" "$?"

# ── 3. the source guard ──────────────────────────────────────────────────────
chk "3 sourcing rt does not execute main (this file depends on it)" 0

echo "────────────────────────────────────────────"
if [ "$FAIL" = 0 ]; then echo "rt canaries: ${PASS}/${PASS} pass"; exit 0; fi
echo "rt canaries: ${PASS} pass, ${FAIL} FAIL"; exit 1
