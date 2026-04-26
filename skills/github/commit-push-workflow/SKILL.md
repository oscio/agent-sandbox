---
name: commit-push-workflow
description: Commit-per-task + worktree-per-feature + always-push discipline tailored to Hermes workspace pods. Treats Forgejo as the source-of-truth — never leave work in local-only commits. Applies to plain git push (no PR ceremony) AND when the pod is feeding a downstream agent or human reviewer.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [Git, Forgejo, Workflow, Commits, Worktree, AI-Native-Dev]
    related_skills: [github-pr-workflow, codebase-inspection, spec-kit]
---

# Commit-Per-Task + Worktree + Always-Push

Workflow discipline for hermes-agent inside a workspace pod. The pod is
ephemeral; **work that lives only locally is work the next agent can't see**.
This skill bakes in three habits:

| Habit | Why |
|---|---|
| Commit per completed sub-task | Atomic units, easy to revert, clean history |
| `git worktree add` for parallel work | One branch per concern, no stash juggling |
| `git push` immediately after every commit | Forgejo = source of truth, survives pod death |

## Pre-conditions (already set up)

The spawner provisions everything below at pod creation; verify with
`git config --global --list` if you suspect an issue:

- `~/.git-credentials` populated with `https://<user>:<token>@git.dev.openschema.io`
- `git config --global credential.helper store`
- `git config --global user.name <slug>` and `user.email <slug>@noreply.local`
- Token has `write:repository` + `write:user` scopes (push + repo create)
- Platform CA installed → no `--insecure` ever needed

If any are missing, the spawner's automation isn't enabled — fall back to
the github-pr-workflow skill's manual auth section.

## Hard rules

1. **NEVER end a session with uncommitted+unpushed work.** Even WIP commits
   are fine: `git commit -m "wip: thinking about X"`. The next agent or
   human MUST be able to see what you tried.
2. **Push after every commit.** Default `origin <branch>`. Force-push only
   on a branch you yourself created in this session.
3. **One worktree per concern.** When you start a parallel concern (e.g.
   "fix bug X" while "feature Y" is in progress), use `git worktree add`,
   not `git stash`.

## Normal commit/push loop

```bash
# Inside ~/workspace/<repo> after a unit of work passes its test:
git add -A
git commit -m "feat(<area>): <one-line summary>

<optional body explaining WHY, not WHAT>

Co-Authored-By: <agent-id> <agent-email>"
git push
```

The `Co-Authored-By:` trailer is how multi-agent attribution flows: even
when the pusher is you (the project's git identity), the trailer surfaces
which agent did the work. If you're aware of an upstream agent that
delegated to you, add their trailer too.

## First push to a brand-new repo

The pod's GIT_TOKEN can create repos (`write:user` scope). Use that
instead of asking a human:

```bash
# Create remote on Forgejo
curl -fsS -H "Authorization: token $GIT_TOKEN" \
     -H "Content-Type: application/json" \
     -d "{\"name\": \"$REPO\", \"private\": true}" \
     "https://$GIT_HOST/api/v1/user/repos" >/dev/null

# Wire up + first push
git remote add origin "https://$GIT_HOST/$GIT_USERNAME/$REPO.git"
git push -u origin main
```

The repo URL is then `https://git.dev.openschema.io/$GIT_USERNAME/$REPO`.

## Worktree pattern (parallel concerns)

`git stash` is a code smell — it loses context, can't be checkpointed, and
the next agent sees nothing. Use worktrees instead:

```bash
# In your main worktree (e.g. ~/workspace/myapp on branch `main`)
# Spin up a parallel branch in its own working directory:
git worktree add ../myapp-fix-bug-123 -b fix/bug-123

# Switch dirs and work; commits go to fix/bug-123 in isolation
cd ../myapp-fix-bug-123
# ... edits, tests, commit, push
git push -u origin fix/bug-123

# When done, remove the worktree
git worktree remove ../myapp-fix-bug-123
```

Branch naming: `<type>/<slug>` — types `feat`, `fix`, `refactor`, `chore`,
`spec` (when paired with the spec-kit skill).

## Sanity check before ending a session

```bash
# Anything uncommitted?
git -C ~/workspace/<repo> status --short
# Unpushed commits on current branch?
git -C ~/workspace/<repo> log --branches --not --remotes --oneline
# Untouched worktrees with WIP?
git worktree list --porcelain
```

If any of those produce output, **commit + push before exiting**. Even a
`wip:` commit beats losing the work to pod GC.

## When push fails

- `403 Push to create is not enabled` — repo doesn't exist; create via API
  block above first.
- `403` after that — token scope issue; expected `write:repository` +
  `write:user`. The spawner provisions both; if a stale token is around
  (Secret cache), `kubectl rollout restart` the workspace pod to refresh.
- `fatal: unable to access` with TLS error — platform CA isn't installed.
  Workspace pod's start.sh runs `update-ca-certificates`; if you got a
  custom-mounted CA bundle wrong, restart the pod.

## What this skill is NOT

- Not a substitute for PR review when shipping to a shared branch — for
  that workflow see `github-pr-workflow` (works against Forgejo too,
  Forgejo is GitHub-API compatible).
- Not for binary blobs / large files — use git-lfs for those, otherwise
  Forgejo's storage balloons.
- Not for secrets — never commit `.env`, tokens, kubeconfigs. The CA in
  `~/.kube/config` is project-scoped and shouldn't leak.
