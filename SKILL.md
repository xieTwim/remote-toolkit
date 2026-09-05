---
name: remote
description: Remote Toolkit — drives remote servers via Mutagen file sync + SSH through the `rt` CLI; multi-server profiles, Slurm submission/monitoring on HPC hosts, tmux-backed background commands. Trigger on any mention of a remote server, SSH target, HPC cluster, GPU box, `rt`, file sync to/from a remote machine, Slurm jobs (submit/queue/logs/cancel), `.sbatch` files, profile setup, or running/moving/deploying something on a remote — even without the words "rt"/"remote toolkit". On the first triggering prompt run `rt status --all` to enumerate profiles before assuming one.
---

# Remote Toolkit — Full Guide for Claude Code

Drive remote servers via the `rt` command. Files sync via Mutagen; commands run via SSH/tmux; HPC clusters get optional Slurm subcommands.

Config directory: `~/.config/remote-toolkit/`

**First action when this skill triggers:** run `rt status --all` to see which profiles are configured. If multiple profiles exist and the user's intent doesn't pin down a target, ask which to use before doing anything else. Never sudo-install dependencies — surface missing tools to the user instead.

## Prerequisites

**Important:** These tools require admin rights. You (Claude Code) cannot install them — ask the user.

Run `rt check` to verify dependencies. If anything is missing, **stop and tell the user**:

Linux (Debian/Ubuntu):
```
sudo apt install -y tmux sshpass
# Mutagen: see https://mutagen.io/documentation/introduction/installation
```

macOS (requires Homebrew):
```
brew install mutagen-io/mutagen/mutagen
brew install tmux
brew install esolitos/ipa/sshpass
```

After install, run `rt check` again.

## First-Time Server Connection

When the user provides server info (e.g., `ssh user@host -p PORT`, password `xxx`):

### 1. Check dependencies
```bash
rt check
```

### 2. Create config

Profiles are namespaced under host groups: `<host-group>/<profile>` (e.g., `fact-cluster/scratch`). Each host group has one shared `host.conf` (login info) plus one `<profile>.conf` per workspace.

Layout under `~/.config/remote-toolkit/`:
```
fact-cluster/
  host.conf       Host-level (REMOTE_HOST, SSH_PORT, SLURM_ENABLED)
  scratch.conf    Profile-level (REMOTE_DIR, optional LOCAL_DIR)
  ako.conf        Another profile under the same host
```

Use Write to create them. Example for a new HPC host:

`~/.config/remote-toolkit/fact-cluster/host.conf`:
```
REMOTE_HOST="user@login.cluster"
SSH_PORT=22
SLURM_ENABLED=1
```

`~/.config/remote-toolkit/fact-cluster/scratch.conf`:
```
REMOTE_DIR="/home/user/scratch"
# LOCAL_DIR defaults to ~/Work/Remote/fact-cluster/scratch — override only if needed
```

Profile names must be in `<host>/<profile>` form (no bare-name fallback). Each segment is alphanumeric with single dashes between alphanumerics (no leading/trailing dash, no `--`, no `_` or `.`), max 32 chars — keeps the name unambiguous when `--` separates segments in the Mutagen session name and `_` separates them in tmux session names.

#### One host, several storage backends

A host group is a *login*, not a filesystem. If the same host mounts more than one storage backend (two network filesystems, a fast scratch tier plus bulk storage, two regions of the same cluster), give each backend **its own profile** — one profile is one `REMOTE_DIR`, and that is the whole mechanism. Suggested naming: `<project>` for the default backend and `<project>-<backend>` for the other, e.g.

```
wxg-cvm/myproj        REMOTE_DIR="/mnt/fsA/user/myproj"
wxg-cvm/myproj-alt    REMOTE_DIR="/mnt/fsB/user/myproj"
```

Two non-obvious rules when a project moves between backends:

- **Editing `REMOTE_DIR` does NOT retarget a live profile.** `connect` is idempotent: it finds the existing session and resumes/flushes it, so the edit silently has no effect and you keep syncing to the old root. Moving = create the new profile, verify it round-trips, then retire the old one (`disconnect`, archive its `.conf`). This also makes the move reversible.
- **Never point two profiles at one `LOCAL_DIR`.** `LOCAL_DIR` is derived from the profile name, so distinct names are safe automatically — do not override it to "share" one replica between two backends. Two sessions reconciling the same directory will fight, and a delete on one side propagates through both.

Which backend a project belongs on is a data-locality question, not a tidiness one: measure it. Bulk sequential reads are what differ between backends; small-file/metadata work often does not. If a run reads only a few hundred MB, moving it buys nothing.

For non-default SSH_PORT or SSH_KEY, **also add a Host entry to `~/.ssh/config`** so Mutagen finds the right SSH parameters (Mutagen reads ssh config, not host.conf):
```
Host login.cluster
    Port 2222
    IdentityFile ~/.ssh/cluster_key
```

### 3. Push SSH key (one-time)
```bash
rt -p fact-cluster/scratch setup-key --password 'password'
```
(Once pushed for one profile in a host group, all profiles in that group share the key.)

### 4. Connect
```bash
rt -p fact-cluster/scratch connect
```

`connect` starts the Mutagen daemon (if needed) and creates a sync session named `rt-<host>--<profile>` (e.g., `rt-fact-cluster--scratch`). Initial scan happens in the background; `rt status` shows progress.

## Daily Usage

### Connection Management

```bash
rt status              # Sync + SSH state for current profile
rt status --all        # All profiles
rt connect             # Idempotent — resumes if paused, flushes if already connected
rt disconnect          # Terminates sync; preserves local files AND leaves background jobs running
rt disconnect --kill-jobs   # ... and stop them too (flushes first, so their output comes back)
```

### File Operations

The local replica directory defaults to `~/Work/Remote/<host>/<profile>/` (override via `LOCAL_DIR` in the profile config). Above that, host-group dirs `~/Work/Remote/<host>/` may carry a git-tracked `CLAUDE.md` and shared `templates/` (selectively un-ignored in `.gitignore`).

These are **regular local directories**, not network mounts. Read / Edit / Write at full local-disk speed:
- `Read ~/Work/Remote/fact-cluster/scratch/src/main.py`
- `Edit ~/Work/Remote/fact-cluster/ako/train.py`

Mutagen syncs changes to and from the remote in the background (typically < 1s for small files). Use `rt sync flush` to force reconciliation; `rt sync status` for diagnostics.

#### Before you launch anything from a file you just edited: `rt verify`

**A returned flush does NOT mean the two sides are equal, and nothing about a flush ever claimed it did.** `mutagen sync flush` forces a synchronization *cycle*; it does not compare content. Confirmed against the real engine: a session with an unresolved conflict, and a path under an ignore rule, **both flush with exit 0 while the endpoints differ**. `rt sync flush` returning 0 therefore means "a cycle completed", not "the remote has your file".

This is not academic. A patched launcher was staged, waited on with a fixed `sleep 10`, and the still-stale remote copy was copied into place; `bash -n` passed because the *old* file is also valid shell, so the run started, died instantly on an unknown case, and held 8 GPUs idle for ~25 minutes.

`rt verify` is the assertion that a flush is not:

```bash
rt -p wxg-cvm/train verify train.py configs/run.yaml     # waits (default 60s) until they match
rt -p wxg-cvm/train verify --timeout 5 --interval 1 launch.sh
```

It hashes each path locally, has the remote hash the same paths, and compares — including recomputing the local side afterwards, so a file edited mid-check is not certified. Exit codes mirror the flush codes:

| rc | meaning |
|---|---|
| 0 | equality **observed**, and stable across the check |
| 2 | **blocked or unverifiable** — bad/absent/ignored path, a symlink or directory, no sync session, sync not propagating, or no sha256 tool on either side. Waiting cannot help. |
| 3 | the deadline elapsed and the sides still differ. **Non-arrival — not evidence that sync is still working on it.** |

Rules it enforces, each because the alternative is a false "arrived":
- Paths are **relative to the profile root**, regular files only. Directories and symlinks are refused rather than guessed at.
- A path matching the **live session's ignore rules** is refused immediately: it can never arrive by syncing, so waiting for it waits forever. The matcher covers the pattern shapes `rt` itself generates — `dir/`, `*.ext`, and a bare name — not Mutagen's full grammar, so a **non-match claims nothing** (an unexplained difference is reported as "not equal by the deadline", never as "still converging"), and it **declines to answer at all** if the live rules contain a negation (`!pattern`), whose resolution needs Mutagen's real ordering. It also does not know about root-relative patterns or the separate VCS-ignore setting, so `.git/config` is not recognised as blocked.
- A path is refused if **any component** of it passes through a symlink, not just the last one — an intermediate symlink can leave the profile root entirely, and certifying a file neither endpoint syncs is worse than refusing to answer.
- A missing hashing tool is **unverifiable**, never a mismatch and never an arrival.

Use it before `cp`-ing a staged file into place, before `rt slurm submit`, and before any `exec --bg` that launches code you just edited.

#### What does NOT sync — read this before looking for a result that never arrived

**Sync is not the whole directory.** Every profile is created with this default ignore set, and a file under any of these paths never becomes part of the local replica in either direction:

```
__pycache__/  *.pyc  .venv/  venv/  node_modules/
wandb/  outputs/  checkpoints/  .ipynb_checkpoints/
.triton_cache/  .DS_Store  *.swp
.claude/  CLAUDE.md  HANDOFF.md  HINTS.md  ITERATIONS.md  .local/  *.local.md
```

Plus `.git/` when `MUTAGEN_IGNORE_VCS=1` (the default), plus whatever the profile adds in `MUTAGEN_IGNORE`.

Three consequences that have each cost time:

1. **A training run writing to `outputs/` or `checkpoints/` produces nothing locally.** That is by design — those are large — but it means the local replica is *not* a copy of the remote, and "it did not sync" is usually "it was never in scope". Write results you want back to a path outside the ignore set, or fetch them explicitly with `rt exec 'cat …'`.
2. **Ignores are frozen when the session is created.** Editing `MUTAGEN_IGNORE` does nothing to a running session. You must `rt disconnect && rt connect` to apply it. `rt sync status` prints the **live** session's effective ignores and warns when they no longer match what the config would create — trust that output, not the config file.
3. **A growing ignore list is a smell.** It usually means a sync bucket is being used as storage. Prune the bucket instead; see rule 4 below.

### Remote Command Execution

Short commands (< 30 seconds) — auto-flushes sync first:
```bash
rt -p fact-cluster/scratch exec "pwd"
rt -p fact-cluster/scratch exec "nvidia-smi"
rt -p fact-cluster/scratch exec --no-flush "ls"          # skip flush for fast iteration
rt -p fact-cluster/scratch exec --timeout 30 "cat big.log"   # bound the wait
```

**To bound a read, use `--timeout`, never `timeout(1)`.** macOS has no `timeout` — it is `gtimeout`, from coreutils, and usually not installed — so `timeout 30 rt … exec …` dies with `command not found: timeout` **without running the command at all**. Written as `timeout 30 rt … exec … | head -3` it is worse: the pipeline still exits 0 because `head` succeeded, so a read that never happened is indistinguishable from a successful read that returned nothing. `rt exec --timeout SECS` implements the bound inside `rt` in pure Bash, needs no GNU binary, and exits **124** (timeout(1)'s conventional code) when it elapses.

The bound is on the **wait**, not on the work: `rt` kills the local `ssh`, which does not reliably kill the remote process. It says so when it fires. If you need the remote side to stop too, run it with `--bg` and kill the tmux session.

**A large `exec` payload can be cut, and `rt` now says so — but only about the half it can see.** A stream carries no statement about its own completeness: measured 2026-08-06, a multi-file pull through a single `exec` returned 1 of 7 files and exited 0, and the caller noticed only because it happened to hold a manifest of what it had asked for. Two things now make that checkable:

- The remote command is followed by a **trailer** the remote shell writes after it exits. If the stream ends without it, `exec` prints `output is TRUNCATED` and exits **125** — "no outcome established", beside the 124 already used for the bound. A real transport status is never replaced by 125; a genuine `ssh` failure keeps its own.
- A complete payload at or above **64 KiB** reports its size (`exec delivered N bytes of stdout, complete`). Below that, nothing is printed and the call behaves exactly as before. Tune with `RT_EXEC_REPORT_BYTES`.

**That size line is the part you have to act on.** `rt` does not cap the payload and neither does `ssh`, so a cut at ~100 KB happens in whatever *captures* rt's stdout — an agent's tool-output limit, a harness buffer — which `rt` cannot detect and cannot prevent. Compare the reported number against what you actually hold. And note that piping `rt exec` into anything discards `rt`'s exit status entirely — the pipeline reports the last command's — so a `TRUNCATED` exit is invisible to `rt … exec 'cat f' | grep …`.

## Moving a payload: `rt fetch` and `rt push`, never a pipe

**For anything you would be upset to receive half of, do not use `exec` at all.** Use these:

```bash
rt -p host/proj fetch runs.tar 'cd /data/runs && tar cf - *.csv'   # generated payload
rt -p host/proj fetch one.csv  'cat /data/runs/one.csv'            # an existing file
rt -p host/proj push ./patched.py scripts/patched.py               # local -> remote
```

The remote stages the payload, digests it **there**, streams it, and reports the digest in the
trailer; `rt` digests what actually arrived and renames into place **only on a match**. So a cut
anywhere — remote, transport, or rt's own stdout — is a digest mismatch, and the destination is
never a partial file. `push` is the same discipline in the other direction and exists because
`base64 < local | rt exec 'base64 -d > remote'` delivered an **empty** stdin stream 2 of 3 times:
`base64 -d` succeeded on zero bytes, a 0-byte script "deployed" cleanly, and a GPU evaluation was
consumed running `python3 <empty file>` at rc=0.

| exit | meaning |
|---|---|
| **0** | delivered and verified; the digest is printed |
| **2** | **unverifiable** — no `sha256sum`/`shasum` on one side. Not a mismatch; investigate the host |
| **3** | **digest mismatch** — the payload was cut or altered. Investigate the transfer |
| **124** | the `--timeout` bound fired |
| **125** | no outcome established — the stream ended before the remote reported finishing |
| other | the remote command's own status |

**On every non-zero path the destination is not written and the incoming file is removed**, so a
partial payload can never be picked up later by a glob and read as an artifact. A payload from a
command that exited non-zero is not installed either, whatever its digest says.

Two bounds worth knowing: the payload is staged on the **remote**, so it needs free space there
for one copy — that is the price of digesting before sending, which is the only ordering in which
the digest describes what the remote meant to send. And `fetch`'s destination temp is a **sibling**
of the destination, so the final rename stays within one filesystem.

`exec`'s 125 stays as a diagnostic for callers that have not migrated.

Long commands (builds, training daemons, services):
```bash
rt -p fact-cluster/scratch exec --bg --name build "make all"
rt -p fact-cluster/ako exec --bg --name train "python3 train.py"
```

`--bg` VERIFIES the session before reporting it: after `tmux new-session` it checks that the
session exists or its log does, and exits non-zero naming the job when neither is there. A
"Background job started" line is now a claim the tool checked. The failure it catches is a
payload body carrying nested quotes — the remote shell rejects it, nothing launches — and the
answer is to stage the body as a script and background that.

Check background tasks:
```bash
rt -p fact-cluster/scratch logs                                   # list bg jobs for this profile
rt -p fact-cluster/ako logs rt_fact-cluster_ako_bg_train          # show specific output
rt -p fact-cluster/ako logs rt_fact-cluster_ako_bg_train -f       # follow (tail -f)
```

The working directory for `rt exec` is `REMOTE_DIR`, which mirrors the local `~/Work/Remote/<host>/<profile>/` replica.

## Slurm (HPC) Workflows

Available when `SLURM_ENABLED=1` is set in `host.conf` or the profile config. Sync flush is automatic before submit.

`SLURM_SBATCH_ARGS` (host.conf for cluster-wide policy, profile config to override) injects standing sbatch args before every submit — e.g. fact-cluster carries `"--no-requeue --exclude=ultimate-law,einstein"`. The submit line echoes the merged args, and explicit `-- ...` args come after the defaults, so they override (sbatch last-wins).

```bash
rt -p fact-cluster/scratch slurm submit train.sbatch                       # cd && sbatch train.sbatch
rt -p fact-cluster/scratch slurm submit train.sbatch -- --time=04:00:00    # extra args after `--`
rt -p fact-cluster/scratch slurm queue                                      # squeue -u $USER
rt -p fact-cluster/scratch slurm queue --all                                # squeue (whole cluster)
rt -p fact-cluster/scratch slurm logs                                       # list recent submissions
rt -p fact-cluster/scratch slurm logs 12345                                 # cat slurm-12345.out
rt -p fact-cluster/scratch slurm logs 12345 -f                              # tail -f
rt -p fact-cluster/scratch slurm logs 12345 --err                           # show .err instead
rt -p fact-cluster/scratch slurm cancel 12345                               # scancel 12345
```

`rt` does not generate sbatch scripts — write your own `*.sbatch` under the profile's local replica and submit by path.

## Important Rules

1. **No interactive commands** — vim, less, top, python REPL won't work. Use non-interactive alternatives (`python3 -c "..."`, `head`, `cat`).

2. **Long-running commands** — use `rt exec --bg` (any host) or `rt slurm submit` (Slurm hosts). SSH timeouts will kill foreground commands over a few minutes. **A stop from your side — Ctrl-C, a task stop, a closed terminal — kills only the local `ssh`; the remote command keeps running as an orphan.** `rt exec` says so at that moment (exit 128+signal, output marked as a PREFIX) and has no kill plumbing by design (ruled 2026-09-05): anything you may need to stop goes through `--bg`, where `rt logs` names the tmux session to kill; otherwise `pgrep`/`kill` it on the host.

3. **A failed flush is two different states, and the callers differ on purpose.** `_sync_flush` returns **2** (paused session or a mutagen error — *nothing* was synchronised) or **3** (the `RT_FLUSH_TIMEOUT` bound elapsed; the daemon keeps syncing). `rt exec` REFUSES on 2 and continues with a warning on 3 — refusing on a routine timeout would just make `--no-flush` habitual. `rt slurm submit` refuses on BOTH, because a queued job outlives the shell that queued it, and it also refuses when there is **no sync session at all** (`--assume-staged` if the script was placed there by other means). `rt sync flush` exits non-zero when it could not flush.

4. **Sync timing & the flush wedge** — Mutagen syncs in the background. `rt exec` (and `slurm submit`) auto-flush FIRST so the remote sees the latest edits. That flush is **bounded by `RT_FLUSH_TIMEOUT` (default 10s)**: without the cap, a large or backlogged sync blocks until a full cycle completes, which **wedges every command — even `echo` hangs for minutes**. If exec is slow or wedging:
   - `--no-flush` skips the flush entirely (fast, but beware stale code).
   - The real cause is usually a **bloated sync set** — a heavy dir missing from the profile's `MUTAGEN_IGNORE`. Check `mutagen sync list`; a multi-GB or many-thousand-file working set is the tell. Add the dir to `MUTAGEN_IGNORE` and recreate the session (`rt disconnect && rt connect` — ignores only apply at create time).
   - **The wedge is cross-project.** All profiles share ONE Mutagen daemon (and, per host, one mount), so a runaway sync in *one* profile stalls *every* profile's flush, not just its own. `rt` now caps each session with `--max-entry-count` (default 50000, override `MUTAGEN_MAX_ENTRY_COUNT`, empty disables) so a runaway **halts itself** instead of taking the daemon down — a *halted* session with a huge entry count in `mutagen sync list` is the tell; fix its `MUTAGEN_IGNORE` and recreate. The cap backstops ignore hygiene, it doesn't replace it (on ceph-fuse even a few-thousand-file dir hurts below the cap).
   - **Bridging a source TREE to the remote: send one archive, not the tree.** A shared `scratch` profile is usually already a few thousand entries, so dropping a repo working copy into it trips the breaker and halts the session for every user of that profile — the entries are legitimate, so there is no `MUTAGEN_IGNORE` fix. `tar -czf` it, copy the single file into the replica, and extract on the remote **outside** the synced directory. Measured 2026-08-30: a 27 MB / 1522-file tree pushed `scratch-sh` from 2724 to over its 5000 cap; removing the directory did NOT clear the halt, `rt disconnect && rt connect` did.
   - When the sync itself is wedged, a **direct `ssh <host>` bypasses `rt` entirely** (and skips the flush) — the fastest escape for read-only/inspection work.

5. **Connection issues — `rt status` reports one of seven sync states, and they need different responses.** A flush fails fast (rc 2, nothing synchronised) on `paused`, `halted`, `erroring` and `unknown`; `exec` refuses on rc 2 and on `unknown`, and `slurm submit` refuses on rc 2 and 3.

   | `sync=` | means | what fixes it |
   |---|---|---|
   | `active` | connected, and the status verb is one this tool recognises as healthy | — |
   | `offline` | an endpoint is disconnected, or still connecting | check network; `rt sync flush` to retry |
   | `paused` | someone paused it | **`rt connect` resumes it** |
   | `erroring` | connected, but Mutagen has a live error and is synchronising **nothing** | usually the entry-count breaker — see below |
   | `halted` | Mutagen hit a **safety brake**: a root was emptied, deleted, or changed type | needs a human decision — see below |
   | `none` | no session for this profile | `rt connect` |
   | `unknown` | the daemon could not be asked, answered ambiguously, or reported a status verb this tool does not recognise — **no claim is made either way** | `mutagen daemon start`; if it persists, `rt` may be older than your Mutagen |

   **Read the ⚠ on a `status --all` row before trusting any state word.** A row that is not synchronising is marked `⚠ synchronising nothing`, and one whose session has never completed a single cycle adds `— has NEVER completed a cycle`; the summary line counts those separately from the live sessions. That distinction is the one the state word cannot make: `erroring` is a statement about NOW, so a breaker that clears on the next rescan and one that can never clear (the tree is simply larger than the configured limit) print the same word. Measured 2026-08-12: a profile sat erroring for at least two days without one completed cycle, listed among the healthy profiles in the same visual form, and read to a session as "currently retrying". A row also carries `⚠ LOCAL sync root ABSENT (<dir>)` / `⚠ REMOTE sync root ABSENT (<dir>)` when the directory a session synchronises no longer exists on that endpoint — one stat per endpoint, the remote one only while Mutagen reports that endpoint connected, and `(remote root not established)` when the host did not answer, which is never read as absent. An absent root is the precondition for a wholesale propagation in either direction; rt reports it and changes nothing about what Mutagen does next (ruled 2026-09-05: report half only), so establish which side is authoritative before the next cycle.

   **Both `erroring` and `halted` used to be reported as `active`.** The classifier decided health from the *absence* of two strings, so every state Mutagen has that those strings do not name read as healthy. Two measured examples: the entry-count breaker reports `Connected: Yes` on both endpoints with `Status: Waiting … for rescan`; and all three safety brakes (`HaltedOnRootEmptied`, `HaltedOnRootDeletion`, `HaltedOnRootTypeChange`) report `Connected: Yes` on both endpoints with an **empty** last-error field. Classification is now positive: `active` requires a recognised healthy verb, and anything unrecognised is `unknown`.

   `rt connect` does **not** recover either state — neither is paused, so there is nothing to resume — and flushing them does not fail, it **hangs** (measured). The remedies differ, which is why they are separate states:

   - **`erroring`** — fix the cause (usually a heavy dir missing from `MUTAGEN_IGNORE`, or raise `MUTAGEN_MAX_ENTRY_COUNT`), then **recreate**: `rt disconnect && rt connect`. Editing `MUTAGEN_IGNORE` alone does nothing, because ignores are applied only at session-create time. `rt status` prints the live error beside the state, plus a `Sync cause:` line when the error shape matches a limit `rt` itself set (`MUTAGEN_MAX_STAGING_FILE_SIZE`, `MUTAGEN_MAX_ENTRY_COUNT`) — Mutagen reports what broke, only `rt` knows which of its own settings made it inevitable. That line is a shape match, not a measurement, and says so.
   - **`halted`** — do **not** recreate the session to clear it. The brake fired because one root's contents vanished or changed type, and clearing it decides which side wins. Inspect with `rt sync status`, then recover deliberately with `mutagen sync reset --label-selector="rt-host=<host>,rt-profile=<profile>"` or by reconciling the two roots by hand.

6. **Missing dependencies** — If `rt check` reports "not found", **do not attempt to sudo install**. Tell the user to run the install commands.

7. **Help** — `rt help` for command reference.
