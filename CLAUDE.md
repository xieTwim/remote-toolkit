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

Subcommands: `init` `check` `setup-key` `connect` `disconnect` `exec` `logs` `status` `sync` `slurm` `help`

## Mutagen Integration

- `rt connect` ensures the Mutagen daemon is running (`mutagen daemon start`, idempotent), then creates a sync session named `rt-<host>-<profile>` with two labels: `rt-host=<host>` and `rt-profile=<profile>`.
- All Mutagen queries (`_has_sync`, `_sync_status`, `_sync_flush`, `_sync_terminate`) build a composite selector via `_sync_label_selector` (`rt-host=<h>,rt-profile=<p>`). Helpers default to globals; pass `(host, profile)` explicitly when iterating (e.g., from `_status_all`).
- **`_sync_flush` is time-bounded** (`RT_FLUSH_TIMEOUT`, default 30s): `mutagen sync flush` blocks until a full sync cycle completes, and since `cmd_exec`/`cmd_slurm` auto-flush first, an unbounded flush on a large/backlogged session wedged *every* command. It now runs the flush in the background and kills it past the cap (returning non-zero so the caller warns); the daemon keeps syncing regardless. A profile whose flush routinely times out is missing `MUTAGEN_IGNORE` entries for a heavy dir.
- `_status_all` walks `$RT_HOME/.rt/*/` for host-group dirs, then `*/` for profiles within each, and renders `[host/profile]` rows.
- Mutagen URL form is `[user@]host:path` and reads SSH parameters from `~/.ssh/config`. For non-default `SSH_PORT` or `SSH_KEY`, the user must add a matching Host entry to ssh config; `rt connect` warns when this is needed.

## Slurm Integration

- Gated by `SLURM_ENABLED=1` set in `host.conf` (typical) or `<profile>.conf` (override). `cmd_slurm` calls `_slurm_require_enabled` first; non-Slurm hosts get a clear error.
- `rt slurm submit` performs a mandatory `_sync_flush` before `sbatch` to prevent stale-code submissions, then parses sbatch output for the job ID and appends to `.rt/<host>/<profile>/slurm_jobs` (cap 50 entries).

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
