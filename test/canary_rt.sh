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
# This block is about the JOB-killing behaviour, so the sync side is stubbed to "no session".
# `_sync_status` must agree with `_has_sync` here: blocks 4-5 left it returning `active`, and
# `cmd_disconnect` is called WITHOUT a subshell below, so its termination-postcondition `die`
# would take the whole runner down mid-suite rather than failing one check.
_has_sync() { return 1; }
_sync_status() { echo none; }
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

# ── 7. the sync classifier has a negative case ───────────────────────────────
#
# `_sync_status` decided health from the ABSENCE of two strings in `mutagen sync list` text, so
# every state Mutagen has that those strings do not name was reported `active`. The one that
# actually happens is the entry-count circuit breaker: it reports `Connected: Yes` on BOTH
# endpoints and `Status: Waiting 5 seconds for rescan`, and classified as healthy while
# synchronising nothing.
#
# Blocks 4-6 replaced `_sync_status`/`_run_bounded`/`_ssh` with stubs. Re-source to get the real
# implementations back before testing them.
set +e; source "$RT" 2>/dev/null; set +e
RT_PROFILE="h/p"; RT_HOST_GROUP="h"; RT_PROFILE_NAME="p"; RT_SESSION_PREFIX="rt_h_p_bg_"
info() { :; }; warn() { :; }

# Stub the `mutagen` BINARY (a shell function wins over PATH) and feed back the exact template
# records measured against real Mutagen 0.18.1, so the parse is pinned to observed output rather
# than to output I invented.
mutagen() { printf '%s\n' "$FAKE_TEMPLATE_OUT"; return "${FAKE_MUTAGEN_RC:-0}"; }
FAKE_MUTAGEN_RC=0

# <want> <.Paused>|<.Status>|<.Alpha.Connected>|<.Beta.Connected>|<.LastError>
# Deliberately NOT column-aligned: the padding would land in the trailing .LastError field and
# make three of these read as erroring. The record is data, so it gets no cosmetics.
#
# The three Halted* rows are the ones that broke the first version of this fix. Each was
# MEASURED against 0.18.1 by driving the condition on local endpoints, and each reports an
# EMPTY .LastError with BOTH endpoints connected — so a classifier that keys on the error alone
# calls all three healthy. That is the same defect this entry is about, one state over.
# Record layout, exactly as RT_SYNC_TEMPLATE emits it (9 fields):
#   paused|status|alphaConn|betaConn|scanned|dirs|files|bytes|lastError
# The paused/offline rows carry EMPTY size fields on purpose: `.Alpha.EndpointState` is nil
# while an endpoint is disconnected, which is what the template's `{{else}}|||{{end}}` produces.
for case in \
  "active false|Watching|true|true|true|5|134|3174279|" \
  "active false|WaitingForRescan|true|true|true|2|20|2048|" \
  "active false|StagingBeta|true|true|true|2|20|2048|" \
  "erroring false|WaitingForRescan|true|true|false|0|0|0|alpha scan error: exceeded allowed entry count" \
  "halted false|HaltedOnRootEmptied|true|true|true|1|0|0|" \
  "halted false|HaltedOnRootDeletion|true|true|true|1|0|0|" \
  "halted false|HaltedOnRootTypeChange|true|true|true|1|0|0|" \
  "paused true|Disconnected|false|false|||||" \
  "offline false|Watching|false|true|||||" \
  "offline false|Disconnected|true|true|||||" \
  "unknown false|HaltedOnSomethingAddedInAFutureMutagen|true|true|true|1|1|1|" \
; do
  want="${case%% *}"; rec="${case#* }"
  FAKE_TEMPLATE_OUT="$rec"
  got="$(_sync_status)"
  chk "7 [$want] Status=$(echo "$rec" | cut -d'|' -f2)$([ -n "$(echo "$rec" | cut -d'|' -f9)" ] && echo ' +error') -> $want" \
      "$([ "$got" = "$want" ] && echo 0 || echo 1)" "classified '$got', want '$want'"
done

# The classification is POSITIVE — `active` requires a RECOGNISED healthy verb. The row above
# pins that an unrecognised one reports `unknown`; this says why it matters. The old classifier
# called everything it did not recognise `active`, so every state Mutagen has that it did not
# name read as healthy, and a future Mutagen adding a brake would silently rejoin that set.
FAKE_TEMPLATE_OUT='false|Watching|true|true|true|1|1|1|'
chk "7a1 ... while a verb the tool DOES recognise as healthy still reads active" \
    "$([ "$(_sync_status)" = "active" ] && echo 0 || echo 1)" "got $(_sync_status)"

# One profile is one session. Two records matching this label pair means something outside `rt`
# created one, and answering from the first would report a state over a scope not established.
FAKE_TEMPLATE_OUT='false|Watching|true|true|true|1|1|1|
false|HaltedOnRootEmptied|true|true|true|1|0|0|'
chk "7a2 two sessions matching one profile's labels -> unknown, not first-one-wins" \
    "$([ "$(_sync_status)" = "unknown" ] && echo 0 || echo 1)" "got $(_sync_status)"

FAKE_TEMPLATE_OUT=""
chk "7b no session -> none" "$([ "$(_sync_status)" = "none" ] && echo 0 || echo 1)" "got $(_sync_status)"

# POSITIVE FIXTURE for the state that did not exist before: a probe that CANNOT RUN (daemon
# down, mutagen gone, or a future Mutagen rejecting the template) reported `none` — "there is no
# sync session", a claim about the remote that nothing established. Without this check the new
# `unknown` branch could be dead code and nothing would say so.
FAKE_MUTAGEN_RC=1; FAKE_TEMPLATE_OUT=""
chk "7c a probe that CANNOT RUN -> unknown, not none" \
    "$([ "$(_sync_status)" = "unknown" ] && echo 0 || echo 1)" "got $(_sync_status)"
# 7d is an INVARIANT, not a regression test: `_has_sync` excludes both `none` and `unknown`, so
# it passes with the `unknown` branch reverted too. It is here to pin that introducing the new
# state did not accidentally make an unaskable daemon look like a live session.
chk "7d ... and _has_sync stays false for it" "$(_has_sync; [ $? -ne 0 ] && echo 0 || echo 1)"
FAKE_MUTAGEN_RC=0

# The error message may itself contain '|'; it is the LAST field, so it must not shift the others.
FAKE_TEMPLATE_OUT='false|WaitingForRescan|true|true|false|0|0|0|scan error: a|b|c'
chk "7e a '|' inside the error text does not corrupt the classification" \
    "$([ "$(_sync_status)" = "erroring" ] && echo 0 || echo 1)" "got $(_sync_status)"
chk "7f ... and the full error is recoverable for the message" \
    "$([ "$(_sync_last_error)" = "scan error: a|b|c" ] && echo 0 || echo 1)" "got '$(_sync_last_error)'"

# A non-converging session does not FAIL a flush, it HANGS (measured: `mutagen sync flush` still
# running after 15s on a breaker-halted session). So without a fail-fast it burns
# RT_FLUSH_TIMEOUT and returns 3 — "the daemon is still syncing" — and `rt exec` continues on 3.
# That is the fail-open: a command running against stale code behind a reassuring warning.
for rec in \
  'false|WaitingForRescan|true|true|false|0|0|0|alpha scan error: exceeded allowed entry count' \
  'false|HaltedOnRootEmptied|true|true|true|1|0|0|' \
; do
  FAKE_TEMPLATE_OUT="$rec"
  _sync_flush >/dev/null 2>&1; rc=$?
  chk "7g [$(echo "$rec" | cut -d'|' -f2)] flush returns 2 (nothing synced), never 3 (still working)" \
      "$([ "$rc" = 2 ] && echo 0 || echo 1)" "got $rc"
done
# 7h also passes with the `unknown` branch reverted — the stubbed mutagen fails inside
# `_run_bounded` too, so flush reaches 2 by the other road. It pins the OUTCOME (an unaskable
# daemon is never a benign flush), not the branch; 7c is what pins the branch.
FAKE_MUTAGEN_RC=1; FAKE_TEMPLATE_OUT=""
_sync_flush >/dev/null 2>&1; rc=$?
chk "7h an unaskable daemon -> flush returns 2, not a benign 0" \
    "$([ "$rc" = 2 ] && echo 0 || echo 1)" "got $rc"
FAKE_MUTAGEN_RC=0
unset -f mutagen

# ── 8. the same thing, against the REAL engine ───────────────────────────────
#
# Block 7 pins the parse; this pins that the recorded shapes are still what Mutagen emits. It is
# the check that would have caught the original defect, so when it cannot run it must SAY so —
# a silently-skipped block is indistinguishable from a passing one.
if ! command -v mutagen >/dev/null 2>&1; then
  printf '  SKIP 8 live Mutagen classification (mutagen not installed)\n'
else
  LIVE_SEL="rt-host=rtcanary,rt-profile=breaker"
  mutagen sync terminate --label-selector "$LIVE_SEL" >/dev/null 2>&1
  mkdir -p "$SCRATCH/live/a" "$SCRATCH/live/b"
  for i in 1 2 3 4 5 6 7 8; do echo "x$i" > "$SCRATCH/live/a/f$i.txt"; done
  # --max-entry-count=2 counts the root directory too, so 8 files trips the breaker.
  if mutagen sync create --name=rt-canary--breaker \
       --label='rt-host=rtcanary' --label='rt-profile=breaker' \
       --max-entry-count=2 "$SCRATCH/live/a" "$SCRATCH/live/b" >/dev/null 2>&1; then
    RT_HOST_GROUP=rtcanary; RT_PROFILE_NAME=breaker
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ "$(_sync_status)" = "erroring" ] && break
      sleep 1
    done
    live="$(_sync_status)"
    chk "8 a REAL entry-count breaker session classifies as erroring, not active" \
        "$([ "$live" = "erroring" ] && echo 0 || echo 1)" "classified '$live'"
    chk "8b ... and the live error text is reported" \
        "$(if [[ "$(_sync_last_error)" == *"entry count"* ]]; then echo 0; else echo 1; fi)" \
        "got '$(_sync_last_error)'"
    # Bounded so a regression cannot hang the suite: flush must REFUSE, not wait.
    t0=$(date +%s); RT_FLUSH_TIMEOUT=3 _sync_flush >/dev/null 2>&1; rc=$?; t1=$(date +%s)
    chk "8c ... and flush REFUSES it (rc 2) instead of waiting out the bound" \
        "$([ "$rc" = 2 ] && [ $((t1-t0)) -lt 3 ] && echo 0 || echo 1)" "rc=$rc after $((t1-t0))s"
    mutagen sync terminate --label-selector "$LIVE_SEL" >/dev/null 2>&1
  else
    printf '  SKIP 8 live entry-count classification (could not create a probe session)\n'
  fi

  # The state that broke the first version of this fix, driven for real: a Mutagen SAFETY BRAKE
  # reports an empty .LastError with both endpoints connected, so an error-only classifier calls
  # it healthy. This is the check that says the measured shape is still the shipped shape.
  mutagen sync terminate --label-selector "$LIVE_SEL" >/dev/null 2>&1
  rm -rf "$SCRATCH/live2"; mkdir -p "$SCRATCH/live2/a" "$SCRATCH/live2/b"
  for i in 1 2 3; do echo "keepme$i" > "$SCRATCH/live2/a/f$i.txt"; done
  if mutagen sync create --name=rt-canary--breaker \
       --label='rt-host=rtcanary' --label='rt-profile=breaker' \
       "$SCRATCH/live2/a" "$SCRATCH/live2/b" >/dev/null 2>&1; then
    RT_HOST_GROUP=rtcanary; RT_PROFILE_NAME=breaker
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ "$(_sync_status)" = "active" ] && break
      sleep 1
    done
    rm -f "$SCRATCH/live2/a"/*.txt      # one-sided root emptying
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      [ "$(_sync_status)" = "halted" ] && break
      sleep 1
    done
    live="$(_sync_status)"
    chk "8d a REAL safety-brake halt classifies as halted, though its .LastError is EMPTY" \
        "$([ "$live" = "halted" ] && echo 0 || echo 1)" "classified '$live'"
    chk "8e ... and it really does carry no error text (the reason 8d cannot key on one)" \
        "$([ -z "$(_sync_last_error)" ] && echo 0 || echo 1)" "got '$(_sync_last_error)'"
    mutagen sync terminate --label-selector "$LIVE_SEL" >/dev/null 2>&1
  else
    printf '  SKIP 8d live safety-brake classification (could not create a probe session)\n'
  fi
  RT_HOST_GROUP=h; RT_PROFILE_NAME=p
fi

# ── 8f. `exec` must not run when the sync state could not be established ──────
#
# Found by an INDEPENDENT REVIEW of this session's own change, not by the suite. `_has_sync` is
# a boolean and cannot carry "I could not find out": it returns false for `unknown`, and
# `cmd_exec` gated its whole flush block on `_has_sync`, so an unaskable daemon skipped the
# flush and ran the command with no warning — the most permissive path taken for the least
# established state. The classification was right and the consumer ignored it.
_sync_status() { echo "${FAKE_STATUS:-active}"; }
_ssh_test() { return 0; }
_exec_sync() { echo "RAN_THE_COMMAND"; }
_exec_bg()   { echo "RAN_THE_COMMAND"; }
load_config() { :; }
out=$( FAKE_STATUS=unknown; cmd_exec "echo hi" 2>&1 ); rc=$?
chk "8f exec REFUSES when the sync state could not be established" \
    "$([ "$rc" != 0 ] && ! grep -q RAN_THE_COMMAND <<< "$out" && echo 0 || echo 1)" \
    "rc=$rc out=$(head -c 160 <<< "$out")"
out=$( FAKE_STATUS=unknown; cmd_exec --no-flush "echo hi" 2>&1 ); rc=$?
chk "8g ... unless --no-flush says the caller meant the remote as it stands" \
    "$(grep -q RAN_THE_COMMAND <<< "$out" && echo 0 || echo 1)" "rc=$rc out=$(head -c 160 <<< "$out")"

# ── 9. `status --all` enumerates CONFIGURED profiles ─────────────────────────
#
# It walked state directories — the record `connect` writes — so a profile that was configured
# and never connected did not exist as far as this command was concerned. That is the question
# you run it to answer, and the SKILL's first instruction is to run it to enumerate profiles.
# Measured on the author's machine 2026-08-05: 11 configs, 10 state dirs, one invisible.
RT_HOME_SAVE="$RT_HOME"
export RT_HOME="$SCRATCH/conf2"
mkdir -p "$RT_HOME/h1" "$RT_HOME/_archive" "$RT_HOME/.rt/h1/connected" "$RT_HOME/.rt/h1/orphan"
cat > "$RT_HOME/h1/host.conf"  <<'EOF'
REMOTE_HOST=host-one
EOF
cat > "$RT_HOME/h1/connected.conf" <<'EOF'
REMOTE_DIR=/remote/connected
EOF
# NEVER connected: no state dir. This is the row the old enumeration dropped.
cat > "$RT_HOME/h1/neverconnected.conf" <<'EOF'
REMOTE_DIR=/remote/never
EOF
# A retired config outside any host group must not be mistaken for a profile.
cat > "$RT_HOME/_archive/old.conf" <<'EOF'
REMOTE_DIR=/remote/retired
EOF
printf 'host-one' > "$RT_HOME/.rt/h1/connected/host"
printf '/remote/connected' > "$RT_HOME/.rt/h1/connected/remote_dir"
printf '/local/connected' > "$RT_HOME/.rt/h1/connected/local_dir"

_sync_status() { echo none; }
all_out="$(_status_all 2>&1)"

chk "9 a configured-but-never-connected profile is LISTED" \
    "$(grep -q 'h1/neverconnected' <<< "$all_out" && echo 0 || echo 1)" "$(head -c 200 <<< "$all_out")"
chk "9b a connected profile is still listed" \
    "$(grep -q 'h1/connected' <<< "$all_out" && echo 0 || echo 1)"
chk "9c a state dir with NO config is listed and MARKED (it is still syncing)" \
    "$(grep -q 'h1/orphan' <<< "$all_out" && grep -q 'no config file' <<< "$all_out" && echo 0 || echo 1)" \
    "$(grep 'orphan' <<< "$all_out")"
# Asserted on the ROW SHAPE `[_archive/...]`, not on the words in the config. A looser
# "must not contain 'old'" fired on the scratch path — /var/folders contains it — which is the
# same over-broad-negative trap this suite exists to avoid, just pointing the other way.
chk "9d a retired config outside a host group is NOT counted as a profile" \
    "$(grep -q '^  \[_archive/' <<< "$all_out" && echo 1 || echo 0)" "$(grep '_archive' <<< "$all_out")"
chk "9e the enumeration names its own SCOPE (count + where it looked)" \
    "$(grep -q '3 profile(s) known to' <<< "$all_out" && echo 0 || echo 1)" \
    "$(grep 'profile(s)' <<< "$all_out")"
# The identity of a never-connected profile comes from sourcing its config, and configs are
# bash: reading several in one shell would leak each one's vars into the next. `neverconnected`
# and `connected` set DIFFERENT REMOTE_DIRs, so a leak shows up as the wrong path on a row.
chk "9f sourcing one profile's config does not leak into the next" \
    "$(grep -q 'h1/neverconnected.*/remote/never' <<< "$all_out" && echo 0 || echo 1)" \
    "$(grep 'neverconnected' <<< "$all_out")"

# A FRESH INSTALL: no configs, no state. This is the empty-array expansion path, and macOS ships
# bash 3.2, where `"${arr[@]}"` on an empty array is an "unbound variable" error under `set -u` —
# so the very first command a new user runs is the one that would abort.
rm -rf "$RT_HOME"; mkdir -p "$RT_HOME"
out="$(_status_all 2>&1)"; rc=$?
chk "9g a completely empty RT_HOME says so instead of erroring (bash 3.2 empty-array path)" \
    "$([ "$rc" -eq 0 ] && grep -q 'No profiles configured' <<< "$out" && ! grep -qi 'unbound' <<< "$out" && echo 0 || echo 1)" \
    "rc=$rc out=$(head -c 160 <<< "$out")"

rm -rf "$RT_HOME"
export RT_HOME="$RT_HOME_SAVE"

# ── 10. disconnect must not report success it did not achieve ────────────────
#
# `mutagen sync terminate … || true` discarded every failure, `clear_state` then ran
# unconditionally, and `Disconnected` was printed with rc 0. So a termination that failed left
# the session running — still propagating deletions — with the only local record of it deleted,
# and told the caller it was done.
#
# `cmd_disconnect` calls `die`, which exits, so each case runs in a subshell; `clear_state` is
# therefore observed through a MARKER FILE rather than a variable, which would not survive it.
set +e; source "$RT" 2>/dev/null; set +e
RT_PROFILE="h/p"; RT_HOST_GROUP="h"; RT_PROFILE_NAME="p"; RT_SESSION_PREFIX="rt_h_p_bg_"
LOCAL_DIR="$SCRATCH/local"
info() { :; }
# `warn` stays REAL here: 10c is about what the operator is told, and silencing it would make
# the check pass on an implementation that swallowed mutagen's reason — the same swallowing
# this block exists to catch.
warn() { printf '!! %s\n' "$*" >&2; }
load_config() { :; }
_ssh_test() { return 1; }                     # isolate: skip the background-job branch
clear_state() { touch "$SCRATCH/cleared"; }

# _d <initial-status> <terminate-rc> <post-termination-status>
#      -> "<rc>|<cleared>|<output>"
#
# `_sync_status` must answer DIFFERENTLY for the two probes: once before terminating, once to
# establish the session is actually gone. A single-valued stub cannot express the case that
# matters — "gone" vs "I could not tell" at the postcondition — so the call is counted through a
# FILE, since `cmd_disconnect` reads it inside a subshell.
_d() {
  rm -f "$SCRATCH/cleared"
  local st="$1" trc="$2" post="$3" out rc=0
  printf '0' > "$SCRATCH/dcalls"
  out=$(
    eval "_sync_status() {
      local n; n=\$(( \$(cat '$SCRATCH/dcalls') + 1 )); printf '%s' \"\$n\" > '$SCRATCH/dcalls'
      if [ \"\$n\" -eq 1 ]; then echo $st; else echo $post; fi
    }"
    eval "_sync_terminate() { echo 'unable to terminate: connection refused'; return $trc; }"
    cmd_disconnect 2>&1
  ) || rc=$?
  printf '%s|%s|%s' "$rc" "$([ -e "$SCRATCH/cleared" ] && echo yes || echo no)" "$out"
}

r="$(_d active 1 none)"; rc="${r%%|*}"; rest="${r#*|}"; cleared="${rest%%|*}"; out="${rest#*|}"
chk "10 a FAILED terminate exits non-zero (was: rc 0, 'Disconnected')" \
    "$([ "$rc" != 0 ] && echo 0 || echo 1)" "rc=$rc"
chk "10b ... and does NOT delete the local record of a session that may still be running" \
    "$([ "$cleared" = "no" ] && echo 0 || echo 1)" "cleared=$cleared"
chk "10c ... and quotes mutagen's own reason" \
    "$(grep -q 'connection refused' <<< "$out" && echo 0 || echo 1)" "$(head -c 160 <<< "$out")"

r="$(_d active 0 active)"; rc="${r%%|*}"; rest="${r#*|}"; cleared="${rest%%|*}"
chk "10d terminate reporting SUCCESS while the session survives is still a failure" \
    "$([ "$rc" != 0 ] && [ "$cleared" = "no" ] && echo 0 || echo 1)" "rc=$rc cleared=$cleared"

# The case an independent review found, which nothing here covered: the daemon becomes
# UNASKABLE between the terminate and the confirmation. `_has_sync` returned false for that —
# indistinguishable from "no session" — so the local record was deleted and rc 0 returned over a
# session that may still exist.
r="$(_d active 0 unknown)"; rc="${r%%|*}"; rest="${r#*|}"; cleared="${rest%%|*}"
chk "10d2 a daemon that goes unaskable AFTER terminating is not proof the session is gone" \
    "$([ "$rc" != 0 ] && [ "$cleared" = "no" ] && echo 0 || echo 1)" "rc=$rc cleared=$cleared"

r="$(_d active 0 none)"; rc="${r%%|*}"; rest="${r#*|}"; cleared="${rest%%|*}"; out="${rest#*|}"
chk "10e a termination that is ESTABLISHED clears state and succeeds" \
    "$([ "$rc" = 0 ] && [ "$cleared" = "yes" ] && echo 0 || echo 1)" "rc=$rc cleared=$cleared"

r="$(_d unknown 0 none)"; rc="${r%%|*}"; rest="${r#*|}"; cleared="${rest%%|*}"
chk "10f an unaskable daemon does not license deleting the record either" \
    "$([ "$rc" != 0 ] && [ "$cleared" = "no" ] && echo 0 || echo 1)" "rc=$rc cleared=$cleared"

r="$(_d none 0 none)"; rc="${r%%|*}"; rest="${r#*|}"; cleared="${rest%%|*}"
chk "10g no session at all still disconnects cleanly" \
    "$([ "$rc" = 0 ] && [ "$cleared" = "yes" ] && echo 0 || echo 1)" "rc=$rc cleared=$cleared"

# ── 11. the documented sync scope matches the implemented one ────────────────
#
# The docs said files sync to and from the remote and never enumerated the exclusions, while the
# defaults silently drop `outputs/`, `checkpoints/`, `wandb/` and more — so a result written to
# any of them never reached the local replica and nothing said why. And because Mutagen freezes
# ignores at session-CREATE time, the natural fix (edit MUTAGEN_IGNORE) changes nothing about
# the running session, leaving the config file wrong about what is excluded.
set +e; source "$RT" 2>/dev/null; set +e
RT_PROFILE="h/p"; RT_HOST_GROUP="h"; RT_PROFILE_NAME="p"
info() { :; }; warn() { printf '!! %s\n' "$*" >&2; }

# Every default pattern must appear in BOTH user-facing documents. This is what stops the code
# array and the prose lists from drifting; a pattern added to `rt` alone now fails here.
DOCS_DIR="$(dirname "$HERE")"
missing_doc=""
for pat in "${RT_DEFAULT_IGNORES[@]}"; do
  grep -qF -- "$pat" "$DOCS_DIR/SKILL.md"  || missing_doc="$missing_doc SKILL:$pat"
  grep -qF -- "$pat" "$DOCS_DIR/README.md" || missing_doc="$missing_doc README:$pat"
done
chk "11 every default ignore pattern is enumerated in SKILL.md and README.md" \
    "$([ -z "$missing_doc" ] && echo 0 || echo 1)" "undocumented:$missing_doc"
# POSITIVE FIXTURE: the check above is only worth having if it can fail. A pattern that is NOT
# in the docs must make it fire — otherwise it is a structural check matching nothing, which is
# indistinguishable from a clean tree.
grep -qF -- "definitely-not-a-documented-ignore-pattern/" "$DOCS_DIR/SKILL.md"
chk "11a ... and that check can still fire (an undocumented pattern is not found)" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"

# `sync status` must report the LIVE session's ignores, and say so when the config has drifted.
MUTAGEN_IGNORE=("data/")
_has_sync() { return 0; }
_sync_live_vcs() { echo IgnoreVCSModeIgnore; }

_sync_live_ignores() { _ignore_patterns; }        # live == config
out="$(_sync_report_ignores 2>&1)"
chk "11b with no drift, the live ignore set is printed and nothing is claimed about drift" \
    "$(grep -q 'LIVE session' <<< "$out" && ! grep -qi 'DIFFER' <<< "$out" && echo 0 || echo 1)" \
    "$(head -c 200 <<< "$out")"
chk "11c ... and it lists an actual default pattern" \
    "$(grep -q 'checkpoints/' <<< "$out" && echo 0 || echo 1)"

# The case that motivated this: someone added a pattern to MUTAGEN_IGNORE and the running
# session never picked it up. The config now says one thing and the session enforces another.
_sync_live_ignores() { printf '%s\n' "${RT_DEFAULT_IGNORES[@]}"; }   # live lacks `data/`
out="$(_sync_report_ignores 2>&1)"
chk "11d an edited MUTAGEN_IGNORE that the live session never picked up is REPORTED" \
    "$(grep -qi 'DIFFER' <<< "$out" && echo 0 || echo 1)" "$(head -c 240 <<< "$out")"
chk "11e ... and the specific pattern that is only in the config is named" \
    "$(grep -q 'only CONFIG: *data/' <<< "$out" && echo 0 || echo 1)" \
    "$(grep 'only ' <<< "$out" | head -c 200)"

# With no live session there is nothing to report ON — saying "effective ignores" would claim a
# session's state. It must say these are what the NEXT connect would apply.
_has_sync() { return 1; }
out="$(_sync_report_ignores 2>&1)"
chk "11f with no session, the list is labelled as prospective, not as live" \
    "$(grep -q 'next connect' <<< "$out" && ! grep -q 'LIVE session' <<< "$out" && echo 0 || echo 1)" \
    "$(head -c 200 <<< "$out")"

# ── 12. a bloated sync set is named BEFORE it becomes latency ────────────────
#
# A courier bucket degrades silently as finished handoffs pile up. Measured 2026-08-01: 10,292
# files / 2.6 GB put a flush in `Scanning files` for 20+ minutes — a 9 KB push took ~40 minutes
# — while the same bucket at 232 files / 41 MB flushed in 7 seconds. Nothing reported the size
# until the latency was the symptom.
set +e; source "$RT" 2>/dev/null; set +e
RT_PROFILE="h/p"; RT_HOST_GROUP="h"; RT_PROFILE_NAME="p"
RT_STATE_DIR="$SCRATCH/state12"
info() { :; }; warn() { printf '!! %s\n' "$*" >&2; }
mutagen() { printf '%s\n' "$FAKE_TEMPLATE_OUT"; return 0; }

bloat() {  # bloat <record> -> stderr of one _sync_warn_if_bloated, with the stamp cleared
  rm -rf "$RT_STATE_DIR"
  FAKE_TEMPLATE_OUT="$1"
  _sync_warn_if_bloated 2>&1
}

#                       paused|status|aconn|bconn|scanned|dirs|files|bytes|err
BIG='false|Watching|true|true|true|500|10292|2791728742|'
SMALL='false|Watching|true|true|true|20|232|43000000|'
UNSCANNED='false|WaitingForRescan|true|true|false|0|0|0|alpha scan error: exceeded allowed entry count'

out="$(bloat "$BIG")"
chk "12 a 10,292-file / 2.6 GB sync set is reported at flush time" \
    "$(grep -q 'LARGE' <<< "$out" && echo 0 || echo 1)" "$(head -c 200 <<< "$out")"
chk "12b ... and the message says PRUNE, not 'add another ignore'" \
    "$(grep -q 'PRUNE' <<< "$out" && echo 0 || echo 1)" "$(head -c 200 <<< "$out")"

out="$(bloat "$SMALL")"
chk "12c the same bucket at 232 files / 41 MB says nothing" \
    "$([ -z "$out" ] && echo 0 || echo 1)" "$(head -c 200 <<< "$out")"

# The counts of an UNSCANNED endpoint are zeros that mean "did not look", not "nothing there".
# Reporting them as a measurement — in either direction — is the fail-open this tool keeps
# closing, so `_sync_counts` must refuse rather than answer.
out="$(bloat "$UNSCANNED")"
chk "12d an endpoint that has not been scanned yields no size CLAIM at all" \
    "$([ -z "$out" ] && echo 0 || echo 1)" "$(head -c 200 <<< "$out")"
FAKE_TEMPLATE_OUT="$UNSCANNED"
_sync_counts >/dev/null 2>&1
chk "12e ... and _sync_counts REFUSES rather than returning 0 files" "$([ $? -ne 0 ] && echo 0 || echo 1)"
FAKE_TEMPLATE_OUT="$BIG"
chk "12f ... while a scanned endpoint does return its counts" \
    "$([ "$(_sync_counts)" = "10292 2791728742" ] && echo 0 || echo 1)" "got '$(_sync_counts)'"

# Rate limiting: `rt exec` flushes on every call, and a warning printed hundreds of times is one
# that gets filtered — this workspace already has a caller grepping `^!! Sync flush` out of its
# output. The second call inside the interval must be silent, and it must come back after it.
rm -rf "$RT_STATE_DIR"; FAKE_TEMPLATE_OUT="$BIG"
first="$(_sync_warn_if_bloated 2>&1)"
second="$(_sync_warn_if_bloated 2>&1)"
chk "12g the warning is rate-limited (second flush inside the interval is silent)" \
    "$([ -n "$first" ] && [ -z "$second" ] && echo 0 || echo 1)" "first=${#first} second=${#second}"
third="$(RT_BLOAT_WARN_INTERVAL=0 _sync_warn_if_bloated 2>&1)"
chk "12h ... and it returns once the interval has passed (not silenced permanently)" \
    "$([ -n "$third" ] && echo 0 || echo 1)" "third=${#third}"

out="$(RT_SYNC_WARN_FILES= RT_SYNC_WARN_BYTES= bloat "$BIG")"
chk "12i the thresholds can be disabled" "$([ -z "$out" ] && echo 0 || echo 1)" "$(head -c 120 <<< "$out")"

# EVERY check above calls `_sync_warn_if_bloated` directly, so all of them pass with the call
# REMOVED from `_sync_flush` — measured, and the reason this one exists. The entry asks for the
# warning at FLUSH time; a suite that only tests the function tests the wrong noun.
rm -rf "$RT_STATE_DIR"; FAKE_TEMPLATE_OUT="$BIG"
out="$(_sync_flush 2>&1)"
chk "12j the warning is reached THROUGH _sync_flush, not merely defined" \
    "$(grep -q 'LARGE' <<< "$out" && echo 0 || echo 1)" "$(head -c 160 <<< "$out")"
unset -f mutagen

# ── 13. agent-supplied values are DATA, not remote shell ─────────────────────
#
# `_ssh` hands a STRING to a remote login shell, so anything interpolated into it is shell
# source unless something makes it data. `slurm cancel` built `scancel $*`, so
# `rt slurm cancel '123; some-command'` constructed a remote compound command; log ids reached
# `tail -f ~/.rt_logs/<id>.log` unquoted the same way.
#
# These checks RUN the captured string against stub binaries, so they pin what the remote shell
# would actually do rather than what the source looks like.
set +e; source "$RT" 2>/dev/null; set +e
# `_init_profile` rather than assigning the globals by hand. Sourcing `rt` never runs it (main
# is guarded), so RT_CONF stays EMPTY — and a `load_config` in this block would then die with
# "Config not found" before reaching anything under test. That is a false pass: check 13e was
# passing for exactly that reason until a mutation run exposed it.
RT_PROFILE="h/p"; _init_profile
REMOTE_HOST="example-host"; LOCAL_DIR="$SCRATCH/local"; REMOTE_DIR="$SCRATCH/proj"
info() { :; }; warn() { :; }

mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/scancel" <<'EOF'
#!/bin/sh
for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
EOF
chmod +x "$SCRATCH/bin/scancel"

# _shq must survive every metacharacter, under /bin/sh as well as bash — the remote runs a
# LOGIN shell, which is not necessarily bash.
shq_bad=""
for v in "plain" "it's" "a'b'c" '$(id)' '`id`' '; echo x' 'a b' '*' '\' '"q"'; do
  got=$(/bin/sh -c "printf '%s' $(_shq "$v")" 2>/dev/null)
  [ "$got" = "$v" ] || shq_bad="$shq_bad [$v->$got]"
done
chk "13 _shq round-trips every metacharacter through /bin/sh" \
    "$([ -z "$shq_bad" ] && echo 0 || echo 1)" "$shq_bad"

# A job id reaches scancel as ONE argv element, whatever it contains.
# The capture goes to a FILE as well as a variable: `_slurm_submit` calls `_ssh` inside a
# command substitution, so a variable assignment there dies with the subshell and the check
# would read an empty string as "nothing was sent" — a false pass.
CAPTURED=""; _ssh() { CAPTURED="$*"; printf '%s' "$*" > "$SCRATCH/captured"; }
_ssh_test() { return 0; }
rm -f "$SCRATCH/captured"
_slurm_cancel 123 456_7 >/dev/null 2>&1
argv="$(cd "$SCRATCH" && PATH="$SCRATCH/bin:$PATH" sh -c "$CAPTURED" 2>/dev/null | tr '\n' ' ')"
chk "13b two job ids arrive as exactly two arguments" \
    "$([ "$argv" = "ARG[123] ARG[456_7] " ] && echo 0 || echo 1)" "argv='$argv' cmd='$CAPTURED'"

# The recorded attack: `rt slurm cancel '123; <command>'`. It must be refused BEFORE any ssh.
#
# The "nothing was sent" half is asserted through the capture FILE. Asserting it through the
# `CAPTURED` variable was vacuous: `_slurm_cancel` runs in a subshell here (it calls `die`), so
# the variable could not have changed whatever the code did, and the follow-up then executed the
# parent's untouched placeholder. Both halves passed for no reason.
rm -f "$SCRATCH/PWNED" "$SCRATCH/captured"
( _slurm_cancel "123; touch $SCRATCH/PWNED" ) >/dev/null 2>&1; rc=$?
sent="$(cat "$SCRATCH/captured" 2>/dev/null || true)"
chk "13c an id carrying a command separator is REFUSED, and nothing is sent" \
    "$([ "$rc" != 0 ] && [ -z "$sent" ] && echo 0 || echo 1)" "rc=$rc sent='$sent'"
( cd "$SCRATCH" && PATH="$SCRATCH/bin:$PATH" sh -c "$sent" ) >/dev/null 2>&1
chk "13d ... and no injected command ran" \
    "$([ ! -e "$SCRATCH/PWNED" ] && echo 0 || echo 1)" "PWNED exists"

# Same boundary, other entry points.
rm -f "$SCRATCH/PWNED"
( cmd_logs "x; touch $SCRATCH/PWNED" ) >/dev/null 2>&1; rc=$?
chk "13e a log id carrying a command separator is refused" \
    "$([ "$rc" != 0 ] && [ ! -e "$SCRATCH/PWNED" ] && echo 0 || echo 1)" "rc=$rc"
( _slurm_logs "1; touch $SCRATCH/PWNED" ) >/dev/null 2>&1; rc=$?
chk "13f a slurm log id carrying a command separator is refused" \
    "$([ "$rc" != 0 ] && [ ! -e "$SCRATCH/PWNED" ] && echo 0 || echo 1)" "rc=$rc"
( _require_jobname "x;touch /tmp/x" ) >/dev/null 2>&1
chk "13g an --bg job NAME carrying shell text is refused by the grammar" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"
( _require_jobname "build-2" ) >/dev/null 2>&1
chk "13h ... while an ordinary name is still accepted" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# The submit SCRIPT PATH is user-supplied and is the one value here that ONLY quoting protects
# — it has no grammar and no config-time check. An apostrophe is the payload that matters: the
# old `'${script}'` form is already inert against `$(…)` and backticks, so a check built around
# those would pass with the fix reverted. (That is not hypothetical — the first version of this
# check did exactly that, and a mutation run caught it.)
cat > "$SCRATCH/bin/sbatch" <<'EOF'
#!/bin/sh
for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
echo "Submitted batch job 1"
EOF
chmod +x "$SCRATCH/bin/sbatch"
rm -f "$SCRATCH/PWNED"
RT_STATE_DIR="$SCRATCH/state13"; SLURM_ENABLED=1; SLURM_LOG_DIR="$SCRATCH"; SLURM_SBATCH_ARGS=""
_has_sync() { return 1; }
rm -f "$SCRATCH/captured"
EVIL="don't; touch $SCRATCH/PWNED.sbatch"
_slurm_submit --assume-staged "$EVIL" >/dev/null 2>&1
sent="$(cat "$SCRATCH/captured" 2>/dev/null)"
argv="$(cd "$SCRATCH" && PATH="$SCRATCH/bin:$PATH" sh -c "$sent" 2>/dev/null | grep '^ARG\[')"
chk "13i an apostrophe + separator in a script path stays ONE argument" \
    "$([ "$argv" = "ARG[$EVIL]" ] && echo 0 || echo 1)" "argv='$argv' sent='$sent'"
chk "13j ... and the injected command did not run" \
    "$([ ! -e "$SCRATCH/PWNED.sbatch" ] && echo 0 || echo 1)" "sent='$sent'"

# An apostrophe in REMOTE_DIR used to break the ad-hoc single quoting SILENTLY. It cannot be
# carried through the three quoting levels of the --bg payload, so it is refused with a clear
# message instead of building a malformed remote command.
mkdir -p "$RT_HOME/q"
printf 'REMOTE_HOST=h\n' > "$RT_HOME/q/host.conf"
# A VALID bash assignment whose VALUE contains an apostrophe. Writing `REMOTE_DIR=/tmp/it's`
# instead would be an unterminated quote — the config would fail to source and the check would
# pass for the wrong reason.
printf 'REMOTE_DIR="/tmp/it%ss"\n' "'" > "$RT_HOME/q/r.conf"
( RT_PROFILE="q/r"; _init_profile; load_config ) >/dev/null 2>&1
chk "13l a REMOTE_DIR containing an apostrophe fails loudly, not silently" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"
# ... and the ordinary case still loads, so 13j is not passing because load_config is broken.
printf 'REMOTE_DIR="/tmp/ordinary"\n' > "$RT_HOME/q/r.conf"
( RT_PROFILE="q/r"; _init_profile; load_config ) >/dev/null 2>&1
chk "13m ... while an ordinary REMOTE_DIR still loads" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# ── 14. bounded reads work without a GNU timeout(1) ──────────────────────────
#
# Callers bounded remote reads by writing `timeout 30 rt … exec …` on the Mac, and macOS has NO
# `timeout` — it is `gtimeout`, from coreutils, usually not installed. The command died with
# "command not found: timeout" without running. A sibling report records the nastier form:
# written as `timeout 120 <cmd> | head -3`, the PIPELINE still exits 0 because `head` succeeded,
# so a read that never happened looks like a success that returned nothing.
set +e; source "$RT" 2>/dev/null; set +e
RT_PROFILE="h/p"; _init_profile
REMOTE_HOST="stub-host"; SSH_OPTS=(-o BatchMode=yes); REMOTE_DIR="$SCRATCH/proj"
info() { :; }; warn() { :; }

# A real executable, not a shell function: backgrounding a FUNCTION forks a subshell, so `$!`
# would be the subshell and the check would be scoring the wrong process — which is exactly the
# bug this block caught in the implementation.
LATE="$SCRATCH/late-write"
cat > "$SCRATCH/bin/ssh" <<EOF
#!/bin/sh
case "\$*" in
  *SLOW*) sleep 4; echo LATE >> "$LATE"; echo SLOW_DONE ;;
  *)      echo REMOTE_OK ;;
esac
EOF
chmod +x "$SCRATCH/bin/ssh"
PATH_SAVE="$PATH"; export PATH="$SCRATCH/bin:$PATH"

rm -f "$LATE"
# Output goes to a FILE, not through `$( )`. A command substitution waits for every writer to
# close the pipe, and this stub leaves an orphaned `sleep` holding the inherited stdout — so
# capturing would measure the orphan's lifetime, not the bound, and read 5s for a bound of 2.
# (The real path was measured live at 3.3s for a bound of 3: ssh has no such local child.)
t0=$(date +%s); _ssh_bounded 2 "SLOW" >"$SCRATCH/o14" 2>/dev/null; rc=$?; t1=$(date +%s)
chk "14 a bounded read returns 124 at the bound, with no GNU timeout(1) anywhere" \
    "$([ "$rc" = 124 ] && [ $((t1-t0)) -lt 4 ] && echo 0 || echo 1)" "rc=$rc after $((t1-t0))s"
chk "14b ... and it returns nothing rather than the slow command's output" \
    "$([ ! -s "$SCRATCH/o14" ] && echo 0 || echo 1)" "out='$(cat "$SCRATCH/o14")'"
# The killed process must really be dead. With the bound applied to a subshell instead of to
# ssh itself, the ssh survives, keeps the pipe open and writes AFTER the caller gave up —
# measured live before this was fixed: the bound returned at 3s and the output arrived at 30s.
sleep 4
chk "14c ... and the killed remote client does not write after the bound elapsed" \
    "$([ ! -e "$LATE" ] && echo 0 || echo 1)" "late write happened"

_ssh_bounded 10 "quick" >"$SCRATCH/o14b" 2>/dev/null; rc=$?
chk "14d a command that finishes inside the bound returns 0 and its output" \
    "$([ "$rc" = 0 ] && [ "$(cat "$SCRATCH/o14b")" = "REMOTE_OK" ] && echo 0 || echo 1)" \
    "rc=$rc out='$(cat "$SCRATCH/o14b")'"

# The flag is validated at the boundary, like every other agent-supplied value.
_ssh_test() { return 0; }; _has_sync() { return 1; }; load_config() { :; }
( cmd_exec --timeout abc "echo hi" ) >/dev/null 2>&1
chk "14e --timeout rejects a non-numeric bound" "$([ $? -ne 0 ] && echo 0 || echo 1)"
( cmd_exec --timeout 0 "echo hi" ) >/dev/null 2>&1
chk "14f --timeout rejects zero" "$([ $? -ne 0 ] && echo 0 || echo 1)"
( cmd_exec --bg --timeout 5 "echo hi" ) >/dev/null 2>&1
chk "14g --timeout with --bg is refused (a background job outlives this shell)" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"
export PATH="$PATH_SAVE"

# END-TO-END: `cmd_exec --timeout N` must actually ROUTE through the bounded helper. Checks
# 14e-14g only pin the flag's validation, and all three pass with the whole feature reverted —
# old `cmd_exec` rejects `--timeout` as an unknown flag, which is also non-zero.
export PATH="$SCRATCH/bin:$PATH"
_ssh_test() { return 0; }; _has_sync() { return 1; }; load_config() { :; }
_sync_status() { echo none; }
rm -f "$SCRATCH/late-write2"
#
# The stub sleeps far longer than the bound because the output ACCOUNTING added a second, bounded
# wait after the kill (`_exec_reap`, 2s), so a working bound now costs ~3s here rather than ~1s.
# Against the original `sleep 4` / `-lt 4` that left no margin on either side — a working bound at
# 3s and a broken one at 4s — and it flaked once under load. Widening the gap restores what the
# check is for: ~3s when the bound holds, ~12s when it does not.
cat > "$SCRATCH/bin/ssh" <<EOF
#!/bin/sh
case "\$*" in
  *SLOWX*) sleep 12; echo LATE >> "$SCRATCH/late-write2" ;;
  *)       echo REMOTE_OK ;;
esac
EOF
chmod +x "$SCRATCH/bin/ssh"
t0=$(date +%s); cmd_exec --timeout 1 "SLOWX" >/dev/null 2>&1; rc=$?; t1=$(date +%s)
chk "14i cmd_exec --timeout routes through the bounded helper (rc 124, bound honoured)" \
    "$([ "$rc" = 124 ] && [ $((t1-t0)) -lt 6 ] && echo 0 || echo 1)" "rc=$rc after $((t1-t0))s"
export PATH="$PATH_SAVE"

# The entry's fallback clause: say so where the bounded-read path is documented.
DOCS_DIR="$(dirname "$HERE")"
chk "14h the docs name the macOS timeout(1) trap at the bounded-read path" \
    "$(grep -q 'gtimeout' "$DOCS_DIR/SKILL.md" && grep -q 'timeout' "$DOCS_DIR/README.md" && echo 0 || echo 1)"

# ── 15. `rt verify` — the arrival assertion ──────────────────────────────────
#
# Nothing told a caller when a staged file had actually ARRIVED, so callers slept a fixed
# interval and used whatever was there. Measured 2026-08-01: a patched launcher was staged,
# waited on for ten seconds, and the still-stale remote copy was copied into place. `bash -n`
# passed because the OLD file is valid shell, so the run started, died instantly, and held 8
# GPUs idle for ~25 minutes. A returned flush was never the missing signal — it forces a sync
# CYCLE and does not prove the endpoints are equal.
set +e; source "$RT" 2>/dev/null; set +e
RT_PROFILE="h/p"; _init_profile
REMOTE_HOST="stub-host"; REMOTE_DIR="/remote/proj"
LOCAL_DIR="$SCRATCH/vlocal"; rm -rf "$LOCAL_DIR"; mkdir -p "$LOCAL_DIR/sub"
info() { :; }; warn() { :; }
load_config() { :; }
_sync_status() { echo "${FAKE_STATUS:-active}"; }
_sync_live_ignores() { printf 'outputs/\n*.pyc\nCLAUDE.md\n'; }

printf 'launcher v2\n' > "$LOCAL_DIR/launch.sh"
printf 'config A\n'    > "$LOCAL_DIR/sub/cfg.yaml"

# The stub plays the REMOTE side: it answers with whatever manifest the test dictates.
_ssh() { printf '%s\n' "$FAKE_REMOTE"; return "${FAKE_SSH_RC:-0}"; }
FAKE_SSH_RC=0
_mk_remote() { _local_digests "$@"; }        # remote agrees with local

FAKE_REMOTE="$(_mk_remote launch.sh sub/cfg.yaml)"
( cmd_verify --timeout 0 launch.sh sub/cfg.yaml ) >/dev/null 2>&1
chk "15 identical content on both sides verifies (rc 0)" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# The incident: the remote still holds the OLD file. Valid shell, wrong content.
FAKE_REMOTE="$(printf '%s  launch.sh\n' "$(printf 'launcher v1\n' | shasum -a 256 | awk '{print $1}')")
$(_local_digests sub/cfg.yaml)"
out=$( cmd_verify --timeout 0 launch.sh sub/cfg.yaml 2>&1 ); rc=$?
chk "15b a stale remote copy is NOT arrival (rc 3)" "$([ "$rc" = 3 ] && echo 0 || echo 1)" "rc=$rc"
chk "15c ... and the differing path is named" \
    "$(grep -q 'launch.sh.*differs' <<< "$out" && echo 0 || echo 1)" "$(head -c 200 <<< "$out")"

FAKE_REMOTE="MISSING  launch.sh
$(_local_digests sub/cfg.yaml)"
out=$( cmd_verify --timeout 0 launch.sh sub/cfg.yaml 2>&1 ); rc=$?
chk "15d a path absent on the remote is reported as absent, not as a mismatch" \
    "$([ "$rc" = 3 ] && grep -q 'launch.sh.*absent' <<< "$out" && echo 0 || echo 1)" "rc=$rc"

# The remote holds the right BYTES under the wrong NAMES. Worth pinning on its own: "both files
# are present and every digest I expected exists somewhere" is the shape a sloppier check would
# accept, and the caller would launch the wrong file.
#
# What actually catches it is not stated as path binding: a mutation run showed this check still
# passes with the path removed from the manifest, because the two manifests then differ in
# format and order anyway. The path in each line earns its place by making the PER-FILE
# diagnosis possible — 15c and 15d are the checks that fail when it is removed.
printf 'launcher v2\n' > "$LOCAL_DIR/a.sh"; printf 'config A\n' > "$LOCAL_DIR/b.sh"
FAKE_REMOTE="$(printf '%s  a.sh\n%s  b.sh\n' \
  "$(printf 'config A\n'   | shasum -a 256 | awk '{print $1}')" \
  "$(printf 'launcher v2\n' | shasum -a 256 | awk '{print $1}')")"
( cmd_verify --timeout 0 a.sh b.sh ) >/dev/null 2>&1
chk "15e the right bytes under the wrong names do not verify" \
    "$([ $? -eq 3 ] && echo 0 || echo 1)"

# Everything that can NEVER be verified is decided before any waiting, and exits 2 — not 1, and
# never 3, because 3 means "not yet" and would invite a caller to retry forever.
FAKE_REMOTE="$(_mk_remote launch.sh)"
mkdir -p "$LOCAL_DIR/outputs"; printf 'x\n' > "$LOCAL_DIR/outputs/res.txt"
ln -sf launch.sh "$LOCAL_DIR/link.sh"
for c in "outputs/res.txt:an ignored path" "/etc/passwd:an absolute path" "../x:a traversal" \
         "sub:a directory" "link.sh:a symlink" "nope.txt:a path absent locally"; do
  path="${c%%:*}"; what="${c#*:}"
  ( cmd_verify --timeout 0 "$path" ) >/dev/null 2>&1
  chk "15f [$what] is refused with rc 2 (blocked), not 1 and not 3" \
      "$([ $? -eq 2 ] && echo 0 || echo 1)"
done

# A newline splits one path across two manifest lines on BOTH sides, so the comparison and the
# per-file mismatch report would describe something other than the file being asked about.
( cmd_verify --timeout 0 "$(printf 'a\nb')" ) >/dev/null 2>&1
chk "15f2 a path containing a newline is refused (the manifest is line-oriented)" \
    "$([ $? -eq 2 ] && echo 0 || echo 1)"

# ORDER: the ignore check reads the LIVE session, so it is meaningless when the daemon cannot be
# asked. With both an unaskable daemon AND an ignored path, the SESSION must be what is
# reported — otherwise "not ignored" gets asserted on the strength of an empty answer.
out=$( FAKE_STATUS=unknown; cmd_verify --timeout 0 outputs/res.txt 2>&1 ); rc=$?
chk "15f3 an unaskable daemon is reported as such, not silently treated as 'not ignored'" \
    "$([ "$rc" -eq 2 ] && grep -qi 'could not establish' <<< "$out" && echo 0 || echo 1)" \
    "rc=$rc out=$(head -c 160 <<< "$out")"

# A remote with no hashing tool is UNVERIFIABLE. Reporting it as a mismatch would be a lie in
# the dangerous direction; reporting it as arrival would be worse.
FAKE_REMOTE="RT_NO_SHA_TOOL"
( cmd_verify --timeout 0 launch.sh ) >/dev/null 2>&1
chk "15g a remote with no sha256 tool is unverifiable (rc 2), never a mismatch or an arrival" \
    "$([ $? -eq 2 ] && echo 0 || echo 1)"

# A session that is propagating nothing cannot deliver these files, so waiting is pointless.
FAKE_REMOTE="$(_mk_remote launch.sh)"
for st in none unknown paused halted erroring; do
  ( FAKE_STATUS=$st; cmd_verify --timeout 0 launch.sh ) >/dev/null 2>&1
  chk "15h sync=$st refuses immediately (rc 2) rather than waiting for what cannot come" \
      "$([ $? -eq 2 ] && echo 0 || echo 1)"
done

# A file edited DURING the check cannot be certified: the local side moved, so the remote digest
# describes neither state. The contract is "equality was observed and held", not "these bytes
# are frozen" — nothing here can promise the second.
FAKE_STATUS=active
FAKE_REMOTE="$(_mk_remote launch.sh)"
# The call counter lives in a FILE. `cmd_verify` reads these through `$( )`, so a shell variable
# would be incremented in a subshell and every call would look like the first — which is exactly
# what happened, and made this check pass an implementation that never compared L1 against L2.
printf '0' > "$SCRATCH/ldcalls"
_local_digests() {           # returns a DIFFERENT manifest on the second call of each round
  local n; n=$(( $(cat "$SCRATCH/ldcalls") + 1 )); printf '%s' "$n" > "$SCRATCH/ldcalls"
  if [ $((n % 2)) -eq 0 ]; then printf 'deadbeef  launch.sh\n'
  else printf '%s\n' "$FAKE_REMOTE"; fi
}
out=$( cmd_verify --timeout 0 launch.sh 2>&1 ); rc=$?
chk "15i a file that changes mid-check is not certified" "$([ "$rc" = 3 ] && echo 0 || echo 1)" "rc=$rc"

# Many hosts print a banner or an MOTD on stdout. It must not be mistaken for a digest. The
# comparison is whole-manifest equality, so extra output can only make the sides UNEQUAL — a
# false negative, in the safe direction. Pinned so a future "be tolerant of leading noise"
# change has to argue with a check rather than slip past one.
# Re-source to get the REAL `_local_digests` back. `unset -f` would not do it: the stub above
# replaced rt's own definition rather than shadowing it, so unsetting leaves nothing behind and
# the check fails with "command not found" — fail-safe, but not the path being tested.
set +e; source "$RT" 2>/dev/null; set +e
RT_PROFILE="h/p"; _init_profile
REMOTE_HOST="stub-host"; REMOTE_DIR="/remote/proj"; LOCAL_DIR="$SCRATCH/vlocal"
info() { :; }; warn() { :; }; load_config() { :; }
_sync_status() { echo active; }
_sync_live_ignores() { printf 'outputs/\n*.pyc\nCLAUDE.md\n'; }
_ssh() { printf '%s\n' "$FAKE_REMOTE"; return 0; }
FAKE_REMOTE="Welcome to the cluster
Last login: never
$(_local_digests launch.sh)"
out=$( cmd_verify --timeout 0 launch.sh 2>&1 ); rc=$?
chk "15j a login banner on the remote's stdout does not read as an arrival" \
    "$([ "$rc" -eq 3 ] && echo 0 || echo 1)" "rc=$rc out=$(head -c 200 <<< "$out")"

# ── 16. findings from the independent review of THIS session's work ──────────
#
# Every check below exists because a de-correlated reader attacked the code I had just written
# and the suite I had just written to score it. None of these were caught by 122 green checks.
set +e; source "$RT" 2>/dev/null; set +e
RT_PROFILE="h/p"; _init_profile
REMOTE_HOST="stub-host"; REMOTE_DIR="/remote/proj"; LOCAL_DIR="$SCRATCH/vlocal"
info() { :; }; warn() { :; }; load_config() { :; }
_sync_status() { echo active; }
_sync_live_ignores() { printf 'outputs/\n'; }

# (a) A failed evidence-producing command cannot certify, whatever it printed. A forced-command
# wrapper or a dying transport can emit a COMPLETE, MATCHING manifest and still exit non-zero.
_ssh() { printf '%s\n' "$FAKE_REMOTE"; return "${FAKE_SSH_RC:-0}"; }
FAKE_REMOTE="$(_local_digests launch.sh)"; FAKE_SSH_RC=255
( cmd_verify --timeout 0 launch.sh ) >/dev/null 2>&1
chk "16 verify does NOT report ARRIVED when the remote command exited non-zero" \
    "$([ $? -eq 2 ] && echo 0 || echo 1)"
FAKE_SSH_RC=0
( cmd_verify --timeout 0 launch.sh ) >/dev/null 2>&1
chk "16b ... and still reports ARRIVED when it exited 0" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# (b) `--timeout` must be a real bound. Sleeping a full interval AFTER checking the deadline made
# `--timeout 1 --interval 5` take 5 seconds.
FAKE_REMOTE="MISSING  launch.sh"
t0=$(date +%s); ( cmd_verify --timeout 1 --interval 5 launch.sh ) >/dev/null 2>&1; t1=$(date +%s)
chk "16c --timeout bounds the wait even when --interval is larger" \
    "$([ $((t1-t0)) -le 3 ] && echo 0 || echo 1)" "took $((t1-t0))s for a 1s timeout"

# (c) The mismatch REPORT must not itself abort. `grep` exits 1 when the remote said nothing
# about a path, and under `set -euo pipefail` that leaked rc 1 out of a 0/2/3-only contract.
FAKE_REMOTE="unrelated  other.txt"
( cmd_verify --timeout 0 launch.sh ) >/dev/null 2>&1
chk "16d a remote that mentions none of the requested paths still returns 3, not 1" \
    "$([ $? -eq 3 ] && echo 0 || echo 1)"

# (d) `..` is a path COMPONENT, not a substring: `model..yaml` is a legal filename.
printf 'x\n' > "$LOCAL_DIR/model..yaml"
FAKE_REMOTE="$(_local_digests model..yaml)"
( cmd_verify --timeout 0 model..yaml ) >/dev/null 2>&1
chk "16e a filename containing '..' is accepted; only a '..' COMPONENT is a traversal" \
    "$([ $? -eq 0 ] && echo 0 || echo 1)"
( cmd_verify --timeout 0 "sub/../launch.sh" ) >/dev/null 2>&1
chk "16f ... while a real '..' component is still refused" "$([ $? -eq 2 ] && echo 0 || echo 1)"

# (h) A symlink in ANY component, not just the last: `sub/file` where `sub` is a symlink out of
# the profile root would otherwise be certified, and it is a file neither endpoint is syncing.
mkdir -p "$SCRATCH/outside"; printf 'elsewhere\n' > "$SCRATCH/outside/f.txt"
ln -sfn "$SCRATCH/outside" "$LOCAL_DIR/viasym"
FAKE_REMOTE="$(_local_digests viasym/f.txt 2>/dev/null)"
( cmd_verify --timeout 0 viasym/f.txt ) >/dev/null 2>&1
chk "16l a symlinked INTERMEDIATE component is refused, not just a symlinked leaf" \
    "$([ $? -eq 2 ] && echo 0 || echo 1)"

# (i) A trailing slash means DIRECTORY in Mutagen, so `outputs/` must not block a regular file
# that happens to be named `outputs`.
_sync_live_ignores() { printf 'outputs/\n'; }
printf 'not a dir\n' > "$LOCAL_DIR/outputs2"
_ignored_reason "outputs2" >/dev/null 2>&1
chk "16m an unrelated name is not matched by a directory rule" "$([ $? -ne 0 ] && echo 0 || echo 1)"
_ignored_reason "outputs" >/dev/null 2>&1
chk "16n a FILE named like a directory rule is not treated as ignored" "$([ $? -ne 0 ] && echo 0 || echo 1)"
_ignored_reason "outputs/x.txt" >/dev/null 2>&1
chk "16o ... while a path UNDER that directory still is" "$([ $? -eq 0 ] && echo 0 || echo 1)"

# (j) A negation needs Mutagen's real ordering to resolve. The helper stops claiming rather than
# answering wrongly and refusing a path that would in fact sync.
_sync_live_ignores() { printf 'CLAUDE.md\n!CLAUDE.md\n'; }
_ignored_reason "CLAUDE.md" >/dev/null 2>&1
chk "16p a negation rule makes the matcher decline to claim, not guess" "$([ $? -ne 0 ] && echo 0 || echo 1)"
_sync_live_ignores() { printf 'outputs/\n'; }

# (e) The VCS enum. `*Ignore*` matched ALL THREE values, because every one of them contains the
# literal "IgnoreVCSMode" — so this line said ".git/ is ignored" even for Propagate, which means
# the opposite. A failed query said "SYNCED", also a claim.
_has_sync() { return 0; }
_ignore_patterns() { printf 'a/\n'; }
_sync_live_ignores() { printf 'a/\n'; }
for c in "IgnoreVCSModeIgnore:ignored" "IgnoreVCSModePropagate:SYNCED" "IgnoreVCSModeDefault:SYNCED" ":could not be established"; do
  v="${c%%:*}"; want="${c#*:}"
  eval "_sync_live_vcs() { printf '%s' '$v'; }"
  out="$(_sync_report_ignores 2>&1)"
  chk "16g VCS=${v:-<query failed>} reports '$want'" \
      "$(grep -qF "$want" <<< "$out" && echo 0 || echo 1)" "$(grep -i 'VCS' <<< "$out")"
done

# (f) `rt sync status` must SURVIVE printing drift. `diff` exits 1 whenever the inputs differ —
# which is always, here — and under `set -euo pipefail` that aborted the command partway
# through, on exactly the profiles it exists to diagnose. Measured live before the fix: rc 1 and
# no Mutagen dump after the drift lines.
_sync_live_vcs() { printf 'IgnoreVCSModeIgnore'; }
_ignore_patterns() { printf 'a/\nb-only-in-config/\n'; }
_sync_live_ignores() { printf 'a/\n'; }
( set -euo pipefail; _sync_report_ignores >/dev/null 2>&1; echo REACHED_END > "$SCRATCH/dr" )
chk "16h reporting drift does not abort the command that reports it" \
    "$([ -e "$SCRATCH/dr" ] && echo 0 || echo 1)"

# (g) sbatch arguments are agent-supplied and were remote SHELL SOURCE. A `;` in one of them
# built a compound command whose LAST element supplied the exit status, so a submission that
# never happened reported success.
cat > "$SCRATCH/bin/sbatch" <<'EOF'
#!/bin/sh
for a in "$@"; do printf 'SARG[%s]\n' "$a"; done
echo "Submitted batch job 1"
EOF
chmod +x "$SCRATCH/bin/sbatch"
rm -f "$SCRATCH/captured" "$SCRATCH/PWNED.sb"
# REMOTE_DIR must EXIST: the emitted command is `cd <dir> && sbatch …`, so a nonexistent dir
# short-circuits before sbatch and the check would score an empty argv as "nothing injected".
mkdir -p "$SCRATCH/proj"; REMOTE_DIR="$SCRATCH/proj"
RT_STATE_DIR="$SCRATCH/state16"; SLURM_ENABLED=1; SLURM_LOG_DIR="$SCRATCH"; SLURM_SBATCH_ARGS=""
_ssh_test() { return 0; }; _has_sync() { return 1; }
_ssh() { printf '%s' "$*" > "$SCRATCH/captured"; echo "Submitted batch job 1"; }
_slurm_submit --assume-staged run.sbatch -- "--comment=x; touch $SCRATCH/PWNED.sb" >/dev/null 2>&1
sent="$(cat "$SCRATCH/captured" 2>/dev/null)"
argv="$(cd "$SCRATCH" && PATH="$SCRATCH/bin:$PATH" sh -c "$sent" 2>/dev/null | grep '^SARG\[')"
chk "16i an sbatch arg containing ';' stays ONE argument" \
    "$(grep -qF "SARG[--comment=x; touch $SCRATCH/PWNED.sb]" <<< "$argv" && echo 0 || echo 1)" "argv='$argv'"
chk "16j ... and does not run as a second remote command" \
    "$([ ! -e "$SCRATCH/PWNED.sb" ] && echo 0 || echo 1)" "sent='$sent'"
# Ordinary flags must still reach sbatch as separate arguments.
rm -f "$SCRATCH/captured"
_slurm_submit --assume-staged run.sbatch -- --time=04:00:00 --gres=gpu:2 >/dev/null 2>&1
argv="$(cd "$SCRATCH" && PATH="$SCRATCH/bin:$PATH" sh -c "$(cat "$SCRATCH/captured")" 2>/dev/null | grep -c '^SARG\[')"
chk "16k ordinary sbatch flags still arrive as separate arguments" \
    "$([ "$argv" = "3" ] && echo 0 || echo 1)" "got $argv args (want 3: 2 flags + script)"

# ── 17. `exec` says what it delivered ────────────────────────────────────────
#
# A stream carries no statement about its own completeness. Measured 2026-08-06: a multi-file pull
# through one `exec` returned 1 of 7 files and exited 0; the caller only noticed because it
# happened to hold a manifest. The remote command now emits a TRAILER on stderr after it exits,
# and the payload is counted on the way through — so "the stream ended early" stops being
# indistinguishable from "the command had nothing more to say".
#
# `_ssh` is stubbed to RUN the wrapper locally, so what is scored is the real remote text: the
# trailer really is emitted by a shell, and the filter really has to find it.
set +e; source "$RT" 2>/dev/null; set +e
RT_PROFILE="h/p"; _init_profile
REMOTE_HOST="stub-host"; REMOTE_DIR="$SCRATCH/proj"; mkdir -p "$REMOTE_DIR"
info() { printf ':: %s\n' "$*" >&2; }
warn() { printf '!! %s\n' "$*" >&2; }
_ssh() { sh -c "$1"; }

O="$SCRATCH/o17"; E="$SCRATCH/e17"

# The trailer is emitted AFTER the command, so it is the last thing the remote shell runs — and
# the wrapper has to end with an explicit `exit`, or every exec would report printf's status.
# That is the fail-open this block exists to prevent, one level up from the one it fixes.
_exec_sync 'exit 7' >"$O" 2>"$E"; rc=$?
chk "17 a complete stream still returns the COMMAND's status, not the trailer's" \
    "$([ "$rc" = 7 ] && echo 0 || echo 1)" "rc=$rc"
# ... and the status alone does not score the SUBSHELL that makes it right. Without one, a literal
# `exit 7` terminates the remote shell before the trailer is written, the stream is then reported
# TRUNCATED — and the status is STILL 7, because the transport carried it. Found by a mutation
# run: dropping the subshell left the check above green. What distinguishes the two is silence.
chk "17a ... having said nothing, because a literal 'exit' did not outrun the trailer" \
    "$([ ! -s "$E" ] && echo 0 || echo 1)" "stderr='$(cat "$E")'"
_exec_sync 'echo hi' >"$O" 2>"$E"; rc=$?
chk "17b ... and a succeeding command still returns 0 with its output" \
    "$([ "$rc" = 0 ] && [ "$(cat "$O")" = "hi" ] && echo 0 || echo 1)" "rc=$rc out='$(cat "$O")'"

# BYTE-EXACT, and this is load-bearing rather than tidy: a live caller pipes `tar cf -` through
# `exec` into `tar xf -`, so one added byte — a newline from a line-oriented filter, an accounting
# line on the wrong stream — corrupts an archive. NUL bytes and no trailing newline, because those
# are exactly what a line-oriented implementation would silently change.
printf 'a\000b\nno-trailing-newline' > "$SCRATCH/bin17.dat"
_exec_sync "cat '$SCRATCH/bin17.dat'" >"$O" 2>"$E"
chk "17c the payload passes through byte-exact (NULs, no trailing newline)" \
    "$(cmp -s "$SCRATCH/bin17.dat" "$O" && echo 0 || echo 1)" "got $(wc -c < "$O") bytes, want $(wc -c < "$SCRATCH/bin17.dat")"

# THE REGRESSION. A stream that ends without the trailer is a PREFIX, and this is the case that
# used to exit 0 with no marker anywhere. Reverting `_exec_sync` to the old pass-through makes
# this stub's rc 0 and this check fail.
_ssh() { printf 'one-of-seven'; return 0; }
_exec_sync 'pull the seven files' >"$O" 2>"$E"; rc=$?
chk "17d a stream that ends without the trailer exits non-zero (was: 0)" \
    "$([ "$rc" = 125 ] && echo 0 || echo 1)" "rc=$rc"
chk "17e ... and says TRUNCATED, naming what did arrive" \
    "$(grep -q 'TRUNCATED' "$E" && grep -q '12 bytes' "$E" && echo 0 || echo 1)" "stderr='$(cat "$E")'"
chk "17f ... while still delivering the prefix it did receive" \
    "$([ "$(cat "$O")" = "one-of-seven" ] && echo 0 || echo 1)" "out='$(cat "$O")'"

# A transport that failed on its own already carries a status, and 125 must not replace it —
# 125 means "no outcome was established", which is a different fact from "ssh said 3".
_ssh() { printf 'x'; return 3; }
_exec_sync 'anything' >"$O" 2>"$E"; rc=$?
chk "17g a truncated stream whose transport reported a status keeps THAT status" \
    "$([ "$rc" = 3 ] && grep -q 'TRUNCATED' "$E" && echo 0 || echo 1)" "rc=$rc"

_ssh() { sh -c "$1"; }

# NEGATIVE CASE, the one that makes the check above worth having: a complete small stream must be
# silent. Without this, "always warn" would pass every check above and the warning would be
# filtered out by every caller within a week — which is what happened to a sibling warning here.
_exec_sync 'echo small' >"$O" 2>"$E"
chk "17h a complete SMALL output prints no accounting line at all" \
    "$([ ! -s "$E" ] && echo 0 || echo 1)" "stderr='$(cat "$E")'"

# Above the threshold the size is reported, because that number is the caller's only handle on a
# cut that happens further downstream than rt can see.
yes 0123456789abcdefghijklmnopqrstuvwxyz | head -c 70000 > "$SCRATCH/big17.dat"
_exec_sync "cat '$SCRATCH/big17.dat'" >"$O" 2>"$E"
chk "17i a complete LARGE output reports the byte count it delivered" \
    "$(grep -q '70000 bytes' "$E" && echo 0 || echo 1)" "stderr='$(cat "$E")'"
chk "17j ... and that count is the number of bytes that actually arrived" \
    "$([ "$(wc -c < "$O" | tr -d ' ')" = "70000" ] && echo 0 || echo 1)" "delivered $(wc -c < "$O") bytes"

# The trailer proves the COMMAND wrote everything it had. It says nothing about whether rt handed
# all of it on — and a consumer that closes early takes the tail with it while the command may
# still exit 0. Probed against this commit's own first version: `exec 'cat 400KB' | head -c 5`
# reported "81920 bytes of stdout, complete", which is the unsupported benign claim this whole
# block removes, reintroduced one layer out. rc comes through a file because a pipeline reports
# its LAST stage's status, which is the same reason the docs say not to pipe this.
#
# The payload has to be far larger than a pipe buffer, and that is the boundary this check is
# really about: at 70 KB every byte still reaches rt's stdout — the kernel buffers it and `head`
# throws it away — so "delivered, complete" is TRUE there and the loss is the consumer's, not
# rt's. Only once forwarding itself cannot finish does the claim become rt's to get wrong.
# Measured while writing this check: at 70 KB the defect does not reproduce at all.
yes 0123456789abcdefghijklmnopqrstuvwxyz | head -c 2000000 > "$SCRATCH/huge17.dat"
{ _exec_sync "cat '$SCRATCH/huge17.dat'" 2>"$E"; echo $? > "$SCRATCH/rc17"; } | head -c 5 > "$O"
rc="$(cat "$SCRATCH/rc17")"
chk "17r a consumer that closes early is reported as a PREFIX, never as complete" \
    "$([ "$rc" != 0 ] && grep -q 'did NOT deliver the whole payload' "$E" && ! grep -q 'complete' "$E" && echo 0 || echo 1)" \
    "rc=$rc stderr='$(cat "$E")'"

# The remote's own stderr must still arrive, and the trailer must not. An implementation that
# passed the trailer through would leak a token into every caller's diagnostics; one that dropped
# too much would eat the remote's last line, which is silent loss of exactly the kind of message
# a failure is announced in.
_exec_sync 'echo out-line; echo err-line >&2' >"$O" 2>"$E"
chk "17k the remote's stderr still reaches the caller" \
    "$(grep -q '^err-line$' "$E" && echo 0 || echo 1)" "stderr='$(cat "$E")'"
chk "17l ... and the trailer token is not in it" \
    "$(grep -q '__rt_exec_end' "$E" && echo 1 || echo 0)" "stderr='$(cat "$E")'"

# The filter's one hard case: a remote whose last stderr write has no newline, so the trailer is
# not a record of its own. That line must survive — losing it is the silent-loss shape above.
_exec_sync 'printf out; printf no-newline-tail >&2' >"$O" 2>"$E"; rc=$?
chk "17m a stderr line with no trailing newline survives the trailer filter" \
    "$([ "$rc" = 0 ] && grep -q '^no-newline-tail$' "$E" && echo 0 || echo 1)" "rc=$rc stderr='$(cat "$E")'"

# `_exec_reap` is why the accounting does not reinstate an unbounded wait: the readers see EOF
# only once EVERY holder of the payload pipe has closed it, and after `--timeout` kills ssh that
# can include something ssh left behind. Check 14i scores the end-to-end bound; these two score
# the reaper's own two outcomes, since a reaper that never kills and one that always kills both
# leave 14i green.
sleep 6 & slow_pid=$!
# Grouped with stderr closed: the shell announces the killed job on `wait`, and that notice is
# not this check's output.
{ t0=$(date +%s); _exec_reap 1 "$slow_pid"; rr=$?; t1=$(date +%s); wait "$slow_pid"; } 2>/dev/null
chk "17n the reaper kills a reader that outlives the grace, and returns non-zero" \
    "$([ "$rr" != 0 ] && [ $((t1-t0)) -lt 4 ] && echo 0 || echo 1)" "rc=$rr after $((t1-t0))s"
sleep 0 & fast_pid=$!
_exec_reap 3 "$fast_pid"; rr=$?
wait "$fast_pid" 2>/dev/null
chk "17o ... and returns 0 without killing one that finishes inside it" \
    "$([ "$rr" = 0 ] && echo 0 || echo 1)" "rc=$rr"

# The count is ABSENT, not 0, when it could not be taken — `wc` writes its total only at EOF, so
# a killed reader leaves no number, and reporting that as zero would be a measurement nobody made.
out17="$(_exec_account "" "" 0 0 2>&1)"; rc=$?
chk "17p an uncounted stream is reported as unestablished, not as 0 bytes" \
    "$([ "$rc" = 125 ] && grep -q 'unestablished' <<< "$out17" && ! grep -q '0 bytes' <<< "$out17" && echo 0 || echo 1)" \
    "rc=$rc out='$out17'"

# The docs have to carry the new status, or a caller branching on `rt exec` has no way to learn it.
DOCS_DIR="$(dirname "$HERE")"
chk "17q the 125 status is documented where exec's exit codes are" \
    "$(grep -q '125' "$DOCS_DIR/SKILL.md" && grep -q '125' "$DOCS_DIR/README.md" && grep -q '125' "$RT" && echo 0 || echo 1)"

echo "────────────────────────────────────────────"
if [ "$FAIL" = 0 ]; then echo "rt canaries: ${PASS}/${PASS} pass"; exit 0; fi
echo "rt canaries: ${PASS} pass, ${FAIL} FAIL"; exit 1
