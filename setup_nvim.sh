#!/usr/bin/env bash
set -euo pipefail

if ! command -v nvim >/dev/null 2>&1; then
  printf "Error: 'nvim' not found on PATH.\n" >&2
  exit 1
fi

NVIM_CONFIG_DIR="$(nvim --headless +'echo stdpath("config")' +q 2>/dev/null | tr -d '\r' || true)"
if [ -z "${NVIM_CONFIG_DIR:-}" ]; then
  NVIM_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
fi
mkdir -p "$NVIM_CONFIG_DIR"

TARGET="$NVIM_CONFIG_DIR/init.vim"

if [ -f "$TARGET" ]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  cp -f "$TARGET" "$TARGET.bak.$ts"
  echo "Backed up existing init.vim to $TARGET.bak.$ts"
fi

cat > "$TARGET" <<'EOF'
"
set number

set expandtab
set tabstop=4
set shiftwidth=4
set softtabstop=4
filetype plugin indent on

set smartindent
EOF

echo "Installed init.vim to: $TARGET"
