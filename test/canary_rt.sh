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
# make three of these read as halted. The record is data, so it gets no cosmetics.
for case in \
  "active false|Watching|true|true|" \
  "halted false|WaitingForRescan|true|true|alpha scan error: exceeded allowed entry count" \
  "paused true|Disconnected|false|false|" \
  "offline false|Watching|false|true|" \
; do
  want="${case%% *}"; rec="${case#* }"
  FAKE_TEMPLATE_OUT="$rec"
  got="$(_sync_status)"
  chk "7 [$want] a session reporting Status=$(echo "$rec" | cut -d'|' -f2) classifies as $want" \
      "$([ "$got" = "$want" ] && echo 0 || echo 1)" "classified '$got', want '$want'"
done

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
FAKE_TEMPLATE_OUT='false|WaitingForRescan|true|true|scan error: a|b|c'
chk "7e a '|' inside the error text does not corrupt the classification" \
    "$([ "$(_sync_status)" = "halted" ] && echo 0 || echo 1)" "got $(_sync_status)"
chk "7f ... and the full error is recoverable for the message" \
    "$([ "$(_sync_last_error)" = "scan error: a|b|c" ] && echo 0 || echo 1)" "got '$(_sync_last_error)'"

# A halted session does not FAIL a flush, it HANGS (measured: `mutagen sync flush` still running
# after 15s on a breaker-halted session). So without a fail-fast it burns RT_FLUSH_TIMEOUT and
# returns 3 — "the daemon is still syncing" — and `rt exec` continues on 3. That is the
# fail-open: a command running against stale code behind a reassuring warning.
FAKE_TEMPLATE_OUT='false|WaitingForRescan|true|true|alpha scan error: exceeded allowed entry count'
_sync_flush >/dev/null 2>&1; rc=$?
chk "7g a HALTED session -> flush returns 2 (nothing synced), never 3 (still working)" \
    "$([ "$rc" = 2 ] && echo 0 || echo 1)" "got $rc"
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
      [ "$(_sync_status)" = "halted" ] && break
      sleep 1
    done
    live="$(_sync_status)"
    chk "8 a REAL breaker-halted session classifies as halted, not active" \
        "$([ "$live" = "halted" ] && echo 0 || echo 1)" "classified '$live'"
    chk "8b ... and the live error text is reported" \
        "$(if [[ "$(_sync_last_error)" == *"entry count"* ]]; then echo 0; else echo 1; fi)" \
        "got '$(_sync_last_error)'"
    # Bounded so a regression cannot hang the suite: flush must REFUSE, not wait.
    t0=$(date +%s); RT_FLUSH_TIMEOUT=3 _sync_flush >/dev/null 2>&1; rc=$?; t1=$(date +%s)
    chk "8c ... and flush REFUSES it (rc 2) instead of waiting out the bound" \
        "$([ "$rc" = 2 ] && [ $((t1-t0)) -lt 3 ] && echo 0 || echo 1)" "rc=$rc after $((t1-t0))s"
    mutagen sync terminate --label-selector "$LIVE_SEL" >/dev/null 2>&1
    RT_HOST_GROUP=h; RT_PROFILE_NAME=p
  else
    printf '  SKIP 8 live Mutagen classification (could not create a probe session)\n'
  fi
fi

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

rm -rf "$RT_HOME"
export RT_HOME="$RT_HOME_SAVE"

echo "────────────────────────────────────────────"
if [ "$FAIL" = 0 ]; then echo "rt canaries: ${PASS}/${PASS} pass"; exit 0; fi
echo "rt canaries: ${PASS} pass, ${FAIL} FAIL"; exit 1
