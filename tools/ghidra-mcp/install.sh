#!/bin/sh
# Installs bethington/ghidra-mcp for the user's Ghidra 12.1.4 (Homebrew formula).
# Uses the upstream release assets: the extension zip stamped for 12.1.4 and the bridge wheel.
# Everything lands in ~/.local/share/ghidra-mcp so it outlives task worktrees.
# Idempotent. The GUI steps (restart Ghidra, enable the plugin) are in docs/ghidra-mcp.md.
set -eu

TAG="${GHIDRA_MCP_TAG:-v7.0.0-rc.3}"
GHIDRA="${GHIDRA_INSTALL_DIR:-/opt/homebrew/opt/ghidra/libexec}"
GVER=$(sed -n 's/^application.version=//p' "$GHIDRA/Ghidra/application.properties")
ROOT="$HOME/.local/share/ghidra-mcp"
DL="$ROOT/dl-${TAG#v}"
EXT_DIR="$HOME/Library/ghidra/ghidra_${GVER}_PUBLIC/Extensions"
URL="https://github.com/bethington/ghidra-mcp/releases/download/$TAG"
ZIP="GhidraMCP-${TAG#v}.zip"
WHL="ghidra_mcp_bridge-$(echo "${TAG#v}" | sed 's/-.*//')-py3-none-any.whl"

mkdir -p "$DL"
[ -f "$DL/$ZIP" ] || curl -fsSL -o "$DL/$ZIP" "$URL/$ZIP"
[ -f "$DL/$WHL" ] || curl -fsSL -o "$DL/$WHL" "$URL/$WHL"

STAMP=$(unzip -p "$DL/$ZIP" GhidraMCP/extension.properties | sed -n 's/^version=//p')
[ "$STAMP" = "$GVER" ] || { echo "extension is stamped for Ghidra $STAMP, installed Ghidra is $GVER" >&2; exit 1; }
mkdir -p "$EXT_DIR" && rm -rf "$EXT_DIR/GhidraMCP" && unzip -q -o "$DL/$ZIP" -d "$EXT_DIR"

[ -x "$ROOT/venv/bin/python" ] || uv venv -q -p 3.12 "$ROOT/venv"
uv pip install -q --reinstall -p "$ROOT/venv/bin/python" "$DL/$WHL"

cat > "$ROOT/run-bridge.sh" <<'SH'
#!/bin/sh
# Stdio MCP bridge -> GhidraMCP plugin HTTP server inside the running Ghidra GUI.
export GHIDRA_MCP_URL="${GHIDRA_MCP_URL:-http://127.0.0.1:8089}"
exec "$HOME/.local/share/ghidra-mcp/venv/bin/bridge-mcp-ghidra" --transport stdio "$@"
SH
chmod +x "$ROOT/run-bridge.sh"
echo "Installed: extension -> $EXT_DIR/GhidraMCP, bridge -> $ROOT/run-bridge.sh"
