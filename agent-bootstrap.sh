#!/usr/bin/env bash
# Bootstrap HERMES_HOME with config templates if missing, then exec hermes.
#
# Stripped-down version of the upstream /opt/hermes/docker/entrypoint.sh —
# we drop its gosu/UID-remap logic because supervisord already launches us as
# `coder` (UID 1000), the only user in this image.
set -e

HERMES_HOME="${HERMES_HOME:-/home/coder/.hermes}"
INSTALL_DIR="${INSTALL_DIR:-/opt/hermes}"

mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home}

if [ ! -f "$HERMES_HOME/.env" ] && [ -f "$INSTALL_DIR/.env.example" ]; then
    cp "$INSTALL_DIR/.env.example" "$HERMES_HOME/.env"
fi
if [ ! -f "$HERMES_HOME/config.yaml" ] && [ -f "$INSTALL_DIR/cli-config.yaml.example" ]; then
    cp "$INSTALL_DIR/cli-config.yaml.example" "$HERMES_HOME/config.yaml"
fi
if [ ! -f "$HERMES_HOME/SOUL.md" ] && [ -f "$INSTALL_DIR/docker/SOUL.md" ]; then
    cp "$INSTALL_DIR/docker/SOUL.md" "$HERMES_HOME/SOUL.md"
fi

if [ -d "$INSTALL_DIR/skills" ] && [ -f "$INSTALL_DIR/tools/skills_sync.py" ]; then
    "$INSTALL_DIR/.venv/bin/python3" "$INSTALL_DIR/tools/skills_sync.py" || true
fi

# shellcheck disable=SC1091
source "$INSTALL_DIR/.venv/bin/activate"
exec hermes "$@"
