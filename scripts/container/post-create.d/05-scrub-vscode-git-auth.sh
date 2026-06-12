#!/usr/bin/env bash
set -euo pipefail

# Neutralize VS Code's git credential channel inside the container, so agents are confined to the
# scoped /creds shelf tokens and cannot reach the human's VS Code GitHub login (a broad personal
# OAuth token). VS Code injects GIT_ASKPASS + a VSCODE_GIT_IPC_HANDLE socket into the shells it
# spawns; any process inheriting them can ask VS Code for credentials. `git.useIntegratedAskPass:
# false` (devcontainer.json) stops the askpass injection; this scrubs the residual env vars from
# the shells agents are launched from. git/gh are unaffected — they authenticate via
# git-credential-shelf, independent of askpass. See the README "VS Code GitHub auth" section.
#
# Residual: a process launched directly by the VS Code server (not via a terminal shell that
# sources these files) could still inherit VSCODE_GIT_IPC_HANDLE and would have to speak the git
# IPC protocol to the socket directly — a much higher bar, and the easy askpass path is gone.

scrub='# Drop VS Code host-reaching channels so they are not inherited by agents (see .devcontainer
# README). Secondary to devcontainer.json remoteEnv (which covers VS Code-spawned processes); this
# covers shells started OUTSIDE VS Code, e.g. `docker exec`. SSH_AUTH_SOCK is intentionally kept.
unset GIT_ASKPASS VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_ASKPASS_EXTRA_ARGS \
      VSCODE_GIT_IPC_HANDLE VSCODE_IPC_HOOK_CLI BROWSER GPG_AGENT_INFO 2>/dev/null || true'

f=/etc/profile.d/50-scrub-vscode-git-auth.sh
printf '%s\n' "$scrub" | sudo tee "$f" >/dev/null
sudo chmod 0644 "$f"

# Login shells source /etc/profile -> profile.d; interactive non-login shells source
# /etc/bash.bashrc, which may not. Wire bash.bashrc to the same file so both are covered.
if ! sudo grep -qF '50-scrub-vscode-git-auth.sh' /etc/bash.bashrc 2>/dev/null; then
  printf '\n. %s\n' "$f" | sudo tee -a /etc/bash.bashrc >/dev/null
fi
