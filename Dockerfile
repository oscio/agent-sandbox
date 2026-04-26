# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# agent-workspace — single-container "Linux pod" for a Hermes project.
#
# Combines into one image:
#   * code-server (browser VSCode + xterm.js terminal) — operator interface
#   * hermes-agent (gateway on :8642)                  — agent runtime
#   * hermes-webui (UI on :8787)                       — agent web UI
#
# All three processes are managed by supervisord and run as the `coder`
# user (UID 1000), which has passwordless sudo. The agentic workspace lives
# at ~/workspace (= /home/coder/workspace) and is shared across the whole
# environment — the user operates files in code-server's tree + integrated
# terminal, hermes-agent runs against the same files.
#
# Docker daemon comes from a separate `docker-dind` sidecar in the same pod;
# this image only ships the docker CLI (DOCKER_HOST=tcp://localhost:2375).
#
# Base MUST be Debian trixie because the upstream hermes-agent image ships a
# venv built against trixie's python3.13 (`/usr/bin/python3`). Building on
# bookworm breaks the venv's .so loads.
# ---------------------------------------------------------------------------

ARG HERMES_AGENT_IMAGE=nousresearch/hermes-agent:latest
ARG HERMES_WEBUI_IMAGE=ghcr.io/nesquena/hermes-webui:latest
ARG CODE_SERVER_VERSION=4.96.4

FROM ${HERMES_AGENT_IMAGE} AS agent-src
FROM ${HERMES_WEBUI_IMAGE} AS webui-src

FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG CODE_SERVER_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        sudo ca-certificates gnupg lsb-release locales tini supervisor \
        vim nano less man-db tmux zsh bash-completion \
        git git-lfs openssh-client curl wget rsync \
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

# Terraform + kubectl. Workspace pods bind to cluster-admin (opt-in via the
# spawner's `workspace_cluster_admin_enabled` flag) so the agent or user
# can run `terraform apply` directly against this same cluster — useful for
# solo dev where the workspace IS the operator console. State backend
# choice (kubernetes-secret / postgres / S3 / local) is left to the user's
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
RUN groupadd --gid 1000 coder \
 && useradd --uid 1000 --gid 1000 --shell /bin/bash --create-home coder \
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

# Agent: source + venv. The venv's python symlinks resolve to /usr/bin/python3
# (trixie's 3.13), which we have in this base — venv runs as-is.
COPY --from=agent-src /opt/hermes /opt/hermes
RUN chown -R coder:coder /opt/hermes

# Custom skills baked on top of the upstream bundle. Each subdir under
# `skills/` is a category (github, devops, ...); inside it each
# `<skill>/SKILL.md` is a manifest. The agent's skills_sync.py runs at
# pod first boot and copies these into ~/.hermes/skills/ exactly like
# the upstream-bundled ones.
COPY skills/ /opt/hermes/skills/
RUN chown -R coder:coder /opt/hermes/skills

# GitHub Spec Kit CLI — `specify init <project>` bootstraps a directory
# with templates + slash-command stubs the agent recognizes (/specify,
# /plan, /tasks, /implement). See skills/github/spec-kit/SKILL.md for
# the workflow. `--break-system-packages` is required on trixie because
# /usr/bin/python3 is marked externally-managed.
RUN python3 -m pip install --break-system-packages --no-cache-dir \
        git+https://github.com/github/spec-kit.git \
 && specify --version 2>&1 | head -1

# WebUI: re-rooted from upstream's /apptoo to /opt/hermes-webui so paths are
# self-explanatory and parallel /opt/hermes (the agent). The webui runs against
# the agent's venv (see supervisord.conf hermes-webui.command) — that venv
# already has pyyaml + everything else webui needs, no separate install.
COPY --from=webui-src /apptoo /opt/hermes-webui
RUN chown -R coder:coder /opt/hermes-webui

COPY supervisord.conf /etc/supervisord.conf
COPY start.sh /usr/local/bin/agent-workspace-start
COPY agent-bootstrap.sh /usr/local/bin/hermes-agent-bootstrap
RUN chmod +x /usr/local/bin/agent-workspace-start /usr/local/bin/hermes-agent-bootstrap

ENV DOCKER_HOST=tcp://localhost:2375
ENV HERMES_HOME=/home/coder/.hermes
ENV WORKSPACE_DIR=/home/coder/workspace

EXPOSE 7681 8080 8642 8787

WORKDIR /home/coder
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/agent-workspace-start"]
