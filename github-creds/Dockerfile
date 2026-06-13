# Derived GitHub credential sidecar that bakes THIS repo's installations.json (which orgs /
# repos / perms to vend) — a reviewed rebuild, NOT a /workspace bind-mount, so changing vend
# scope is human-gated.
FROM ghcr.io/skleinjung/devcontainers/credential-shelf-github:latest
COPY installations.json /etc/credential-shelf/installations.json
