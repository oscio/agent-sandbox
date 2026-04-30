# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# agent-sandbox — single-container "Linux pod" workspace image.
#
# Combines into one image:
#   * code-server (browser VSCode + xterm.js terminal) — operator interface
#   * ttyd        (standalone xterm.js shell on :7681) — raw terminal URL
#
# Both processes are managed by supervisord and run as the `coder`
# user (UID 1000), which has passwordless sudo. The workspace lives at
# ~/workspace (= /home/coder/workspace) — code-server's file tree and
# integrated terminal both operate against the same directory.
#
# Docker daemon comes from a separate `docker-dind` sidecar in the same pod;
# this image only ships the docker CLI (DOCKER_HOST=tcp://localhost:2375).
# ---------------------------------------------------------------------------

ARG CODE_SERVER_VERSION=4.96.4

FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG CODE_SERVER_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        sudo ca-certificates gnupg lsb-release locales tini supervisor \
        vim nano less man-db tmux zsh bash-completion \
        git git-lfs openssh-client openssh-server curl wget rsync \
        ripgrep fd-find jq tree \
        unzip zip tar \
        build-essential pkg-config libssl-dev \
        python3 python3-pip python3-venv python3-dev \
        nodejs npm \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd

RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL=/usr/local/bin sh \
 && uv --version

# ttyd — standalone xterm.js → bash bridge. Not in Debian trixie's apt repo,
# so pull the static release binary from GitHub.
ARG TTYD_VERSION=1.7.7
RUN ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in \
        amd64) TTYD_ARCH=x86_64 ;; \
        arm64) TTYD_ARCH=aarch64 ;; \
        *) echo "unsupported arch $ARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
        -o /usr/local/bin/ttyd \
 && chmod +x /usr/local/bin/ttyd \
 && ttyd --version

# Terraform + kubectl. Workspace pods can bind to cluster-admin (opt-in via
# the platform's `sandbox_cluster_admin_enabled` flag) so the user can run
# `terraform apply` directly against this same cluster — useful for solo dev
# where the workspace IS the operator console. State backend choice
# (kubernetes-secret / postgres / S3 / local) is left to the user's
# terraform code; the pod just provides the binaries + creds.
ARG TF_VERSION=1.10.4
ARG KUBECTL_VERSION=v1.31.4
RUN ARCH="$(dpkg --print-architecture)" \
 && curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${ARCH}.zip" -o /tmp/terraform.zip \
 && unzip /tmp/terraform.zip -d /usr/local/bin/ \
 && rm /tmp/terraform.zip \
 && terraform -version | head -1 \
 && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl \
 && chmod +x /usr/local/bin/kubectl \
 && kubectl version --client | head -1

# Docker CLI + buildx + compose plugin (no daemon — provided by sidecar).
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        docker-ce-cli docker-buildx-plugin docker-compose-plugin \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

RUN sed -i 's/# *\(en_US.UTF-8\)/\1/' /etc/locale.gen \
 && locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

# Single login user. UID 1000 is what fsGroup pins on the workspace PVC.
# `usermod -p '*'` unlocks the account so ssh key auth works — the
# default `useradd` puts `!` in /etc/shadow which sshd treats as
# "account locked" and refuses even valid pubkey auth ("User coder
# not allowed because account is locked"). `*` means "no password
# set" but the account is not locked, so key auth still goes through.
RUN groupadd --gid 1000 coder \
 && useradd --uid 1000 --gid 1000 --shell /bin/bash --create-home coder \
 && usermod -p '*' coder \
 && echo 'coder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-coder \
 && chmod 0440 /etc/sudoers.d/90-coder

# code-server standalone tarball — works on any glibc Linux, doesn't depend on
# a particular Debian release.
RUN ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in \
        amd64) TARBALL_ARCH=amd64 ;; \
        arm64) TARBALL_ARCH=arm64 ;; \
        *) echo "unsupported arch $ARCH" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-${TARBALL_ARCH}.tar.gz" \
        -o /tmp/code-server.tar.gz \
 && mkdir -p /usr/local/lib/code-server \
 && tar -C /usr/local/lib/code-server --strip-components=1 -xzf /tmp/code-server.tar.gz \
 && rm /tmp/code-server.tar.gz \
 && ln -s /usr/local/lib/code-server/bin/code-server /usr/local/bin/code-server

COPY supervisord.conf /etc/supervisord.conf
COPY start.sh /usr/local/bin/agent-sandbox-start
RUN chmod +x /usr/local/bin/agent-sandbox-start

# sshd config for sidecar SSH shim. Listens on :22 (pod-internal),
# only key auth, no password. authorized_keys is mounted in by the
# spawner from /etc/agent-ssh/authorized_keys (Secret); start.sh
# stages it into /home/coder/.ssh/authorized_keys with right perms.
RUN mkdir -p /run/sshd /etc/ssh \
 && sed -i \
        -e 's/^#\?\(PermitRootLogin\) .*/\1 no/' \
        -e 's/^#\?\(PasswordAuthentication\) .*/\1 no/' \
        -e 's/^#\?\(PubkeyAuthentication\) .*/\1 yes/' \
        -e 's/^#\?\(KbdInteractiveAuthentication\) .*/\1 no/' \
        -e 's/^#\?\(ChallengeResponseAuthentication\) .*/\1 no/' \
        -e 's/^#\?\(UsePAM\) .*/\1 no/' \
        /etc/ssh/sshd_config

ENV DOCKER_HOST=tcp://localhost:2375
ENV WORKSPACE_DIR=/home/coder/workspace

EXPOSE 22 7681 8080

WORKDIR /home/coder
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/agent-sandbox-start"]
