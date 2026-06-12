# Drop VS Code's host-reaching channels from interactive shells, so they aren't inherited by
# agents started from a terminal. devcontainer.json `remoteEnv` already blanks these for the
# processes VS Code spawns (the agent's non-interactive shells included), but VS Code RE-INJECTS
# VSCODE_GIT_IPC_HANDLE / VSCODE_IPC_HOOK_CLI / BROWSER into integrated terminals on top of
# remoteEnv — this is what cleans them there. SSH_AUTH_SOCK is intentionally kept (FIDO-gated).
# See SECURITY.md "two-layer env neutralization". (Build-time installed via Dockerfile.)
unset GIT_ASKPASS VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_ASKPASS_EXTRA_ARGS \
      VSCODE_GIT_IPC_HANDLE VSCODE_IPC_HOOK_CLI BROWSER GPG_AGENT_INFO 2>/dev/null || true
