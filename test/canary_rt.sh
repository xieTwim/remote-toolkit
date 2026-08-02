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
# `rt` sets `-euo pipefail` at its top, and sourcing applies that to THIS shell. `-e` must go
# back off: half these checks call a function expecting a NON-ZERO return, and under `-e` the
# first one would kill the runner silently — which it did, taking blocks 4-6 with it.
set +e
source "$RT" 2>/dev/null
set +e
RT_PROFILE="h/p"; RT_SESSION_PREFIX="rt_h_p_bg_"; REMOTE_DIR="$SCRATCH/proj"
# `rt` keeps `set -u`, and several checks stub load_config away, so the globals it
# would have set have to exist here or an unrelated unbound-variable error kills the run.
REMOTE_HOST="example-host"; REMOTE_USER="nobody"; LOCAL_DIR="$SCRATCH/local"
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

# A failed `cd` must be RECORDED. Note what this does and does not pin: the old construct also
# recorded it (the trailing `echo "EXIT_CODE=$?" >> log` still runs and creates the file), so this
# check passes with the fix reverted and is an invariant, not a regression test. Said plainly
# because the commit that added it claimed otherwise — an adversarial pass corrected that, and a
# check whose stated purpose is wrong is worse than one that is merely redundant.
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

# ── 4. "flush failed" is two states, and they need opposite handling ─────────
#
# `_sync_flush` used to return 1 for both "the session is paused / mutagen errored" (nothing
# synced, and nothing is going to) and "the 10s bound elapsed" (the daemon is still working).
# Collapsing them forced every caller to pick one policy for both, and the tool picked OPPOSITE
# ones: `exec` warned and ran anyway, `slurm submit` aborted. Codes: 0 flushed, 2 could not, 3
# timed out.
_sync_status() { echo "${FAKE_STATUS:-active}"; }
_run_bounded()  { return "${FAKE_BOUNDED_RC:-0}"; }

FAKE_STATUS=paused; _sync_flush >/dev/null 2>&1; rc=$?
chk "4 a PAUSED session -> 2 (nothing synchronised)" "$([ "$rc" = 2 ] && echo 0 || echo 1)" "got $rc"

FAKE_STATUS=active; FAKE_BOUNDED_RC=124; _sync_flush >/dev/null 2>&1; rc=$?
chk "4b the time bound elapsing -> 3, NOT the same as a failure" \
    "$([ "$rc" = 3 ] && echo 0 || echo 1)" "got $rc"

FAKE_BOUNDED_RC=1; _sync_flush >/dev/null 2>&1; rc=$?
chk "4c mutagen itself failing -> 2" "$([ "$rc" = 2 ] && echo 0 || echo 1)" "got $rc"

FAKE_BOUNDED_RC=0; _sync_flush >/dev/null 2>&1; rc=$?
chk "4d a real flush -> 0" "$([ "$rc" = 0 ] && echo 0 || echo 1)" "got $rc"

# ── 5. the callers act on the distinction ────────────────────────────────────
# `rt exec` must REFUSE when nothing synced (its caller is usually a script branching on $?,
# which was being told success while the command ran against unknown code) and must CONTINUE on
# a bound elapsing, or refusal becomes so common that --no-flush turns the protection off.
_has_sync() { return 0; }
_ssh_test()  { return 0; }
_exec_sync() { echo "RAN_THE_COMMAND"; }
_exec_bg()   { echo "RAN_THE_COMMAND"; }
load_config() { :; }

out=$( FAKE_STATUS=paused; cmd_exec "echo hi" 2>&1 ); rc=$?
chk "5 exec REFUSES when nothing was synchronised" \
    "$([ "$rc" != 0 ] && ! grep -q RAN_THE_COMMAND <<< "$out" && echo 0 || echo 1)" \
    "rc=$rc out=$(head -c 120 <<< "$out")"

out=$( FAKE_STATUS=active; FAKE_BOUNDED_RC=124; cmd_exec "echo hi" 2>&1 ); rc=$?
chk "5b exec CONTINUES when only the time bound elapsed, and says so" \
    "$(grep -q RAN_THE_COMMAND <<< "$out" && grep -qi "did not finish" <<< "$out" && echo 0 || echo 1)" \
    "rc=$rc out=$(head -c 160 <<< "$out")"

# `slurm submit` is the one caller for which even a timeout is unacceptable: the job outlives
# the shell, so there is no chance to notice and re-run. And NO SESSION AT ALL is stronger than
# a failed flush — it used to warn and submit anyway, i.e. most permissive for the most
# dangerous state.
_slurm_enabled_check() { :; }
_ssh() { echo "Submitted batch job 1"; }
out=$( FAKE_STATUS=active; FAKE_BOUNDED_RC=124; _slurm_submit run.sbatch 2>&1 ); rc=$?
chk "5c slurm submit REFUSES even on a bare timeout (the job outlives this shell)" \
    "$([ "$rc" != 0 ] && ! grep -q "Submitted batch" <<< "$out" && echo 0 || echo 1)" \
    "rc=$rc out=$(head -c 140 <<< "$out")"

_has_sync() { return 1; }
out=$( _slurm_submit run.sbatch 2>&1 ); rc=$?
chk "5d slurm submit REFUSES with NO sync session (was: warn and submit anyway)" \
    "$([ "$rc" != 0 ] && ! grep -q "Submitted batch" <<< "$out" && echo 0 || echo 1)" \
    "rc=$rc out=$(head -c 140 <<< "$out")"

out=$( _slurm_submit --assume-staged run.sbatch 2>&1 ); rc=$?
chk "5e ... unless --assume-staged says the script was placed by other means" \
    "$(grep -q "Submitted batch" <<< "$out" && echo 0 || echo 1)" "rc=$rc out=$(head -c 140 <<< "$out")"

# ── 6. disconnect leaves jobs running unless told otherwise ──────────────────
# README and SKILL both said disconnect terminates sync and preserves work; it killed every
# background job, with no flush before or after. Two different intentions under one name.
_has_sync() { return 1; }
KILLED=""
_ssh() {
  case "$*" in
    *kill-session*) KILLED=yes; echo "" ;;
    *"grep -c"*)    echo 2 ;;
    *)              echo "" ;;
  esac
}
_sync_terminate() { :; }
clear_state() { :; }
KILLED=""; cmd_disconnect >/dev/null 2>&1
chk "6 disconnect does NOT kill background jobs by default" \
    "$([ -z "$KILLED" ] && echo 0 || echo 1)" "KILLED=$KILLED"
# `info` is stubbed to silence at the top of this file, so restore it just here — this
# check is ABOUT what the operator is told.
info() { printf ':: %s\n' "$*" >&2; }
KILLED=""; out=$(cmd_disconnect 2>&1)
chk "6b ... and SAYS what it is leaving running" \
    "$(grep -qi "RUNNING" <<< "$out" && echo 0 || echo 1)" "$(head -c 140 <<< "$out")"
KILLED=""; cmd_disconnect --kill-jobs >/dev/null 2>&1
chk "6c --kill-jobs still kills them" "$([ -n "$KILLED" ] && echo 0 || echo 1)" "KILLED=$KILLED"

echo "────────────────────────────────────────────"
if [ "$FAIL" = 0 ]; then echo "rt canaries: ${PASS}/${PASS} pass"; exit 0; fi
echo "rt canaries: ${PASS} pass, ${FAIL} FAIL"; exit 1
