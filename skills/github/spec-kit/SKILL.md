---
name: spec-kit
description: GitHub Spec Kit's spec-driven development workflow — turn a one-line idea into runnable code through /specify → /plan → /tasks → /implement, each stage producing a reviewable artifact in `.specify/` before code is written.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [Spec-Driven, Planning, GitHub, Workflow, AI-Native-Dev]
    related_skills: [github-pr-workflow, codebase-inspection]
---

# GitHub Spec Kit (Spec-Driven Development)

Spec-Driven Development workflow from GitHub. Replaces ad-hoc "ask the
agent to write code" with a four-phase pipeline that surfaces design
decisions as reviewable artifacts BEFORE any code lands.

| Phase | Slash command | Output | Review what |
|---|---|---|---|
| Specify | `/specify <idea>` | `specs/<feature>/spec.md` | Intent, scope, user-visible behavior |
| Plan | `/plan` | `plan.md` | Tech stack, file/module layout, contracts |
| Tasks | `/tasks` | `tasks.md` | Ordered, testable units of work |
| Implement | `/implement` | code + tests | Walks tasks.md top-down, marking each done |

The CLI is pre-installed in the workspace image as `specify` (`/usr/local/bin/specify`).

## When to use

- Greenfield feature where the design isn't obvious — surface tradeoffs
  in `plan.md` before locking them into code.
- Multi-file refactor that needs an explicit ordering — `tasks.md` is
  resumable on partial failure.
- Anytime you want to review intent and design BEFORE implementation,
  with each artifact small enough to read in one sitting.

Skip it for one-line bugfixes; the ceremony costs more than it saves.

## Bootstrap a project

```bash
specify init my-feature
cd my-feature
```

Creates `.specify/` with templates, memory, and command stubs. Add it to
git so the workflow is reproducible.

## Slash command details

### `/specify <one-liner>`

Drafts `specs/<feature>/spec.md` from a one-line description. Focuses on
**user-facing behavior** — no tech stack choices, no API signatures.

Iterate cheaply: edit the draft until intent is clear before moving on.

### `/plan`

Reads `spec.md`, produces `plan.md` covering:

- Chosen tech stack (with reasoning)
- File/module layout
- External contracts (API endpoints, DB schemas, etc.)
- Open questions / risks

Edit `plan.md` to push back on choices BEFORE `/tasks` decomposes them.

### `/tasks`

Decomposes `plan.md` into `tasks.md` — an ordered list, each task with:

- Acceptance test
- Dependencies on prior tasks
- Estimated touch (file paths)

Tasks the engine identifies as parallel-safe are marked `[P]`.

### `/implement`

Walks `tasks.md` top-down, writes code/tests for each, marks tasks
complete as it goes. **Stops on test failure** — doesn't push through.
Re-running picks up at the first incomplete task, so it's
checkpoint-friendly.

## Tips

- Keep `spec.md` short (~1 page). The agent fills in detail at `/plan` time.
- Edit each artifact before moving on — that's the whole point. The
  effort balance: cheap edits in markdown vs. expensive edits in code.
- For `/implement` on long task lists, run it once, review the diff,
  re-run to continue. The agent reads the existing `tasks.md` checkboxes.
- Want to drop into a sub-feature mid-implementation? Run `/specify`
  again with a new feature name; each spec is its own subdirectory under
  `specs/`.

## References

- Repo: https://github.com/github/spec-kit
- Blog: https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai/
