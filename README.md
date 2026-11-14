# bluesky-social/.github

Shared GitHub Actions reusable workflows and Renovate presets for
`bluesky-social` repositories. The repository is public so that public and
private repositories can both use them.

Pin `@v1` for workflows and `#v1` for Renovate presets. Non-breaking changes
move `v1`; a change to a workflow's inputs, secrets, outputs, or permissions
gets a new major (`v2`).

## Reusable workflows

### `pr-title.yml`

A required check that the pull request title has a `type:` prefix
(`feat:`, `fix(api):`, `docs:`, `feat!:`). Titles become squash-merge commit
messages, and release-please drops commits without a prefix. Check name:
`pr-title / pr-title`.

```yaml
name: pr-title
on:
  pull_request:
    types: [opened, edited, synchronize, reopened]
permissions: {}
jobs:
  pr-title:
    uses: bluesky-social/.github/.github/workflows/pr-title.yml@v1
```

### `release-please.yml` and `actions/release-gate/`

The org release pipeline for single-package release-please repositories.

1. Cuts any merged release (tag and GitHub release) with the job token, so a
   tag-push workflow never double-runs.
2. Maintains the standing Release PR as a GitHub App, so the Release PR's CI
   runs.
3. Runs the release gate. When every commit since the last tag arrived through
   a merged Renovate or Dependabot pull request made only of that bot's own
   verified commits, on a weekday between 09:00 and 16:00 Pacific, and the
   Release PR has no `release:manual` label, the scheduled or manually
   dispatched run enables auto-merge. Anything a human wrote waits for a human.
   Held CI runs are approved only when they come from this repository's own
   release branch at the release head.

The gate scripts are plain shell, checked out from this workflow's own commit,
with scenario tests in `actions/release-gate/test.sh`. Outputs:
`release_created` and `tag_name`, for the caller's own build and deploy jobs.
The App needs contents, pull requests, issues, and actions write, and checks
read. Branch protection with required checks is what makes auto-merge safe:
without it GitHub merges immediately.

```yaml
name: release-please
on:
  push:
    branches: [main]
  workflow_dispatch: {}
  schedule:
    - cron: '23 16-23 * * 1-5' # hourly through the 09-16 PT window
permissions:
  contents: write
  pull-requests: write
jobs:
  release:
    uses: bluesky-social/.github/.github/workflows/release-please.yml@v1
    with:
      component: example
    secrets:
      RELEASE_APP_ID: ${{ secrets.RELEASE_APP_ID }}
      RELEASE_APP_KEY: ${{ secrets.RELEASE_APP_KEY }}
```

Optional inputs: `config-file` (default `release-please-config.json`) and
`manifest-file` (default `.release-please-manifest.json`).

### `security.yml`

Three required checks with pinned tool versions: `security / govulncheck`
(reachable vulnerabilities in a root Go module; skip with `go: false`),
`security / gitleaks` (secrets in the commits a push or pull request adds),
and `security / actionlint` (workflow lint plus shellcheck over `run:`
blocks). `runner-labels` adds self-hosted runner labels for actionlint to
accept.

```yaml
jobs:
  security:
    uses: bluesky-social/.github/.github/workflows/security.yml@v1
    permissions:
      contents: read
    with:
      go: false
```

### `claude-review.yml` and `claude-mention.yml`

Claude review of pull requests, and answers to `@claude` mentions on them.
Read the [trust model](#claude-reusables-trust-model) before adopting.

Review guidance comes from the caller's `.github/claude-review-prompt.md`,
read at the pull request's base commit, so a pull request cannot change the
rules it is reviewed under. Without that file a default prompt built into
`claude-review.yml` applies. Optional inputs for both: `gateway-url` (the
model gateway; defaults to the org's) and `model` (default
`claude-opus-5-5:api`).

```yaml
# .github/workflows/claude-review.yml
name: claude-review
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
permissions: {}
jobs:
  review:
    uses: bluesky-social/.github/.github/workflows/claude-review.yml@v1
    permissions:
      contents: read
      pull-requests: write
      actions: read
    secrets:
      AGENT_GATEWAY_CLAUDE_GH_REVIEW_KEY: ${{ secrets.AGENT_GATEWAY_CLAUDE_GH_REVIEW_KEY }}
```

```yaml
# .github/workflows/claude-mention.yml
name: claude-mention
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  pull_request_review:
    types: [submitted]
permissions: {}
jobs:
  mention:
    uses: bluesky-social/.github/.github/workflows/claude-mention.yml@v1
    permissions:
      contents: read
      pull-requests: write
      actions: read
    secrets:
      AGENT_GATEWAY_CLAUDE_GH_REVIEW_KEY: ${{ secrets.AGENT_GATEWAY_CLAUDE_GH_REVIEW_KEY }}
```

Pass the key as the named secret shown. Do not use `secrets: inherit`.

## Renovate presets

- `renovate/default.json`: the org dependency policy. Patch, digest, and pin
  updates automerge everywhere; minors automerge for Go modules, GitHub
  Actions, and container images; security updates skip the 3-day minimum
  release age. Runtime dependency bumps are `fix(deps):` so release-please
  releases them. Indirect Go modules get no major updates to v2 or later
  (except `+incompatible` ones), since a new major is a new module path that only
  the importing dependency can adopt.
  Requires branch protection with required checks.
- `renovate/pnpm.json`: adds npm minor automerge and a weekly lock file
  refresh for repositories where pnpm 11 or later enforces its own release-age
  cooldown.
- `renovate/uv.json`: adds a weekly `uv.lock` refresh for repositories where uv
  enforces `exclude-newer`.

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "local>bluesky-social/.github//renovate/default#v1",
    "local>bluesky-social/.github//renovate/pnpm#v1"
  ]
}
```

Each preset's `description` field states its preconditions.

## Claude reusables: trust model

**Who gets reviewed.** `claude-review.yml` runs only on `pull_request`
events for pull requests whose head branch is in the same repository (only
people with write access can push one), that are not drafts, and that neither
a bot opened nor a bot triggered. Fork pull requests are never reviewed.
`claude-mention.yml` runs a gate job first. It answers only when the pull
request head is in the same repository and the commenter's permission, read
from `repos/{owner}/{repo}/collaborators/{user}/permission`, is write,
maintain, or admin. It does not use `author_association`, because
`COLLABORATOR` can mean triage-only. Mentions on issues, fork pull requests,
and bot comments are skipped.

**What the model can do.**

- Read files in the repository checkout and in the inputs a workflow step
  staged before it started: pull request metadata, the diff, and the review
  guidance.
- Comment on lines of this pull request, through claude-code-action's
  inline-comment tool, which is pinned to the pull request.
- Read this pull request's CI status and job logs.
- Return a summary (review) or reply (mention) as structured output. A
  fixed workflow step posts it as `github-actions[bot]`.

**What it cannot do.**

- Run commands, edit files, use the web, or start other agents. Its
  built-in tools are limited to Read, Grep, and Glob. Bash, Edit, Write,
  MultiEdit, NotebookEdit, WebFetch, and WebSearch are also denied by name.
  Any MCP tool other than the three listed above is refused. The workflow
  runs claude-code-action in agent mode only, never tag mode, so no git
  tools or branch checkout are added.
- Read outside the working directories. File reads elsewhere are refused,
  and `.git/` and `/proc` are denied explicitly. claude-code-action writes the
  job token into `.git/config` for its own use, and the process environment
  holds the gateway key.
- Push. The checkout does not persist its credential, and the model has no
  git tools.
- Mint other credentials. The only GitHub credential is the caller job's
  `GITHUB_TOKEN` with `contents: read`, `pull-requests: write`, and
  `actions: read`. There is no `id-token` permission and no Claude App
  token. Subprocess environment scrubbing is on. The posting step refuses
  output that contains the job token, the gateway key, or a GitHub token
  pattern.

**Worst case under prompt injection.** Text in a trusted author's own diff,
pull request description, repository files, or CI logs steers the model into
posting misleading comments on that one pull request, and spends gateway
usage up to the 20-minute job timeout. The model cannot write files, push, or
reach a token through its tools.

**Out of scope.** People with write access are trusted. They can already
push a workflow that reads the repository's secrets, so these workflows do
not defend against them.

## Development

Changes land through pull requests. `ci.yml` runs actionlint (with
shellcheck over `run:` blocks), shellcheck over `actions/**/*.sh`, and
gitleaks over the full history. `release-gate-test.yml` runs the gate
scenarios. `claude-review-self.yml` reviews this repository's own pull
requests through the reusable at the same commit. Conventions for agents
working here are in [AGENTS.md](AGENTS.md).

## License

Dual-licensed under [MIT](LICENSE-MIT.txt) and [Apache 2.0](LICENSE-APACHE.txt);
see [LICENSE.txt](LICENSE.txt).
