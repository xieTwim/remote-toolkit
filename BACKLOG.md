# remote-toolkit — BACKLOG

One entry per ROOT CAUSE. Protocol: research-loop `commands/CAPABILITIES.md` § ISSUES protocol.
Grep before adding (`+1 <project> <date>` on a hit); closes in the fix's own commit, replaced by a
`- [fixed <commit>]` tombstone.

**Sanitized text only.** Host names, profile names, cluster paths and account names stay in the
reporting project's own `ISSUES.md`.

Seeded 2026-08-01 from the second migration lane.

Extended 2026-08-02 by this tool's FIRST audit — a de-correlated read of `rt`, `SKILL.md`,
`CLAUDE.md` and `README.md` against three questions (*where is a state reported without being
established* · *where can data be lost* · *which documented claims are enforced nowhere*), with
every finding reproduced against real Mutagen 0.18.1 on local-only endpoints or a stubbed SSH.
The entries below are that audit's, not a project's; each says whether it was CONFIRMED offline
or still needs a live host.

**The lane has one shape.** `rt`'s callers are usually AGENTS, and almost every path that could
say "I could not establish this" instead returns 0. A human notices an odd line; a bash guard
branching on `$?` does not.

---

- [open] 2026-08-01 dllm-reasoning: nothing tells a caller when a staged file has actually ARRIVED, so callers wait a fixed sleep and then install a stale copy. Measured: a patched launcher script was staged, waited on for ten seconds, and the still-stale remote copy was copied into place — `bash -n` passed because the OLD file is valid shell, so the run started and died instantly on an unknown case, holding 8 GPUs idle for ~25 minutes
  repro: stage a small edit, sleep a fixed interval, read the remote copy
  fix shape: an arrival assertion — content equality (a digest comparison) against the local file, exposed as something a caller can wait on, rather than a flush whose completion does not imply arrival. This is the general defect: the sync layer is being used as a job-control protocol, and a fixed sleep is what callers reach for when the layer offers no ack
**[RULED 2026-08-05, human, decisions §5.3] THE ARRIVAL ASSERTION ONLY**, as this entry actually asks for it: hash the launch set locally, require the remote to echo the same digest, and expose it as something a caller can wait on. **The per-run staging wrapper is a SEPARATE project, to be authorised later — explicitly not in this sweep.** Session 21 had wrongly imported that larger design into this entry and the triage audit caught it. The wrapper is register §3.3. Now actionable as scoped.

- [open] 2026-08-01 reason-select: a courier bucket degrades silently as finished handoffs accumulate, and the tool's only lever makes it worse. Measured: 10,292 files / 2.6 GB in the tree put a flush in `Scanning files` for 20+ minutes — a 9 KB push took ~40 minutes and a 2.7 MB pull had not arrived after 25 — while the same bucket at 232 files / 41 MB flushes in 7 seconds. Everything in it was FINISHED pulls nobody cleared
  repro: let a sync bucket accumulate completed handoffs; measure flush latency against file count
  fix shape: warn on file count / tree size at flush time, before latency becomes the symptom. The standing lesson is that **a courier bucket needs PRUNING, not a growing ignore list — a growing ignore list is the tell that the bucket is being used as storage**; note also that ignores only apply at session-create time, so adding one does not take effect until the session is recreated, which is itself worth surfacing

- [open] 2026-08-01 grpo-speed: bounded reads through `exec` fail on macOS with "command not found: timeout" — the GNU binary is not present on darwin, and the wrapper assumes it
  repro: any `rt … exec` path that bounds a remote read with `timeout`
  fix shape: detect and use `gtimeout` where present, or implement the bound in the wrapper rather than in the remote shell; failing that, say so where the bounded-read path is documented

## From the 2026-08-02 first audit

- [fixed remote-toolkit@b9e35f8] 2026-08-02 a background job's recorded exit status was `tee`'s, not the command's. `{ cmd; } 2>&1 | tee log; echo "EXIT_CODE=$?"` records the LAST element of the pipeline, and `tee` essentially always succeeds — so every job that ever started was recorded `EXIT_CODE=0` and listed by `rt logs` as `[DONE]`, including one that died on its first line. A caller reading that list to decide whether a run finished was told yes, always. Fixed with a POSIX marker file (`${PIPESTATUS[0]}` is bash-only and tmux starts the remote LOGIN shell, so on a dash host it would expand to nothing — the same class of silent failure). The command runs in an explicit subshell so that a literal `exit N` cannot terminate the pipeline's own subshell before the marker is written. `rt` got its first tests with this: `test/canary_rt.sh` sources `rt`, stubs `_ssh`, and RUNS the captured remote command locally, so the four failure shapes are pinned by behaviour rather than by wording

- [fixed remote-toolkit@4a4b376] 2026-08-02 a failed flush was converted into a successful CLI call — and the reason the tool held two OPPOSITE policies for it (`exec` ran anyway, `slurm submit` aborted) is that "flush failed" was one word for two states. `_sync_flush` now returns 2 (paused / mutagen error — nothing synchronised) or 3 (the time bound elapsed; the daemon is still working). `exec` refuses on 2 and continues loudly on 3, because refusing on a routine timeout would make `--no-flush` habitual and turn the protection off entirely; `slurm submit` refuses on both, since a queued job outlives the shell; `sync flush` exits non-zero. **Human ruling 2026-08-02** — the two states had to be separated before any single policy could be right

- [open] 2026-08-02 audit: **"flushed" does not mean the endpoints are equal, and nothing in `rt` establishes that they are.** Mutagen's flush forces a synchronization CYCLE; it does not prove byte-for-byte equality. CONFIRMED with the real engine: `two-way-safe` with an unresolved conflict, and an ignored path, both flush with exit 0 while the endpoints differ. This is the root cause under the 2026-08-01 arrival-assertion entry above, and the general form of it
  repro: create a conflict under `two-way-safe`, flush, compare endpoint hashes
  fix shape: an arrival assertion the caller can wait on — hash the launch set locally, require the remote to echo the same digest — rather than treating a returned flush as a barrier. See the design note at the bottom of this section

- [open] 2026-08-02 audit: **an unhealthy sync session is classified `active`.** The parser treats anything carrying `Identifier:` that is not recognised as paused and does not match `Connected: No` as active. CONFIRMED with real Mutagen 0.18.1: an entry-count breaker halt reports `Last error: … exceeded allowed entry count` / `Status: Waiting 5 seconds for rescan` and classifies as `active` — a halted session reported as healthy. `rt connect` resumes only the exact `paused` classification, so the documented "connect resumes it" recovery does not fire for this case, which is the case that actually happens
  repro: create a session with `--max-entry-count=1`; read the classification
  fix shape: classify on `Last error:` and on the status verb, not on the absence of two strings; and either resume or say plainly that it cannot

- [open] 2026-08-02 audit: **`disconnect` reports success when termination failed, and deletes the local record either way.** `mutagen sync terminate … || true` discards every failure, then the state directory (including `slurm_jobs`) is removed and `Disconnected` is printed. The session may still be running and propagating deletions with its local tracking gone. CONFIRMED with a stubbed terminate failure
  repro: stub `mutagen sync terminate` to fail; observe `state_cleared=yes`, `Disconnected`, rc 0

- [fixed remote-toolkit@4a4b376] 2026-08-02 `disconnect` killed every background job while its own documentation said it preserved work — two intentions under one name, with no flush before or after, so a running job was interrupted and its last output could never reach local. Default is now the documented behaviour and it SAYS how many it leaves running; `--kill-jobs` is the deliberate form and flushes first. `clear_state` also stopped deleting the Slurm submission history, which is the only local record of what was queued and has nothing to do with whether a sync session exists. **Human ruling 2026-08-02**: separate the two intentions, default to the safe one

- [open] 2026-08-02 audit: **agent-supplied values reach the remote shell unquoted.** `slurm cancel` interpolates its arguments straight into `scancel $*`, so `rt slurm cancel "123; <command>"` constructs a remote compound command; `--name` and a log ID likewise enter unquoted positions, and a `REMOTE_DIR` or script path containing an apostrophe breaks the ad-hoc single quoting. CONFIRMED by constructing the strings; not executed against a host. The boundary that matters is agent/user-supplied ids and names — config files are sourced bash and are already trusted
  fix shape: validate ids against `^[0-9_]+$`-shaped patterns at the boundary, and quote every interpolation; a job id is never a shell fragment

- [open] 2026-08-02 audit: **`status --all` enumerates state directories, not configured profiles**, so a configured-but-disconnected profile is invisible — exactly when you would run it to find out what exists. CONFIRMED on this machine: 11 profile config files, 4 shown. The `remote` SKILL's first instruction is to run this command to enumerate profiles, so the one documented use is the one it does not serve
  fix shape: walk `*.conf`, and mark each as connected / configured-only

- [open] 2026-08-02 audit: **documented sync scope is materially wider than the implementation.** The defaults ignore `outputs/`, `checkpoints/`, `wandb/` and others; the docs say files sync to and from the remote and never enumerate the exclusions. A result written to any of those directories never becomes part of the local replica, and ignores apply only at session-CREATE time, so editing the list does nothing to a live session. CONFIRMED with the real engine
  fix shape: enumerate the default ignore set in the docs, and have `status` print the live session's effective ignore list rather than the profile's current text

### The design note this lane produced

The standing claim in the harness register — *"Mutagen is being used as a job-control protocol:
eventual bidirectional sync decides which code a GPU job launches and which result is
authoritative"* — was put to the de-correlated reader as a question, and came back **TRUE with one
qualification**: ignored result paths are remote-only rather than bidirectionally authoritative,
and under the default mode the LOCAL side wins every conflict, so a local edit can overwrite a
remote result regardless of which was written later.

Its recommended smallest incision, recorded here rather than acted on: a per-run staging wrapper
around `exec --bg` and `slurm submit` — copy a deterministic input snapshot to a unique remote run
directory, verify its manifest digest, launch THERE, write outputs there, and fetch them with a
verified manifest. Mutagen stays a browsing convenience and stops being the correctness boundary.
That is a design change to a shared tool and belongs to a human.
