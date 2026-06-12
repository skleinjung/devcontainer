#!/usr/bin/env bash
set -euo pipefail

# The system gitconfig that wires github.com HTTPS auth to git-credential-shelf is baked into the
# image at build time (see Dockerfile) — it can't be written at runtime now that the container has
# no sudo / no-new-privileges.
#
# This runtime step only cleans up a stale per-repo footprint: earlier versions wired a local
# credential.helper directly on the opus checkout, which would shadow the system config. Remove
# only that exact helper (never user-set ones), in any repo directly under /workspace (which is
# bind-mounted, so only available at runtime). No sudo needed — the repos are user-owned.

OLD_HELPER='!/usr/local/bin/gh auth git-credential'
for repo in /workspace/*/.git; do
  d="${repo%/.git}"
  [ -d "$repo" ] || continue
  if git -C "$d" config --local --get-all credential.helper 2>/dev/null | grep -qxF "$OLD_HELPER"; then
    git -C "$d" config --local --unset-all credential.helper 2>/dev/null || true
  fi
done
