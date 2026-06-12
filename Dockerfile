FROM mcr.microsoft.com/devcontainers/base:ubuntu

ARG USERNAME

# Pinned tool versions (kept at the top so they're easy to see and bump).
ARG YQ_VERSION=v4.53.3
ARG PANDOC_VERSION=3.8.3
ARG PANDOC_SHA256=c224fab89f827d3623380ecb7c1078c163c769c849a14ac27e8d3bfbb914c9b4

USER root

# ── Build-time package + binary setup ────────────────────────────────────────
# The container runs with no sudo and no-new-privileges, so nothing may apt-install at runtime —
# everything is installed here. Install gnupg2; PURGE sudo and zsh: the workspace is untrusted and
# uses neither (no sudo grant, no-new-privileges neuters setuid; we use bash, not zsh).
# These layers are kept BEFORE the COPY layers below so editing a script doesn't bust their cache.
RUN export SUDO_FORCE_REMOVE=yes \
  && apt-get update \
  && apt-get --no-install-recommends -yqq install gnupg2 \
  && apt-get -y purge sudo zsh \
  && apt-get -y autoremove \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# yq
RUN wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -O /usr/local/bin/yq \
  && chmod +x /usr/local/bin/yq

# pandoc
RUN curl -fsSL "https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-linux-amd64.tar.gz" -o /tmp/pandoc.tar.gz \
  && echo "${PANDOC_SHA256}  /tmp/pandoc.tar.gz" | sha256sum -c - \
  && tar xzf /tmp/pandoc.tar.gz --strip-components 1 -C /usr/local/ \
  && rm /tmp/pandoc.tar.gz

# Remove the base image's regular users and any residual sudo grant files (the base gives its
# `vscode` user passwordless sudo via /etc/sudoers.d/vscode; userdel removes the account but not
# that file, and purging sudo doesn't remove base-created grant files). Then create our user as a
# plain unprivileged account named after the host user.
RUN getent passwd \
    | awk -F: '($3 >= 1000) && ($1 != "nobody") {print $1}' \
    | xargs -r -n 1 userdel -r \
  && rm -rf /etc/sudoers.d/* \
  && if [ "${USERNAME}" != "root" ]; then \
       groupadd --gid 1000 "${USERNAME}" || true \
       && useradd -s /bin/bash -m -u 1000 -g 1000 "${USERNAME}"; \
     fi

# System gitconfig: github.com HTTPS auth routes to git-credential-shelf (the vended shelf token),
# host-scoped and useHttpPath so the helper can route per-org. --unset-all first keeps it
# deterministic (no duplicate / chained helpers) regardless of base-image defaults or re-runs.
RUN git config --system --unset-all 'credential.https://github.com.helper' 2>/dev/null || true; \
    git config --system --add 'credential.https://github.com.helper' '' \
  && git config --system --add 'credential.https://github.com.helper' '!/usr/local/bin/git-credential-shelf' \
  && git config --system 'credential.https://github.com.useHttpPath' true \
  && git config --system core.editor nano

# claude code — installed as the user (to ~/.local). Kept here, ahead of the frequently-edited
# COPY layers below, so a script change doesn't re-run this network install.
USER ${USERNAME}
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root

# ── Our files (edited more often; kept late so changes don't bust the cache above) ───────────────
COPY rootfs/ /

# Wire /etc/bash.bashrc to the scrub shipped in rootfs (/etc/profile.d/50-scrub-vscode-git-auth.sh)
# so interactive non-login shells source it too. See SECURITY.md "two-layer env neutralization".
RUN printf '\n# Drop VS Code host-reaching channels from interactive shells (see SECURITY.md)\n. /etc/profile.d/50-scrub-vscode-git-auth.sh\n' >> /etc/bash.bashrc

COPY home/ /home/${USERNAME}/
COPY scripts/container/ /usr/local/bin/
RUN find /usr/local/bin -type f -exec chmod +x {} \; \
  && chown -R "${USERNAME}:${USERNAME}" /home/${USERNAME}

# Pre-create dirs that get bind-mounted later (else Docker creates them root-owned at start).
USER ${USERNAME}
RUN mkdir -p /home/${USERNAME}/.claude /home/${USERNAME}/.config /home/${USERNAME}/.ssh \
  && chmod 700 /home/${USERNAME}/.ssh

CMD ["sleep", "infinity"]
