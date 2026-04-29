# agent-sandbox

Single-container "Linux pod" workspace image. Bundles
[code-server](https://github.com/coder/code-server) + ttyd into one
container, supervised by `supervisord`.

## Architecture

```
                      ┌─────────────────────────────────────────┐
                      │           agent-sandbox pod             │
                      │                                         │
   browser ──────────▶│  ┌─ workspace container ─────────────┐  │
   (code-server,      │  │ supervisord (PID 1, via tini)     │  │
    ttyd)             │  │  ├─ code-server  :8080  coder     │  │
                      │  │  └─ ttyd         :7681  coder     │  │
                      │  │                                   │  │
                      │  │  ~/workspace ◀── project files    │  │
                      │  └───────────────────────────────────┘  │
                      │                                         │
                      │  ┌─ docker-dind sidecar ────────────┐   │
                      │  │ dockerd on tcp://localhost:2375  │   │
                      │  └──────────────────────────────────┘   │
                      └─────────────────────────────────────────┘
```

Everything runs as the `coder` user (UID 1000) with passwordless sudo. The
user operates the entire Linux environment via code-server's file tree and
integrated terminal (xterm.js) or via the standalone ttyd shell URL.

## What's inside

- code-server `4.96.4` (downloaded as a standalone tarball)
- ttyd `1.7.7` (raw xterm.js → bash bridge on port 7681)
- Dev toolchain: git, vim, tmux, zsh, ripgrep, fd, jq, build-essential,
  python3 (3.13), nodejs, npm, uv, docker CLI + buildx + compose
- terraform + kubectl (workspace can act as the operator console when
  granted cluster-admin via the spawner)

## Build

```bash
cd services/agent-sandbox
docker build -t agent-sandbox:dev .

# Pin code-server version:
docker build \
  --build-arg CODE_SERVER_VERSION=4.96.4 \
  -t agent-sandbox:dev .
```

The desktop variant (`Dockerfile.desktop`) layers XFCE + KasmVNC on top:

```bash
docker build --build-arg SANDBOX_BASE=agent-sandbox:dev \
             -t agent-sandbox-desktop:dev \
             -f Dockerfile.desktop .
```

## Persistence

The spawner mounts a `workspace` PVC at `/home/coder/workspace`. Project
files persist across pod restarts; everything outside that path is
ephemeral.

`sudo apt install <pkg>` reverts on pod restart. To make tooling persistent:
- Edit this Dockerfile and rebuild — for system-wide tools.
- Install to `~/workspace/.local` (or any subpath of the workspace PVC) and
  add it to PATH in `~/workspace/.bashrc`.

## Why a single container

One Linux environment users can `sudo` into and customize. Shared
filesystem with no permission gymnastics (only `coder` writes).
code-server + xterm.js becomes the operator interface for the entire
environment, not just the editor on a shared volume.

## Wiring from the spawner

The console module's VM service emits a StatefulSet using this image
and exposes ports 7681 (ttyd), 8080 (code-server), and 6901 (KasmVNC,
desktop variant only) via per-host HTTPRoutes.
