#!/usr/bin/env bash
set -euo pipefail

# Builds the sandboxctl Go CLI and installs it to $GOBIN (or $GOPATH/bin,
# defaulting to $HOME/go/bin). Add that directory to your PATH if it isn't
# already.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_DIR="${SCRIPT_DIR}/cli"
BIN_DIR="${GOBIN:-${GOPATH:-$HOME/go}/bin}"
BIN_PATH="${BIN_DIR}/sandboxctl"

command -v go >/dev/null 2>&1 || { echo "go is not installed" >&2; exit 1; }

mkdir -p "$BIN_DIR"
chmod +x "${SCRIPT_DIR}/sandbox.sh"

echo "==> building sandboxctl"
(
  cd "$CLI_DIR"
  go build -trimpath -ldflags "-s -w -X main.assetDir=${SCRIPT_DIR}" -o "$BIN_PATH" .
)

echo "OK: installed $BIN_PATH"
echo
case ":$PATH:" in
  *":$BIN_DIR:"*) echo "PATH already includes $BIN_DIR — run: sandboxctl up" ;;
  *) echo "WARN: $BIN_DIR is not on PATH in this shell; open a new terminal or run: source ~/.zshrc" ;;
esac
