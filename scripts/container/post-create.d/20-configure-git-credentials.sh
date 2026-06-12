#!/usr/bin/env bash
set -euo pipefail

# Wire git to authenticate GitHub over HTTPS using the admin-sidecar-vended App tokens, routed
# per-org by git-credential-shelf. Applies to ANY github.com checkout in this container (terminal
# and agents alike) — clone over HTTPS so git uses these tokens; an SSH clone would use your own
# keys/agent instead.
#
# Written to the SYSTEM gitconfig (not the user's tracked dotfiles, not per-repo): host-scoped to
# github.com so other hosts' helpers (e.g. the VS Code credential proxy) are untouched, and
# useHttpPath so git passes owner/repo and the helper can route on the org. Idempotent.

sudo git config --system --unset-all 'credential.https://github.com.helper' 2>/dev/null || true
sudo git config --system --add 'credential.https://github.com.helper' ''
sudo git config --system --add 'credential.https://github.com.helper' '!/usr/local/bin/git-credential-shelf'
sudo git config --system 'credential.https://github.com.useHttpPath' true

# Clean up this script's old per-repo footprint: earlier versions wired a local credential.helper
# directly on the opus checkout, which would shadow the system config above. Remove only that
# exact helper (never user-set ones), in any repo directly under /workspace, so the host-scoped
# system helper governs uniformly.
OLD_HELPER='!/usr/local/bin/gh auth git-credential'
for repo in /workspace/*/.git; do
  d="${repo%/.git}"
  [ -d "$repo" ] || continue
  if git -C "$d" config --local --get-all credential.helper 2>/dev/null | grep -qxF "$OLD_HELPER"; then
    git -C "$d" config --local --unset-all credential.helper 2>/dev/null || true
  fi
done
