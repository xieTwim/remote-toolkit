---
name: remote
description: Remote Toolkit — drives remote servers via Mutagen file sync + SSH through the `rt` CLI; supports multiple servers via profiles, Slurm submission/monitoring on HPC hosts, and tmux-backed background commands. Use this skill whenever the user mentions a remote server, SSH target, HPC cluster, GPU box, the `rt` command, file sync to/from a remote machine, Slurm jobs (submit/queue/logs/cancel), `.sbatch` files, profile setup/connection, or asks to run/move/deploy something on a remote — even if they don't explicitly say "rt" or "remote toolkit". On the first prompt that triggers this skill, run `rt status --all` to enumerate configured profiles before assuming which one to use.
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

### Remote Command Execution

Short commands (< 30 seconds) — auto-flushes sync first:
```bash
rt -p fact-cluster/scratch exec "pwd"
rt -p fact-cluster/scratch exec "nvidia-smi"
rt -p fact-cluster/scratch exec --no-flush "ls"   # skip flush for fast iteration
```

Long commands (builds, training daemons, services):
```bash
rt -p fact-cluster/scratch exec --bg --name build "make all"
rt -p fact-cluster/ako exec --bg --name train "python3 train.py"
```

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

2. **Long-running commands** — use `rt exec --bg` (any host) or `rt slurm submit` (Slurm hosts). SSH timeouts will kill foreground commands over a few minutes.

3. **A failed flush is two different states, and the callers differ on purpose.** `_sync_flush` returns **2** (paused session or a mutagen error — *nothing* was synchronised) or **3** (the `RT_FLUSH_TIMEOUT` bound elapsed; the daemon keeps syncing). `rt exec` REFUSES on 2 and continues with a warning on 3 — refusing on a routine timeout would just make `--no-flush` habitual. `rt slurm submit` refuses on BOTH, because a queued job outlives the shell that queued it, and it also refuses when there is **no sync session at all** (`--assume-staged` if the script was placed there by other means). `rt sync flush` exits non-zero when it could not flush.

4. **Sync timing & the flush wedge** — Mutagen syncs in the background. `rt exec` (and `slurm submit`) auto-flush FIRST so the remote sees the latest edits. That flush is **bounded by `RT_FLUSH_TIMEOUT` (default 10s)**: without the cap, a large or backlogged sync blocks until a full cycle completes, which **wedges every command — even `echo` hangs for minutes**. If exec is slow or wedging:
   - `--no-flush` skips the flush entirely (fast, but beware stale code).
   - The real cause is usually a **bloated sync set** — a heavy dir missing from the profile's `MUTAGEN_IGNORE`. Check `mutagen sync list`; a multi-GB or many-thousand-file working set is the tell. Add the dir to `MUTAGEN_IGNORE` and recreate the session (`rt disconnect && rt connect` — ignores only apply at create time).
   - **The wedge is cross-project.** All profiles share ONE Mutagen daemon (and, per host, one mount), so a runaway sync in *one* profile stalls *every* profile's flush, not just its own. `rt` now caps each session with `--max-entry-count` (default 50000, override `MUTAGEN_MAX_ENTRY_COUNT`, empty disables) so a runaway **halts itself** instead of taking the daemon down — a *halted* session with a huge entry count in `mutagen sync list` is the tell; fix its `MUTAGEN_IGNORE` and recreate. The cap backstops ignore hygiene, it doesn't replace it (on ceph-fuse even a few-thousand-file dir hurts below the cap).
   - When the sync itself is wedged, a **direct `ssh <host>` bypasses `rt` entirely** (and skips the flush) — the fastest escape for read-only/inspection work.

5. **Connection issues** — If `rt status` shows `sync=offline`, check network. `rt sync flush` to retry. If it shows `sync=paused` (manual pause or the entry-count circuit breaker halting the session), flushes fail fast with a warning — `exec` proceeds on possibly-stale code, `slurm submit` aborts — until **`rt connect` resumes it**. A breaker-halted session records its error in `rt sync status`; fix `MUTAGEN_IGNORE` first or it halts again. `rt disconnect && rt connect` to recreate the session.

6. **Missing dependencies** — If `rt check` reports "not found", **do not attempt to sudo install**. Tell the user to run the install commands.

7. **Help** — `rt help` for command reference.
