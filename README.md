# Remote Toolkit

Let Claude Code drive remote servers from any working directory. Mutagen sync for files; SSH/tmux for commands; opt-in Slurm subcommands for HPC clusters.

## How It Works

Local replica directories sync to remote via Mutagen, so CC can use Read/Edit/Write at local-disk speed. Commands run over SSH, with tmux keeping long-running tasks alive. For HPC clusters, opt-in Slurm subcommands wrap `sbatch`/`squeue`/`scancel`.

```
Local Claude Code
  ├── Read/Edit/Write  →  ~/Work/Remote/<host>/<profile>/  ⇄ Mutagen ⇄  <host>:<remote-dir>
  ├── rt exec          →  SSH + tmux                       →  remote shell                ┐ shared FS
  └── rt slurm submit  →  flush; sbatch                    →  Slurm ──────────────────→  compute (H100/H20/...)
```

Profiles are namespaced as `<host-group>/<profile-name>`. One host group can hold multiple profiles (e.g. `fact-cluster/scratch`, `fact-cluster/ako`) sharing a `host.conf`.

## Install

```bash
# 1. Install system dependencies (CC can't sudo — you need to do this)

# Linux (Debian/Ubuntu)
sudo apt install -y tmux sshpass
# Plus Mutagen: https://mutagen.io/documentation/introduction/installation

# macOS (requires Homebrew)
brew install mutagen-io/mutagen/mutagen
brew install tmux
brew install esolitos/ipa/sshpass

# 2. Clone and install
git clone <repo-url>
cd remote-toolkit
./install.sh
```

`install.sh` does the following:
- Symlinks `~/.local/bin/rt` → makes the `rt` command available globally
- Adds `~/.local/bin` to PATH in `~/.bashrc` (or `~/.zshrc`) if not already present
- Creates config directory `~/.config/remote-toolkit/` (configs are user-managed; `rt -p <host>/<profile> init` seeds skeletons on demand)
- Symlinks the repo to `~/.claude/skills/remote/` → installs as a Claude Code SKILL. CC discovers it from the skill list and triggers it whenever the user mentions a remote server, SSH, Slurm, etc.
- Symlinks `commands/remote.md` to `~/.claude/commands/remote.md` → typing `/remote` invokes the SKILL explicitly.

Pass `--copy` instead of the default `--symlink` if you want the install to copy files (so the original clone can be deleted afterward).

Re-running `install.sh` is idempotent. If you previously installed an older version that injected a fragment into `~/.claude/CLAUDE.md`, the installer removes the `<!-- remote-toolkit -->` block automatically.

## Usage

After installing, just tell CC your server info:

> **You:** Connect to root@192.168.1.100 port 22, password xxx, and edit /root/app/config.yaml

CC handles everything: create config → push SSH key → connect → edit the file.

On first connection, CC copies your local SSH public key (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`) to the remote server's `~/.ssh/authorized_keys` using the password you provide. After that, all connections are passwordless. The password is only used once and is not stored.

**Multiple servers / multiple workspaces:** profiles are `<host-group>/<profile-name>`. Same host group → shared `host.conf` (login info); each profile has its own `<profile>.conf` (remote workspace).

> **You:** Connect to this HPC login node, call the host group `hpc`, profile `train`: user@login.cluster, password xxx, working directory /home/user/train, this cluster uses Slurm

Then refer to it as `hpc/train`:

> **You:** Submit train.sbatch to the queue on hpc/train

> **You:** Disconnect hpc/train

Disconnecting only terminates the sync session. Your local replica at `~/Work/Remote/hpc/train/` is preserved — say "connect hpc/train" to reconnect. To add another workspace on the same cluster (e.g. `hpc/eval`), CC just creates a new `<profile>.conf` under `~/.config/remote-toolkit/hpc/`; the existing `host.conf` is reused.

### A flush is not a proof of arrival

`rt sync flush` forces a synchronization **cycle**. It does not compare content, and it does not
prove the two sides are equal — confirmed against the real engine, a session with an unresolved
conflict and a session with an ignored path **both flush with exit 0 while the endpoints differ**.
So "flush returned 0" means a cycle completed, not "the remote has my file", and `sleep N` means
even less.

When it matters that a specific file has actually landed — you are about to launch it, submit it,
or copy it into place — assert it:

```bash
rt -p hpc/train verify train.py configs/run.yaml
```

It hashes those paths on both sides and waits until they match (default 60s). `0` = equal and
stable, `2` = blocked or unverifiable (bad/ignored path, sync not propagating, no hashing tool),
`3` = still different at the deadline. A `3` means non-arrival; it is **not** a promise that sync
is still working on it.

### What does not sync

The local replica is **not** a full copy of the remote directory. Every profile is created with this default ignore set, and files under these paths never cross in either direction:

```
__pycache__/  *.pyc  .venv/  venv/  node_modules/
wandb/  outputs/  checkpoints/  .ipynb_checkpoints/
.triton_cache/  .DS_Store  *.swp
.claude/  CLAUDE.md  HANDOFF.md  HINTS.md  ITERATIONS.md  .local/  *.local.md
```

…plus `.git/` when `MUTAGEN_IGNORE_VCS=1` (the default), plus anything the profile adds via `MUTAGEN_IGNORE`. So a run that writes results into `outputs/` or `checkpoints/` produces **nothing** locally — that is deliberate (those are large), but it means "it didn't sync" is usually "it was never in scope".

**Ignores are frozen when the session is created.** Editing `MUTAGEN_IGNORE` does not change a running session; `rt disconnect && rt connect` applies it. `rt sync status` prints the **live** session's effective ignores and warns when they no longer match what the config would create — read that, not the config file.

## Things You May Need to Do Manually

| Scenario | Action |
|----------|--------|
| CC reports missing dependencies (Linux) | `sudo apt install -y tmux sshpass` + install Mutagen from mutagen.io |
| CC reports missing dependencies (macOS) | `brew install mutagen-io/mutagen/mutagen tmux esolitos/ipa/sshpass` |
| First time connecting to a server | Tell CC the address, port, and password |
| Non-default SSH port / key | Add a `Host` entry to `~/.ssh/config` so Mutagen sees the same SSH params |
| Sync stuck or out of sync | Tell CC to run `rt sync flush` or `rt disconnect && rt connect` |

Everything else (config creation, SSH key setup, file editing, command execution, background task management, Slurm submission) is handled by CC through the `rt` command.

## Configuration

Config directory: `~/.config/remote-toolkit/`. Two-tier layout grouped by host:

```
~/.config/remote-toolkit/
└── <host-group>/
    ├── host.conf            # shared by all profiles in this host group
    └── <profile>.conf       # one per workspace on that host
```

Profile names must be in `<host>/<profile>` form. Each segment is alphanumeric with single dashes between alphanumerics (no leading/trailing dash, no `--`, no `_` or `.`), max 32 chars — keeps the name unambiguous in Mutagen labels and tmux/Mutagen session names.

Example layout:

| File | Purpose | Local replica |
|------|---------|---------------|
| `fact-cluster/host.conf` | Login + SSH params for fact-cluster | — |
| `fact-cluster/scratch.conf` | Workspace `scratch` on fact-cluster | `~/Work/Remote/fact-cluster/scratch/` |
| `fact-cluster/ako.conf` | Workspace `ako` on fact-cluster | `~/Work/Remote/fact-cluster/ako/` |
| `another-host/host.conf` | Login + SSH for another host | — |

`host.conf` (sourced first):
```bash
REMOTE_HOST="user@hostname"     # or ~/.ssh/config alias — required
SSH_PORT=22                     # optional, default 22
SSH_KEY="$HOME/.ssh/id_ed25519" # optional, default agent
SLURM_ENABLED=1                 # optional, enables `rt slurm *`
```

`<profile>.conf` (sourced second; values override host-level ones):
```bash
REMOTE_DIR="/home/user/project"               # required
# LOCAL_DIR="$HOME/Work/Remote/<host>/<profile>" # default; override only if needed
# MUTAGEN_SYNC_MODE="two-way-resolved"
# MUTAGEN_IGNORE_VCS=1
# MUTAGEN_IGNORE=("data/" "*.bin")
# SLURM_LOG_DIR="$REMOTE_DIR"                  # where slurm-<id>.out lands
```

Reference templates: `host.conf.example` and `profile.conf.example` in the repo. `rt -p <host>/<profile> init` seeds both skeletons in the right place if they don't exist yet.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `rt check` says `mutagen: command not found` | Install Mutagen (see Install section) |
| `command not found: timeout` when bounding a remote read | macOS has no `timeout(1)` (it is `gtimeout`, from coreutils). Do not wrap `rt` in it — use `rt exec --timeout SECS`, which implements the bound in pure Bash and exits 124. Piping a failed `timeout` into `head` is especially bad: the pipeline exits 0, so a read that never ran looks like a read that found nothing. |
| `rt exec` says `output is TRUNCATED` (exit **125**) | The stream ended before the remote command reported finishing, so what arrived is a **prefix**, not the answer. 125 means "no outcome was established"; a transport that failed on its own keeps its own status instead. Re-run, and for large payloads redirect to a file rather than capturing the stream. |
| A large `rt exec` payload came back cut off, and the call exited 0 | Fixed for the half `rt` can see (above). The other half it cannot: neither `rt` nor `ssh` caps the payload, so a cut at ~100 KB is in whatever *captures* rt's stdout. A complete payload ≥ 64 KiB now reports `exec delivered N bytes of stdout, complete` — compare N against what you hold. Better: `rt … exec 'cat big' > local.file`, never `rt … exec … \| something`, since a pipeline reports the last stage's status and throws rt's away. Threshold: `RT_EXEC_REPORT_BYTES`. |
| SSH connection failed | Check network: `ssh -p PORT user@host "echo ok"` |
| `rt status` shows `sync=offline` | `rt sync flush` to retry; check network; verify `~/.ssh/config` matches the `host.conf`'s SSH params |
| `rt status` shows `sync=erroring` | Mutagen has a live error and is syncing **nothing** (the error is printed beside the state). `rt connect` cannot recover it — it is not paused, so there is nothing to resume. Fix the cause (usually a heavy dir missing from `MUTAGEN_IGNORE`, or raise `MUTAGEN_MAX_ENTRY_COUNT`), then **recreate**: `rt disconnect && rt connect`. Editing `MUTAGEN_IGNORE` alone does nothing — ignores apply only at session-create time. |
| `rt status` shows `sync=halted` | A Mutagen **safety brake**: a root was emptied, deleted, or changed type. Do *not* recreate the session to clear it — that decides which side's contents win. See the one-sided-root-emptying row below. |
| `rt status` shows `sync=unknown` | The daemon could not be asked, answered ambiguously (two sessions on one profile's labels), or reported a status verb this `rt` does not recognise. Nothing is claimed about the session either way. `mutagen daemon start`; if it persists, `rt` may be older than your Mutagen. |
| Mutagen connects but files don't sync | `rt sync status` for details; check `MUTAGEN_IGNORE` patterns |
| Slurm subcommands say "not enabled" | Set `SLURM_ENABLED=1` in `host.conf` (or override in the profile config) |
| `rt slurm submit` ran old code | Sync may not have flushed; check `rt sync status` and re-run |
| Mutagen halts with "one-sided root emptying" after you bulk-deleted files on one side | Safety feature: prevents accidental wipe via deletion propagation. Recover with `mutagen sync reset --label-selector="rt-host=<host>,rt-profile=<profile>"`, or `rm` the corresponding files on the other side too. |
