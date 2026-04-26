#!/usr/bin/env bash
# Pod entrypoint: ensure PVC-mounted directories have correct ownership before
# supervisord launches the long-running processes.
#
# fsGroup=1000 (set by the spawner StatefulSet's pod securityContext) makes
# kubelet recursively chgrp the mounted PVCs to GID 1000 — but it does NOT
# chown to UID 1000 if files were previously created by a different UID.
# The chown -R below covers that edge case (pod restart after running with a
# different image that wrote files as a different user). On a fresh PVC the
# directories are empty and chown is a no-op.
set -e

WORKSPACE_DIR="${WORKSPACE_DIR:-/home/coder/workspace}"
HERMES_HOME="${HERMES_HOME:-/home/coder/.hermes}"

mkdir -p "$WORKSPACE_DIR" "$HERMES_HOME"
chown -R coder:coder "$WORKSPACE_DIR" "$HERMES_HOME" 2>/dev/null || true

# Platform CA — the spawner mounts the cluster's self-signed-CA ConfigMap at
# /etc/hermes/ca/. Installing it into /usr/local/share/ca-certificates/ +
# `update-ca-certificates` rebuilds /etc/ssl/certs/ca-certificates.crt so
# git/curl/python (and pretty much everything else that uses the system
# trust store) trust internal HTTPS hosts (Forgejo, Harbor, …) automatically.
if [ -f /etc/hermes/ca/ca.crt ]; then
    install -m 0644 /etc/hermes/ca/ca.crt /usr/local/share/ca-certificates/hermes-platform.crt
    update-ca-certificates 2>/dev/null || true
fi

# In-cluster kubeconfig — render the pod's ServiceAccount token into a
# regular ~/.kube/config so kubectl + terraform's kubernetes provider work
# out of the box. The token + CA come from the projected SA volume that
# kubelet mounts at /var/run/secrets/kubernetes.io/serviceaccount/. The
# resulting config has whatever powers the SA was granted — by default
# very few; cluster-admin only when the spawner emitted the
# ClusterRoleBinding (see workspace_cluster_admin_enabled).
SA_TOKEN_FILE=/var/run/secrets/kubernetes.io/serviceaccount/token
SA_CA_FILE=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
if [ -f "$SA_TOKEN_FILE" ] && [ -f "$SA_CA_FILE" ]; then
    install -d -m 0700 -o coder -g coder /home/coder/.kube
    SA_NS=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo default)
    SA_CA_B64=$(base64 -w 0 < "$SA_CA_FILE")
    SA_TOKEN=$(cat "$SA_TOKEN_FILE")
    cat > /home/coder/.kube/config <<EOF
apiVersion: v1
kind: Config
current-context: in-cluster
clusters:
- name: in-cluster
  cluster:
    server: https://kubernetes.default.svc.cluster.local
    certificate-authority-data: ${SA_CA_B64}
contexts:
- name: in-cluster
  context:
    cluster: in-cluster
    namespace: ${SA_NS}
    user: hermes
users:
- name: hermes
  user:
    token: ${SA_TOKEN}
EOF
    chmod 0600 /home/coder/.kube/config
    chown coder:coder /home/coder/.kube/config
fi

# Git credentials — when the spawner provisioned a Forgejo PAT for this
# project, GIT_HOST/GIT_USERNAME/GIT_TOKEN come in as env vars from the
# `hermes-git-creds` Secret. Translate them into ~/.git-credentials +
# `git config --global` so plain `git push` Just Works for the coder user.
# Skipped silently when env is unset (no Forgejo automation = manual setup).
if [ -n "${GIT_TOKEN:-}" ] && [ -n "${GIT_HOST:-}" ] && [ -n "${GIT_USERNAME:-}" ]; then
    GIT_CRED_FILE="/home/coder/.git-credentials"
    printf 'https://%s:%s@%s\n' "$GIT_USERNAME" "$GIT_TOKEN" "$GIT_HOST" > "$GIT_CRED_FILE"
    chmod 0600 "$GIT_CRED_FILE"
    chown coder:coder "$GIT_CRED_FILE"
    su -s /bin/sh coder -c "git config --global credential.helper store"
    su -s /bin/sh coder -c "git config --global user.name '${GIT_USERNAME}'"
    [ -n "${GIT_EMAIL:-}" ] && su -s /bin/sh coder -c "git config --global user.email '${GIT_EMAIL}'"
fi

exec /usr/bin/supervisord -n -c /etc/supervisord.conf
