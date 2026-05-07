#!/usr/bin/env bash
# Install Remote Toolkit:
# - Symlinks the rt CLI to ~/.local/bin/
# - Migrates configs to ~/.config/remote-toolkit/
# - Installs as Claude Code SKILL: ~/.claude/skills/remote (the repo) +
#   ~/.claude/commands/remote.md slash-command shim
# Default: symlink (live updates via `git pull`).
# `--copy`: copy contents (excluding .git); the original clone can be deleted,
# but future updates require re-clone + re-run.
set -euo pipefail

MODE="symlink"
case "${1:-}" in
    "")        ;;
    --symlink) MODE="symlink" ;;
    --copy)    MODE="copy" ;;
    -h|--help)
        cat <<EOF
Usage: $0 [--symlink | --copy]

  --symlink (default)  Symlink ~/.claude/skills/remote and the slash command
                       back to this repo. git pull picks up updates.
  --copy               Copy the skill (excluding .git) into ~/.claude/skills/remote
                       and the slash command into ~/.claude/commands/remote.md.
                       The original clone can be deleted afterward; updates
                       require re-clone + re-run.
EOF
        exit 0
        ;;
    *)
        echo "Unknown argument: $1. Use --help." >&2
        exit 1
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT_HOME="${RT_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/remote-toolkit}"
BIN_DIR="$HOME/.local/bin"
CLAUDE_DIR="$HOME/.claude"

_color() { [[ -t 1 ]] && printf '\e[%sm' "$1" || true; }
_reset() { _color 0; }
info()  { _color 32; printf ':: %s\n' "$*"; _reset; }
warn()  { _color 33; printf '!! %s\n' "$*"; _reset; }

printf '\n  Remote Toolkit — Install\n\n'

# ── 1. Check dependencies ────────────────────────────────────────
chmod +x "$SCRIPT_DIR/rt"
"$SCRIPT_DIR/rt" check || true
printf '\n'

# ── 2. Create config directory ────────────────────────────────────
# Configs live under $RT_HOME/<host>/{host,<profile>}.conf and are user-managed.
# `rt -p <host>/<profile> init` seeds skeleton files when needed.
mkdir -p "$RT_HOME"

# ── 3. Symlink to PATH ───────────────────────────────────────────
mkdir -p "$BIN_DIR"
if [[ -L "$BIN_DIR/rt" || -f "$BIN_DIR/rt" ]]; then
  rm "$BIN_DIR/rt"
fi
ln -s "$SCRIPT_DIR/rt" "$BIN_DIR/rt"
info "Symlinked: $BIN_DIR/rt → $SCRIPT_DIR/rt"

# Check if ~/.local/bin is in PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  # Add to .bashrc
  SHELL_RC="$HOME/.bashrc"
  [[ "$(basename "$SHELL")" == "zsh" ]] && SHELL_RC="$HOME/.zshrc"
  if ! grep -q 'export PATH="$HOME/.local/bin' "$SHELL_RC" 2>/dev/null; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$SHELL_RC"
    warn "$BIN_DIR not in PATH. Added to $SHELL_RC."
    warn "Run: source $SHELL_RC"
  fi
fi

# ── 4. Migrate from old install (CLAUDE.md fragment + slash file) ──
MARKER_START="<!-- remote-toolkit start -->"
MARKER_END="<!-- remote-toolkit end -->"

if [[ -f "$CLAUDE_DIR/CLAUDE.md" ]] && grep -qF "$MARKER_START" "$CLAUDE_DIR/CLAUDE.md"; then
  tmpfile=$(mktemp)
  awk -v start="$MARKER_START" -v end="$MARKER_END" '
    $0 == start { in_block = 1; next }
    $0 == end   { in_block = 0; next }
    !in_block   { print }
  ' "$CLAUDE_DIR/CLAUDE.md" > "$tmpfile"
  # Collapse runs of multiple blank lines that the removal may have produced.
  awk 'BEGIN{blank=0} /^$/{blank++; if (blank<=1) print; next} {blank=0; print}' \
    "$tmpfile" > "$tmpfile.2"
  mv "$tmpfile.2" "$CLAUDE_DIR/CLAUDE.md"
  rm -f "$tmpfile"
  info "Removed old <!-- remote-toolkit --> block from $CLAUDE_DIR/CLAUDE.md"
fi

# Old install put a regular file at ~/.claude/commands/remote.md; remove it so
# we can install our symlink/copy in step 5. Leave symlinks alone — those are
# either ours (idempotent re-run) or the user's intentional override.
if [[ -f "$CLAUDE_DIR/commands/remote.md" && ! -L "$CLAUDE_DIR/commands/remote.md" ]]; then
  rm "$CLAUDE_DIR/commands/remote.md"
  info "Removed old slash-command file $CLAUDE_DIR/commands/remote.md"
fi

# ── 5. Install as Claude Code SKILL + slash command ──────────────
mkdir -p "$CLAUDE_DIR/skills" "$CLAUDE_DIR/commands"

SKILL_TARGET="$CLAUDE_DIR/skills/remote"
COMMAND_SRC="$SCRIPT_DIR/commands/remote.md"
COMMAND_TARGET="$CLAUDE_DIR/commands/remote.md"

# install_target <src> <target> <mode> <label>
# Idempotent: skip if symlink already points at intended source; refuse
# to overwrite anything else (the user has to remove it manually).
install_target() {
  local src="$1"
  local target="$2"
  local mode="$3"
  local label="$4"

  if [[ -L "$target" || -e "$target" ]]; then
    if [[ -L "$target" && "$(readlink "$target")" == "$src" && "$mode" == "symlink" ]]; then
      info "$label symlink already in place: $target -> $src"
      return 0
    fi
    warn "Refusing to overwrite existing $target. Remove it manually if intended."
    exit 1
  fi

  if [[ "$mode" == "symlink" ]]; then
    ln -s "$src" "$target"
    info "Linked $label: $target -> $src"
  else
    if [[ -d "$src" ]]; then
      rsync -a --exclude='.git' "$src/" "$target/"
    else
      cp "$src" "$target"
    fi
    info "Copied $label: $src -> $target"
  fi
}

install_target "$SCRIPT_DIR"  "$SKILL_TARGET"   "$MODE" "skill"
install_target "$COMMAND_SRC" "$COMMAND_TARGET" "$MODE" "/remote slash command"

# ── 6. Summary ────────────────────────────────────────────────────
printf '\n'
info "Installation complete!"
info "  Config:   $RT_HOME/"
info "  Command:  rt (via $BIN_DIR/rt)"
info "  CC integration: SKILL at $SKILL_TARGET + /remote slash command"
printf '\n'

if [[ "$MODE" == "copy" ]]; then
  info "Future updates: rm -rf $SKILL_TARGET $COMMAND_TARGET, then re-clone and re-run 'bash install.sh --copy'."
  printf '\n'
fi

info "Next steps:"
info "  1. rt -p <host>/<profile> init    # seeds host.conf + <profile>.conf skeletons"
info "  2. Edit $RT_HOME/<host>/host.conf (REMOTE_HOST, SSH_PORT, SLURM_ENABLED)"
info "  3. Edit $RT_HOME/<host>/<profile>.conf (REMOTE_DIR, optional LOCAL_DIR)"
info "  4. rt -p <host>/<profile> setup-key --password 'your-password'"
info "  5. rt -p <host>/<profile> connect"
info ""
info "Reference templates: $SCRIPT_DIR/host.conf.example, $SCRIPT_DIR/profile.conf.example"
printf '\n'
