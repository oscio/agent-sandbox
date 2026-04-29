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

mkdir -p "$WORKSPACE_DIR"
chown -R coder:coder "$WORKSPACE_DIR" 2>/dev/null || true

# sidecar SSH shim auth — when the spawner mounts an agent's public
# key at /etc/agent-ssh/authorized_keys, install it as coder's
# authorized_keys so the sidecar can ssh in over localhost. Skipped
# silently when the mount isn't present (= VM mode without agent).
if [ -f /etc/agent-ssh/authorized_keys ]; then
    install -d -m 0700 -o coder -g coder /home/coder/.ssh
    install -m 0600 -o coder -g coder /etc/agent-ssh/authorized_keys \
        /home/coder/.ssh/authorized_keys
fi
# sshd needs host keys; first boot generates them under /etc/ssh.
ssh-keygen -A 2>/dev/null || true

# Platform CA — when the spawner mounts the cluster's self-signed-CA
# ConfigMap at /etc/platform-ca/, install it into
# /usr/local/share/ca-certificates/ + `update-ca-certificates` so
# git/curl/python (and pretty much everything else that uses the system
# trust store) trust internal HTTPS hosts (Forgejo, Harbor, …) automatically.
if [ -f /etc/platform-ca/ca.crt ]; then
    install -m 0644 /etc/platform-ca/ca.crt /usr/local/share/ca-certificates/platform-ca.crt
    update-ca-certificates 2>/dev/null || true
fi

# In-cluster kubeconfig — render the pod's ServiceAccount token into a
# regular ~/.kube/config so kubectl + terraform's kubernetes provider work
# out of the box. The token + CA come from the projected SA volume that
# kubelet mounts at /var/run/secrets/kubernetes.io/serviceaccount/. The
# resulting config has whatever powers the SA was granted — by default
# very few; cluster-admin only when the spawner emitted the
# ClusterRoleBinding (see sandbox_cluster_admin_enabled).
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
    user: coder
users:
- name: coder
  user:
    token: ${SA_TOKEN}
EOF
    chmod 0600 /home/coder/.kube/config
    chown coder:coder /home/coder/.kube/config
fi

# Git credentials — when the spawner provisioned a Forgejo PAT for this
# project, GIT_HOST/GIT_USERNAME/GIT_TOKEN come in as env vars from a
# git-creds Secret. Translate them into ~/.git-credentials +
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
