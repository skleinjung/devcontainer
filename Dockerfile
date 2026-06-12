FROM mcr.microsoft.com/devcontainers/base:ubuntu

ARG USERNAME

# run privileged setup as root
USER root

# Build-time package setup (the container runs with no sudo and no-new-privileges, so nothing may
# apt-install at runtime). Install gnupg2; PURGE sudo entirely — the workspace is untrusted, holds
# no sudo grant, and no-new-privileges already neuters setuid, so the binary should not exist.
# NO lastpass-cli: secret-fetching tooling belongs in the admin sidecar, not the agent container.
RUN apt-get update \
  && apt-get --no-install-recommends -yqq install gnupg2 \
  && apt-get -y purge sudo \
  && apt-get -y autoremove \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# install yq
RUN wget https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64 -O /usr/local/bin/yq &&\
    chmod +x /usr/local/bin/yq

# remove any existing regular users AND any residual sudo grant files. The base image gives its
# `vscode` user passwordless sudo via /etc/sudoers.d/vscode; userdel removes the account but not
# that file, and `apt-get purge sudo` (above) won't remove base-image-created grant files either.
# Clear /etc/sudoers.d so nothing lingers. (sudo is purged, so this is just tidiness.)
RUN getent passwd \
  | awk -F: '($3 >= 1000) && ($1 != "nobody") {print $1}' \
  | xargs -r -n 1 userdel -r \
  && rm -rf /etc/sudoers.d/*

# setup user with same name as host (unless running as root for some reason).
# NO sudo grant and NO docker group: the workspace is untrusted, runs with cap_drop ALL +
# no-new-privileges (compose), holds no docker socket, and needs no in-container root. All
# privileged setup is done here at build time as root.
RUN if [ "${USERNAME}" != "root" ]; then \
    groupadd --gid 1000 ${USERNAME} || true \
    && useradd -s /bin/bash -m -u 1000 -g 1000 ${USERNAME} \
  ; fi

# copy arbitrary files into our container filesystem
COPY rootfs/ /
COPY scripts/container/ /usr/local/bin/
RUN find /usr/local/bin -type f -exec chmod +x {} \;

# copy files into home directory, setting appropriate permissions on any .ssh files
COPY home/ /home/${USERNAME}/
RUN chown -R "${USERNAME}:${USERNAME}" /home/${USERNAME}

# Build-time privileged setup that previously ran via sudo in post-create.d (now impossible at
# runtime under no-new-privileges). All static, so it belongs in the image anyway.

# System gitconfig: github.com HTTPS auth routes to git-credential-shelf (the vended shelf token),
# host-scoped and useHttpPath so the helper can route per-org.
RUN git config --system --add 'credential.https://github.com.helper' '' \
  && git config --system --add 'credential.https://github.com.helper' '!/usr/local/bin/git-credential-shelf' \
  && git config --system 'credential.https://github.com.useHttpPath' true

# VS Code host-channel scrub for interactive terminals: the /etc/profile.d file ships via
# COPY rootfs/ above (login shells); wire /etc/bash.bashrc for interactive non-login shells.
# See SECURITY.md "two-layer env neutralization".
RUN printf '\n# Drop VS Code host-reaching channels from interactive shells (see SECURITY.md)\n. /etc/profile.d/50-scrub-vscode-git-auth.sh\n' >> /etc/bash.bashrc

# pandoc (build-time; was a sudo post-create step)
RUN PANDOC_VERSION=3.8.3 \
  && PANDOC_SHA256=c224fab89f827d3623380ecb7c1078c163c769c849a14ac27e8d3bfbb914c9b4 \
  && curl -fsSL "https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-linux-amd64.tar.gz" -o /tmp/pandoc.tar.gz \
  && echo "${PANDOC_SHA256}  /tmp/pandoc.tar.gz" | sha256sum -c - \
  && tar xzf /tmp/pandoc.tar.gz --strip-components 1 -C /usr/local/ \
  && rm /tmp/pandoc.tar.gz

# Finish any non-privileged setup
USER ${USERNAME}

# install: claude code
RUN curl -fsSL https://claude.ai/install.sh | bash

# create directories in our image which will be bind-mounted later (otherwise
# Docker will automatically create them as root-only when the container starts)
RUN mkdir -p /home/${USERNAME}/.claude \
  && mkdir -p /home/${USERNAME}/.config \
  && mkdir -p /home/${USERNAME}/.ssh \
  && chmod 700 /home/${USERNAME}/.ssh

CMD ["sleep", "infinity"]
