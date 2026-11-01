#!/usr/bin/env bash
# Queues or withdraws auto-merge on the standing Release Please PR.
#
# MODE=disarm runs before release-please touches the Release PR and withdraws
# any auto-merge this App enabled earlier. MODE=gate runs after: when
# bot-only-release.sh passes on a weekday 09:00-16:00 PT, and the run is the
# hourly schedule or a manual dispatch (batching; push runs only report), it
# approves any
# approval-gated CI runs on the head and enables auto-merge as the release
# App, so GitHub merges once required checks pass and the merge push triggers
# the release run. Disarm-then-rearm means the PR is only ever armed for a
# range this run checked: a run that dies after release-please moved the
# branch leaves it waiting for a human. Strict branch protection closes the
# rest: a human merge to main leaves the Release PR behind, unmergeable until
# the next run (which disarms first) brings it up to date. An auto-merge a
# human enabled is never touched.
#
# Requires GH_TOKEN (release App token), GH_REPO, RELEASE_BRANCH,
# MANIFEST_FILE, APP_SLUG, MODE (disarm|gate).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RELEASE_AUTHORS="app/github-actions app/${APP_SLUG}"

fields='number,title,author,baseRefName,headRefName,headRefOid,isCrossRepository,files,labels,autoMergeRequest'
pr="$(gh pr list --base main --head "${RELEASE_BRANCH}" --state open \
  --json "${fields}" --jq '.[0] // empty')"
if [[ -z "${pr}" ]]; then
  echo "no open Release PR on ${RELEASE_BRANCH}"
  exit 0
fi
number="$(jq -r '.number' <<<"${pr}")"

armed_by_us() {
  jq -e --arg slug "${APP_SLUG}" '
    .autoMergeRequest != null
    and (.autoMergeRequest.enabledBy.login as $by
         | [$slug, "\($slug)[bot]", "app/\($slug)"] | index($by))
  ' <<<"$1" >/dev/null
}

case "${MODE}" in
  disarm)
    if armed_by_us "${pr}"; then
      gh pr merge "${number}" --disable-auto
      echo "withdrew this App's auto-merge of Release PR #${number} before refreshing it"
    fi
    exit 0
    ;;
  gate) ;;
  *)
    echo "unknown MODE '${MODE}'" >&2
    exit 2
    ;;
esac

# Fail closed: if anything below errors out (a refresh that pulled in new
# commits and didn't converge, an API failure), withdraw this App's
# auto-merge rather than leave the PR armed for a range nobody checked.
disarm_on_error() {
  local rc=$?
  if (( rc != 0 )); then
    local current
    if current="$(gh pr view "${number}" --json autoMergeRequest)" && armed_by_us "${current}"; then
      gh pr merge "${number}" --disable-auto || true
      echo "gate failed (exit ${rc}); withdrew this App's auto-merge of Release PR #${number}" >&2
    fi
  fi
  exit "${rc}"
}
trap disarm_on_error EXIT

# Strict branch protection needs the Release PR on the latest main. Refresh
# only a release bot's own same-repo branch, then reread its metadata.
if jq -e --arg authors "${RELEASE_AUTHORS}" '
  .isCrossRepository == false and .author.is_bot == true
  and (.author.login as $login | $authors | split(" ") | index($login))
' <<<"${pr}" >/dev/null; then
  pr="$(bash "${here}/refresh-release-pr.sh" "${number}" "${fields}")"
fi
head="$(jq -r '.headRefOid' <<<"${pr}")"
base_version="$(gh api "repos/${GH_REPO}/contents/${MANIFEST_FILE}?ref=main" \
  --jq '.content | @base64d | fromjson | .["."] // empty')"
if [[ -z "${base_version}" ]]; then
  echo "::error::${MANIFEST_FILE} has no root ('.') package; release-gate supports single-package release-please repos only" >&2
  exit 1
fi

dow="$(TZ=America/Los_Angeles date +%u)"
hour="$(TZ=America/Los_Angeles date +%H)"
in_window=false
if (( dow <= 5 && 10#${hour} >= 9 && 10#${hour} < 16 )); then
  in_window=true
fi

# Batch unattended releases: only the hourly scheduled run (or a manual
# dispatch) arms auto-merge, so every bot merge within the hour ships as one
# release and one deploy instead of one per Renovate PR. Push runs still
# disarm (above) and report eligibility.
arming_run=false
case "${GITHUB_EVENT_NAME:-}" in
  schedule | workflow_dispatch) arming_run=true ;;
esac

if [[ "${in_window}" == true ]] && bash "${here}/bot-only-release.sh" "${pr}" "${base_version}"; then
  if [[ "${arming_run}" != true ]]; then
    echo "Release PR #${number} is eligible; the next scheduled run queues it (event=${GITHUB_EVENT_NAME:-unknown})"
    exit 0
  fi
  # Public repos can hold a bot PR's runs for approval. Approve only runs on
  # this eligible release head that came from this repository's own release
  # branch. Forks share the object network, so a fork PR can sit at the same
  # head SHA, and a fork can name its branch like the release branch: both
  # the head repository and the head branch must match. Every page is read
  # before filtering, so fork runs at this SHA cannot push the release run out
  # of a fixed-size window. Listing errors exit through disarm_on_error.
  runs="$(gh api --paginate \
    "repos/${GH_REPO}/actions/runs?head_sha=${head}&status=action_required&per_page=100" |
    jq -r --arg repo "${GH_REPO}" --arg branch "${RELEASE_BRANCH}" '
      .workflow_runs[]
      | select((.head_repository.full_name // "") == $repo and .head_branch == $branch)
      | .id')"
  while read -r run; do
    [[ -n "${run}" ]] && gh api --method POST "repos/${GH_REPO}/actions/runs/${run}/approve"
  done <<<"${runs}"
  # GitHub enforces the required checks and strict protection.
  gh pr merge "${number}" --auto --squash --match-head-commit "${head}"
  echo "queued auto-merge of Release PR #${number} at ${head}"
elif armed_by_us "${pr}"; then
  # Disarm normally ran already; this covers a re-arm by a concurrent run.
  gh pr merge "${number}" --disable-auto
  echo "withdrew this App's auto-merge of Release PR #${number}"
else
  echo "Release PR #${number} waits for a human (in_window=${in_window})"
fi
