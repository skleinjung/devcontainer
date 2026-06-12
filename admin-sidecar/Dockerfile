# Admin sidecar (https://github.com/twin-digital/opus/issues/164 context): the human's
# privileged environment — SSO sessions, personal GitHub identity, and tooling used with
# elevated credentials (aws, gh, lpass, ansible, terraform). The agent workspace container
# never sees this container's home volume; it only reads the narrow credentials that vend
# scripts (bin/) publish to the shared /creds shelf. Entry is
# `docker exec -it admin-sidecar bash` from a HOST terminal (or VS Code "Attach to Running
# Container") — no sshd, no baked-in keys: access to the host Docker daemon is the access
# control.
FROM mcr.microsoft.com/devcontainers/base:ubuntu

ARG USERNAME

# ansible/lastpass-cli/jq from Ubuntu; gh/terraform from vendor apt repos; AWS CLI v2 from the
# official installer (apt ships v1, which lacks the SSO flows the vend scripts need); yq
# (mikefarah) from GitHub releases (Ubuntu's `yq` package is the incompatible Python one and the
# dotfiles aws helpers use mikefarah syntax).
RUN apt-get update \
  && apt-get install -y --no-install-recommends ansible jq lastpass-cli openssh-client unzip \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
  && curl -fsSL https://apt.releases.hashicorp.com/gpg \
       | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $VERSION_CODENAME) main" \
       > /etc/apt/sources.list.d/hashicorp.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh terraform \
  && rm -rf /var/lib/apt/lists/*

RUN arch=$(dpkg --print-architecture) \
  && case "$arch" in amd64) a=x86_64 ;; arm64) a=aarch64 ;; *) echo "unsupported arch: $arch" >&2; exit 1 ;; esac \
  && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${a}.zip" -o /tmp/awscli.zip \
  && unzip -q /tmp/awscli.zip -d /tmp \
  && /tmp/aws/install \
  && rm -rf /tmp/aws /tmp/awscli.zip \
  && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)" \
       -o /usr/local/bin/yq \
  && chmod 0755 /usr/local/bin/yq

COPY bin/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/vend-*

# Which GitHub App installations to vend (one loop per entry; see vend-daemon). Baked into the
# image, NOT bind-mounted from the agent-writable /workspace, so changing vend scope is a
# human-reviewed rebuild — the same gate as the rest of this config.
COPY github-installations.json /etc/admin-sidecar/github-installations.json

# Match the workspace container's uid/gid so files touched on the shared /workspace and /creds
# mounts stay owned by the host user. The devcontainers base image ships a 'vscode' user at
# uid 1000; rename it rather than fight over the uid.
RUN if [ "${USERNAME}" != "vscode" ]; then \
      usermod -l "${USERNAME}" -d "/home/${USERNAME}" -m vscode \
      && groupmod -n "${USERNAME}" vscode \
      && echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USERNAME}" \
      && chmod 0440 "/etc/sudoers.d/${USERNAME}"; \
    fi

# Seed /creds ownership so a fresh shelf volume initializes writable by the vend scripts.
RUN mkdir -p /creds && chown "${USERNAME}" /creds

USER ${USERNAME}
WORKDIR /home/${USERNAME}
