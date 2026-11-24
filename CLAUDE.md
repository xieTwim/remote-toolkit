# Remote Toolkit — Developer Guide

This file is for **CC developing this tool**, not for using it. The usage guide is in `SKILL.md`.

## Project Structure

```
rt                       Main script (Bash), all functionality
host.conf.example        Reference template for <host-group>/host.conf
profile.conf.example     Reference template for <host-group>/<profile>.conf
install.sh               Installer: symlink, CC SKILL install
SKILL.md                 Claude Code SKILL — frontmatter (name=remote, description) + full guide.
                         install.sh symlinks the whole repo to ~/.claude/skills/remote/.
commands/
  remote.md              Slash-command shim. install.sh symlinks to ~/.claude/commands/remote.md.
                         `/remote` invokes the SKILL.
CLAUDE.md                This file (developer guide)
README.md                User-facing documentation
```

## rt Script Architecture

- **RT_HOME**: Root directory for config and state, defaults to `~/.config/remote-toolkit/`, overridable via env var.
- **RT_SCRIPT_DIR**: Script's own directory.
- **Profile system (host-grouped)**: `-p <host>/<profile>` selects a profile. Required — no bare-name fallback. Each segment must match `^[a-zA-Z0-9](-?[a-zA-Z0-9])*$` and be ≤32 chars (no `_`, no `.`, no `--`, no leading/trailing dash). The strict charset keeps segment encodings injective across the various derived identifiers.
  - `_init_profile` builds paths from RT_PROFILE without validating; commands that operate on a specific profile call `_require_profile` (which `load_config` and `cmd_init` invoke). Commands like `status --all`, `check`, and `help` work without a profile.
  - `RT_HOST_CONF=$RT_HOME/<host>/host.conf` (host-shared vars; sourced first by `load_config`).
  - `RT_CONF=$RT_HOME/<host>/<profile>.conf` (profile vars; sourced second, overrides host).
  - `RT_STATE_DIR=$RT_HOME/.rt/<host>/<profile>` (two-level).
  - `RT_SESSION_PREFIX=rt_<host>_<profile>_bg_` (tmux session prefix; `_` separator, segments forbid `_`).
  - Mutagen session name `rt-<host>--<profile>` (`--` separator, segments forbid `--`). Mutagen rejects `_` in session names; double-dash is the closest injective separator using only allowed chars.
  - Local mount default: `~/Work/Remote/<host>/<profile>/`.
- **Dispatch**: `main()` parses global flags then routes to `cmd_*` functions.

Subcommands: `init` `check` `setup-key` `connect` `disconnect` `exec` `logs` `status` `sync` `slurm` `colab` `help`

## Mutagen Integration

- `rt connect` ensures the Mutagen daemon is running (`mutagen daemon start`, idempotent), then creates a sync session named `rt-<host>--<profile>` with two labels: `rt-host=<host>` and `rt-profile=<profile>`. If the session already exists but is paused (manual pause or circuit-breaker halt), connect resumes it (`_sync_resume`) before flushing; a failed resume dies with a pointer to `rt sync status`.
- All Mutagen queries (`_has_sync`, `_sync_status`, `_sync_flush`, `_sync_resume`, `_sync_terminate`) build a composite selector via `_sync_label_selector` (`rt-host=<h>,rt-profile=<p>`). Helpers default to globals; pass `(host, profile)` explicitly when iterating (e.g., from `_status_all`).
- **Mutagen daemon calls are time-bounded** via `_run_bounded` (flush: `RT_FLUSH_TIMEOUT`, default 10s; resume: `RT_RESUME_TIMEOUT`, default 60s — it re-establishes the SSH transport): `mutagen sync flush` blocks until a full sync cycle completes, and since `cmd_exec`/`cmd_slurm` auto-flush first, an unbounded flush on a large/backlogged session wedged *every* command. `_run_bounded` runs the call in the background and kills it past the cap (returning non-zero so the caller warns); the daemon keeps syncing regardless. A profile whose flush routinely times out is missing `MUTAGEN_IGNORE` entries for a heavy dir. `_sync_flush` additionally **fails fast on a paused session** (a paused session never completes a cycle, so flushing it would just burn the timeout) — it warns and returns 2, telling the caller `rt connect` resumes it.
- `_status_all` walks `$RT_HOME/.rt/*/` for host-group dirs, then `*/` for profiles within each, and renders `[host/profile]` rows.
- Mutagen URL form is `[user@]host:path` and reads SSH parameters from `~/.ssh/config`. For non-default `SSH_PORT` or `SSH_KEY`, the user must add a matching Host entry to ssh config; `rt connect` warns when this is needed.

## Slurm Integration

- Gated by `SLURM_ENABLED=1` set in `host.conf` (typical) or `<profile>.conf` (override). `cmd_slurm` calls `_slurm_require_enabled` first; non-Slurm hosts get a clear error.
- `rt slurm submit` performs a mandatory `_sync_flush` before `sbatch` to prevent stale-code submissions, then parses sbatch output for the job ID and appends to `.rt/<host>/<profile>/slurm_jobs` (cap 50 entries).
- `SLURM_SBATCH_ARGS` (host.conf or `<profile>.conf`; plain var, profile value replaces host value) seeds `sbatch_args` in `_slurm_submit` BEFORE the explicit `-- ...` args, so per-invocation args override the standing defaults (sbatch last-wins). The submit info line echoes the merged args. Do not put a default partition here — CLI args override in-script `#SBATCH -p` directives.

## Colab runtimes (`rt colab`)

The section "Colab runtimes" in `rt` (comment block at its top holds the measured facts). A runtime
NAME is host group `colab-NAME` with one profile, `work` (REMOTE_DIR `/content/work`), so every
existing verb works on it through an ssh alias; `rt colab` only adds the lifecycle.

- Per runtime: `$RT_HOME/colab-NAME/` holds `host.conf`, `work.conf`, `colab.meta` (endpoint,
  hardware, created, deadline, idle limit — deliberately not `*.conf`, so it is never read as a
  profile), the colab CLI's own `colab-session.json` for this runtime alone, and `proxy.log`;
  the alias is `~/.ssh/rt-colab.d/colab-NAME.conf` (`RT_COLAB_SSH_DIR`), reached through one
  `Include` line that `rt colab setup` puts at the top of `~/.ssh/config`.
- The ProxyCommand is `colab --config <that json> ssh --proxy-mode --colab-internal-mode cmd -s NAME`.
  The documented `--proxy-mode -s NAME` creates a runtime when NAME is missing locally, by design
  (the CLI's `docs/06_ssh_access.md`); the hidden `cmd` mode only resolves. `_colab_canary`
  re-proves that offline (dead proxies, empty record: exit 2, "not found", empty stdout) in `setup`
  and before every `up`; `up` refuses otherwise. Canary 24q runs it against the installed CLI, so
  an upgrade that breaks it fails the suite. The same doc says bare `--proxy-mode` (no `-s`) only
  resolves too, which would do this without a hidden option (BACKLOG).
- One ssh connection per runtime here (429 on a second; the CLI says the limit depends on the
  plan): the alias sets `ControlMaster auto` + `ControlPersist 15m`, with `ControlPath` keyed on
  the per-runtime HostName, so two runtimes never share a master. (The CLI's own `colab ssh` gives
  every session the host name `colab-runtime`, so under a `Host *` ControlMaster one session's
  commands reach another's runtime: its discussion #247.) The first `true` in `up` becomes
  the master. A vanished client leaves the runtime holding the slot; `_require_ssh` calls
  `_colab_heal_slot` for colab profiles (end the session through `colab exec`, retry every 5 s for
  90 s; the slot freed ~33 s after when measured). The CLI's main branch adds `colab ssh --force`
  for the same, after 0.8.0 (BACKLOG).
- Colab takes back a runtime nothing connects to. Four CPU runtimes with an rt job were gone about
  3 h after their last connection; a kernel cell left running and the VM calling its own kernel did
  not count; two reached from the Mac every 30 min were still up at 4.5 h (2026-11-24; the CLI's
  issue #160 and PR #144 say the same). A T4 running a GPU job went 20-22 min after its last
  connection, while one with a keeper ran on (2026-11-25; its discussion #219 saw a G4 go after
  23 min). So `up`
  starts a keeper, `rt colab _keep NAME`, detached by `_detach` (setsid, else perl's: macOS has no
  setsid). Every RT_COLAB_KEEP_EVERY s (300) it runs the alias's ssh `true`, which keeps the
  ControlMaster open or reopens it (heal path on a held slot), and it holds `caffeinate -i -w <its
  pid>`. Its lease is the record: it stops once colab.meta is gone or names another endpoint, at the
  deadline, or when a failed connection finds the runtime off the account (a failed listing does not
  stop it). `_require_ssh` (every rt command on a colab profile) and `reconnect` start it again when
  `_colab_keeper_running` (pid file plus the `ps` command line, since pids are reused) finds none. The
  watchdog does not count an open idle connection as busy, so idle release is unchanged.
- `colab sessions` exits 1 when it fails (no network, a sign-in that needs a person), and its
  traceback quotes the source line that prints "No active sessions found on server." So
  `_colab_account_list` reads the exit status before the text (24n3), and accepts an empty answer
  only when `colab usage` reports 0 as well, because a "gone" verdict on a still-billing runtime
  would delete the only record of it. (The one empty-list-on-failure path in the CLI is
  unrefreshable ADC credentials under `--auth=adc`, which rt never passes.)
- The watchdog (`_colab_watchdog_script`) is installed by a bootstrap sent as one base64 word
  (`_colab_bootstrap_script`), so no argv on the VM carries a pgrep-able pattern, and `up` releases
  the runtime unless the VM reports the digest of exactly the script rt sent. It releases via
  `POST http://$TBE_RUNTIME_ADDR/unassign` (read from a Colab process's environment), the endpoint
  behind `google.colab.runtime.unassign()`.
- Failure paths release: a first ssh that fails three times (two retries through `_colab_heal_slot`,
  since one runtime refused it once right after READY), or a failed watchdog install, calls
  `_colab_release_and_forget`, which deletes local records only after the account list no longer
  shows the endpoint.
- Sets: `up --count N` checks every member name first, then creates NAME-1..N through `_colab_up_one`,
  each in a subshell with errexit forced on (`set +e; ( set -e; ... ); rc=$?`): run as an if/||
  condition, bash ignores -e inside, and a member that dies part-way would skip its own release.
  A failure releases the members already up. Members carry COLAB_SET/_INDEX/_SIZE in colab.meta;
  `down --set` and `exec SET` find them by record (`_colab_set_members`), never by name pattern.
  `exec SET` runs rt itself per member (`_colab_member_exec`, the test seam) with `RT_SHARD`/
  `RT_SHARDS` exported and stdin closed, since rt exec forwards stdin to the remote command.
- Google Drive (`--drive`, `rt colab drive`): the official `colab drivemount`, run in parallel with
  `BROWSER=true` so the CLI does not open a page per attempt. It exits 0 also when the mount failed,
  so each VM is asked (`mount | grep 'type fuse.drive'`); approval is per runtime (the consent URL's
  `state` carries the runtime), so rt opens the URLs of those not mounted (`_colab_open_url`, the
  test seam) and the user runs the command again. `_colab_drive_flush_fn` (Colab's
  `drive.flush_and_unmount()`, with CLOUDSDK_CONFIG read from a Colab process, which an ssh login
  lacks) is shared by the watchdog, which releases even when it fails, and `down`, which then keeps
  the runtime unless `--no-flush`. COLAB_DRIVE=1 in colab.meta marks a mount rt made.
- TPU: the bootstrap writes the TPU_*/PJRT_DEVICE/SLICE_BUILDER_WORKER_IPS settings from a Colab
  process's environment (pid 1 on a TPU runtime) to /root/.rt_colab/env.sh and puts a line reading it
  first in root's .bashrc, above its interactive-only guard: sshd's bash reads .bashrc for a remote
  command, so every rt command and tmux job has them. Without them libtpu asks a metadata server
  that does not answer and JAX fails.
- Late allocations: `_colab_up_one` notes the CLI log's length before `colab new` and tees its
  output. On failure `_colab_adopt` takes the first `GET .../tun/m/assign?nbh=` URL logged after
  that mark (the request's notebook hash; the CLI's own retries reuse it), and runs `_colab_adopt_py`
  on the CLI's interpreter (`_colab_cli_python`, from the script's #! line): `Client._issue_request`
  on that URL returns an Assignment if Colab made one, and then the same SessionState `colab new`
  writes goes into this runtime's record. Asked once after a refusal, every 30 s for 10 min after a
  timeout (RT_COLAB_ADOPT_WAIT/_POLL). These are CLI internals, so 24q2 checks them on the installed CLI.
- Tests: canary block 24 (stub CLI in `$CSTUB`, `_colab_ssh` stubbed; real CLI only in 24q and 24q2;
  the keeper is 24K1-24K9, its loop bounded by `_run_bounded`; RT_COLAB_KEEP=0 for the rest of the block).

## CC Integration: SKILL + slash command

`install.sh` installs as a Claude Code SKILL, mirroring the codex-review pattern. There is no `~/.claude/CLAUDE.md` injection.

- **`SKILL.md`** (repo root): frontmatter (`name: remote` + a "pushy" description that lists trigger phrases) + the full operational guide. install.sh symlinks the whole repo to `~/.claude/skills/remote/`. Loaded eagerly as metadata in CC's skill list; the body loads when the description matches the user's prompt or when `/remote` is invoked.
- **`commands/remote.md`**: thin slash-command shim with frontmatter (`description`, `argument-hint`, `allowed-tools`). install.sh symlinks it to `~/.claude/commands/remote.md`. Typing `/remote` triggers the SKILL.

If symlinked (default `--symlink` install mode), edits to `SKILL.md` and `commands/remote.md` take effect immediately — no re-run of `install.sh` needed. With `--copy`, re-run install.sh after edits.

`install.sh` also performs a one-shot migration from the old install form: it strips the `<!-- remote-toolkit start/end -->` block from `~/.claude/CLAUDE.md` and removes a stale regular-file `~/.claude/commands/remote.md` (left by the old `cp`-based install) before creating the new symlinks.

Skill design follows the official Anthropic skill-creator standards (progressive disclosure, "pushy" description that lists trigger phrases, imperative writing style). Reference: `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/skill-creator/skills/skill-creator/SKILL.md`.

## Development Conventions

- Run `bash -n rt` after modifying the rt script to check syntax
- Use `RT_HOME` for all paths — never hardcode `RT_DIR` or the script directory
- No Python/Node or other runtime dependencies — keep it pure Bash
- Config file format is source-able Bash variable assignments
