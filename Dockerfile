# Specialized layer on top of the toolkit `default` image. The toolkit (base+default)
# now provides: no-sudo + the unprivileged user, the VS Code host-channel scrub, the IPC
# socket reaper (reap-vscode-sockets), the credential consumer shims (devcred + the git/gh
# helpers + AWS_SHARED_CREDENTIALS_FILE), gnupg2/yq, and the keep-alive CMD. Everything
# below is project-specific: pandoc, Claude Code, the rootfs helpers (tf,
# aws-get-account-id), the home seed, and the lifecycle scripts.
FROM ghcr.io/skleinjung/devcontainers/default:latest

# The toolkit `default` image bakes its user as `vscode` (uid/gid 1000); match it.
ARG USERNAME=vscode

# Pinned tool versions (kept at the top so they're easy to see and bump).
ARG PANDOC_VERSION=3.8.3
ARG PANDOC_SHA256=c224fab89f827d3623380ecb7c1078c163c769c849a14ac27e8d3bfbb914c9b4

USER root

# pandoc
RUN curl -fsSL "https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-linux-amd64.tar.gz" -o /tmp/pandoc.tar.gz \
  && echo "${PANDOC_SHA256}  /tmp/pandoc.tar.gz" | sha256sum -c - \
  && tar xzf /tmp/pandoc.tar.gz --strip-components 1 -C /usr/local/ \
  && rm /tmp/pandoc.tar.gz

# claude code — installed as the user (to ~/.local). Kept here, ahead of the frequently-
# edited COPY layers below, so a script change doesn't re-run this network install.
USER ${USERNAME}
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root

# ── Our files (edited more often; kept late so changes don't bust the cache above) ───────
# rootfs: the tf + aws-get-account-id helpers. (The VS Code scrub and the github.com
# credential wiring now come from base — we no longer ship them here.)
COPY rootfs/ /

COPY home/ /home/${USERNAME}/
# Lifecycle scripts only (post-create/post-attach + their .d drop-ins) and gh-token-seed.
# The gh/git credential shims and the socket reaper are provided by base — not shipped here.
COPY scripts/container/ /usr/local/bin/
RUN find /usr/local/bin -type f -exec chmod +x {} \; \
  && chown -R "${USERNAME}:${USERNAME}" /home/${USERNAME}

# Pre-create dirs that get bind-mounted later (else Docker creates them root-owned at start).
USER ${USERNAME}
RUN mkdir -p /home/${USERNAME}/.claude /home/${USERNAME}/.config /home/${USERNAME}/.ssh \
  && chmod 700 /home/${USERNAME}/.ssh
