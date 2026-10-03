#!/usr/bin/env bash
#
# Cloud Workstations startup script.
#
# Cloud Workstations executes this script as root on the workstation VM after it
# boots (referenced from the config via --startup-script-uri=gs://<bucket>/startup.sh).
# It runs on every start, so keep it idempotent and fast.
#
# Installs into the default workstation:
#   - Claude Code CLI (native installer, into the user's persistent home: ~/.local/bin)
#   - Antigravity CLI (into the user's persistent home)
#
# Tools owned by the workstation user land on the persistent /home disk and survive
# restarts; the `command -v` guards make subsequent boots no-ops.

set -euxo pipefail

# Default user inside the predefined code-oss image. Home (/home/$WS_USER) is the
# persistent disk. Override by exporting WS_USER before the script runs if needed.
WS_USER="${WS_USER:-user}"

# --- 1) Claude Code CLI (per-user, persistent) -------------------------------
# Native installer needs no Node and self-updates in the background. It installs
# to ~/.local/bin, so make sure that dir is on PATH for the workstation's
# (non-login) terminal shells, which read ~/.bashrc.
if ! runuser -u "$WS_USER" -- bash -lc 'command -v claude' >/dev/null 2>&1; then
  runuser -u "$WS_USER" -- bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'
fi
runuser -u "$WS_USER" -- bash -lc \
  'grep -qs ".local/bin" ~/.bashrc || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> ~/.bashrc'

# --- 2) Antigravity (agy) CLI (per-user, persistent) -------------------------
if ! runuser -u "$WS_USER" -- bash -lc 'command -v agy' >/dev/null 2>&1; then
  runuser -u "$WS_USER" -- bash -lc 'curl -fsSL https://antigravity.google/cli/install.sh | bash'
fi

echo "startup.sh: claude and agy provisioning complete for user '$WS_USER'."
