# agent-workspace

Single-container "Linux pod" image for a Hermes project. Bundles
[code-server](https://github.com/coder/code-server) + hermes-agent +
hermes-webui into one container, supervised by `supervisord`.

## Architecture

```
                      ┌─────────────────────────────────────────┐
                      │         agent-workspace pod            │
                      │                                         │
   browser ──────────▶│  ┌─ workspace container ─────────────┐  │
   (code-server,      │  │ supervisord (PID 1, via tini)     │  │
    webui, agent)     │  │  ├─ code-server      :8080  coder │  │
                      │  │  ├─ hermes-agent     :8642  coder │  │
                      │  │  └─ hermes-webui     :8787  coder │  │
                      │  │                                    │  │
                      │  │  ~/workspace ◀── agentic workspace │  │
                      │  │  ~/.hermes   ◀── HERMES_HOME       │  │
                      │  └────────────────────────────────────┘  │
                      │                                         │
                      │  ┌─ docker-dind sidecar ────────────┐    │
                      │  │ dockerd on tcp://localhost:2375  │    │
                      │  └──────────────────────────────────┘    │
                      └─────────────────────────────────────────┘
```

Everything runs as the `coder` user (UID 1000) with passwordless sudo. The
user operates the entire Linux environment via code-server's file tree and
integrated terminal (xterm.js); hermes-agent works on files in the same
`~/workspace` directory.

## What's inside

- code-server `4.96.4` (downloaded as a standalone tarball)
- hermes-agent (copied from `nousresearch/hermes-agent:latest`, source +
  venv at `/opt/hermes`)
- hermes-webui (copied from `ghcr.io/nesquena/hermes-webui:latest`, source
  at `/opt/hermes-webui`)
- Dev toolchain: git, vim, tmux, zsh, ripgrep, fd, jq, build-essential,
  python3 (3.13), nodejs, npm, uv, docker CLI + buildx + compose

## Build

```bash
cd services/agent-workspace
docker build -t agent-workspace:dev .

# Pin upstream image versions:
docker build \
  --build-arg HERMES_AGENT_IMAGE=nousresearch/hermes-agent:0.11.0 \
  --build-arg HERMES_WEBUI_IMAGE=ghcr.io/nesquena/hermes-webui:0.50.205 \
  --build-arg CODE_SERVER_VERSION=4.96.4 \
  -t agent-workspace:dev .
```

## Persistence

The spawner mounts two PVCs into the container:

| PVC            | Mount path              | Contents                                  |
|----------------|-------------------------|-------------------------------------------|
| `workspace`    | `/home/coder/workspace` | Project files (the agentic workspace)     |
| `hermes-home`  | `/home/coder/.hermes`   | Agent state, sessions, webui state, etc.  |

`sudo apt install <pkg>` reverts on pod restart. To make tooling persistent:
- Edit this Dockerfile and rebuild — for system-wide tools.
- Install to `~/.local` (pipx, nvm, rustup, cargo) — survives via the
  `hermes-home` PVC if the spawner mounts a `~/.local` subpath (TODO).

## Why a single container

Earlier the spawner ran `agent`, `webui`, and `code-server` as separate
containers in the same pod. Single-container is simpler:

- One Linux environment users can `sudo` into and customize.
- Shared filesystem with no permission gymnastics (only `coder` writes).
- code-server + xterm.js becomes the operator interface for the entire
  environment, not just the editor on a shared volume.

## Why base on `debian:trixie-slim`

The upstream `hermes-agent` image ships a Python venv built against trixie's
`/usr/bin/python3` (3.13). Building on bookworm (codercom/code-server's
default) breaks the venv's compiled `.so` loads. trixie + the same
`/usr/bin/python3` keeps the venv working without a rebuild.

## Wiring from the spawner

In `infra/clusters/dev/terraform.tfvars` (or the spawner's env):

```hcl
agent_spawner_workspace_image = "agent-workspace:dev"
```

The spawner emits a single `workspace` container that exposes ports 8080
(code-server), 8642 (agent), 8787 (webui), and three `Service`s + two
`HTTPRoute`s for browser-side access.
