# AGENTS.md: bluesky-social/.github

Public, shared GitHub Actions reusable workflows, release-gate scripts, and
Renovate presets for `bluesky-social` repositories. Consumers across the org
pin them, so a bug here is a bug in every consumer. `README.md` has the
catalog and caller snippets.

## The floating `@v1` contract

- Consumers pin `@v1` (workflows) and `#v1` (Renovate presets). Non-breaking
  changes land on `main` and then move `v1`.
- Moving `v1` is a force-push (`git tag -f v1 <sha> && git push -f origin
  v1`, the usual floating-major pattern). **The operator runs it.** An agent
  proposes the exact commands and never moves or deletes a tag itself.
- Interface changes are breaking: renaming, removing, or retyping an input,
  secret, or output; changing a default; changing a reusable workflow's
  permissions; renaming a job whose check name callers require. Breaking
  changes cut `v2` and get a README note. They never move `v1`.
- Renovate preset changes reach every consumer on its next Renovate run.
  Treat a change to what automerges as a policy change, not a tweak.

## Nothing internal lands here

This repository is public, and so are its pull requests, issues, run logs,
and commit messages. Do not add internal hostnames, account IDs, ARNs,
private repository names, people's names, internal links, or references to
private plans. The exceptions are the gateway URL default in the Claude
reusables and the self-hosted runner labels in `security.yml`.

Pieces coupled to private infrastructure, such as image builds, deploys,
self-hosted runner retries, and internal reporting, live in the internal
`bluesky-social/.github-private`. If a change needs those, it belongs there.

This repository deliberately has no community-health files (SECURITY.md,
CODE_OF_CONDUCT.md, CONTRIBUTING.md, SUPPORT.md, issue or pull request
templates, FUNDING.yml, or `profile/README.md`) at its root, in `.github/`,
or in `docs/`. In a public `.github` they become defaults for every public
repository in the org. Adding one is a separate org decision.

## The Claude reusables

`claude-review.yml` and `claude-mention.yml` wrap
`anthropics/claude-code-action`. In June 2026 the org kept that action as
per-repo copies instead, on two premises: the wrapper's customizations were
unused, and upstream's native gating was stronger. Neither holds now:

- The native gating checks the commenter, not where the pull request came
  from.
- Tag mode grants write tools (Edit, Write, `git add/commit/push`).
- The safe configuration is real policy: a gate job, tool deny rules,
  environment scrubbing, token choice, and deterministic comment posting.
- The copies drifted across several action refs while all carrying the same
  unsafe configuration.

One reusable means one place to review and one pin for Renovate to bump. Do
not go back to per-repo copies without revisiting those points.

Keep the hardening intact. Any of these is a security change, not a tweak:
enabling `track_progress` or tag mode; adding a built-in tool to `--tools`
(Read, Grep, Glob); widening `--allowedTools` beyond the
inline-comment tool and the two CI read tools; dropping a `--disallowedTools`
entry or the `.git`/`/proc` read denials; turning off
`blockReadsOutsideWorkingDirectories`; adding `id-token` or a broader
permission; letting the model post anything except through the fixed
posting steps; passing a comment body through a shell; or loosening the
same-repo, non-draft, non-bot, and commenter-permission gates. Verify
claude-code-action behavior against its source at the pinned SHA before
changing how it is called.

## Pins and checks

- Pin third-party actions by full commit SHA with a version comment
  (`uses: owner/action@<sha> # vX.Y.Z`). Renovate bumps them.
- Before pushing: `actionlint` (reads `.github/actionlint.yaml`),
  `shellcheck actions/**/*.sh`, and `bash actions/release-gate/test.sh`.
  Behavior changes to the release gate need a scenario in `test.sh`.
- Changes land through pull requests, so CI and the Claude review run on
  them.
