#!/usr/bin/env bash
# Decides whether a Release Please PR may merge without a human.
#
# Usage: bot-only-release.sh <release-pr-json> <base-version>
#   release-pr-json: `gh pr view --json number,title,author,baseRefName,
#                    headRefName,isCrossRepository,files,labels`
#   base-version:    the version in the release-please manifest on main
#
# Exits 0 only when the PR is Release Please's own (a release bot author, the
# release branch, touches only the manifest and changelog, no release:manual
# label) AND every commit between v<base-version> and main, merge commits
# included, arrived through a merged Renovate or Dependabot PR made only of
# that bot's own GitHub-verified commits. Provenance comes from GitHub's
# commit->PR association and commit signatures, not git author metadata,
# which anyone can set. Any human change in the range means a human merges
# the release.
#
# Requires GH_TOKEN, GH_REPO, RELEASE_BRANCH, MANIFEST_FILE, and
# RELEASE_AUTHORS (space-separated `gh` author logins, e.g.
# "app/github-actions app/bsky-release-bot").
set -euo pipefail

pr_json="$1"
base_version="$2"

if ! jq -e \
  --arg release_branch "${RELEASE_BRANCH}" \
  --arg manifest "${MANIFEST_FILE}" \
  --arg authors "${RELEASE_AUTHORS}" '
  .author.is_bot == true
  and (.author.login as $login | $authors | split(" ") | index($login))
  and .baseRefName == "main"
  and .headRefName == $release_branch
  and .isCrossRepository == false
  and (.title | startswith("chore(main): release "))
  and ((.files | map(.path) | sort) == ([$manifest, "CHANGELOG.md"] | sort))
  and ([.labels[].name] | index("release:manual") | not)
' <<<"${pr_json}" >/dev/null; then
  echo "not an unattended-eligible Release Please PR"
  exit 1
fi

main_sha="$(gh api "repos/${GH_REPO}/git/ref/heads/main" --jq '.object.sha')"
compare="$(gh api "repos/${GH_REPO}/compare/v${base_version}...${main_sha}")"
total="$(jq -r '.total_commits' <<<"${compare}")"
# compare pages at 250 commits; a range that large is not a dependency bump.
if [[ "${total}" -eq 0 || "${total}" -gt 250 ]]; then
  echo "unexpected range size ${total} since v${base_version}"
  exit 1
fi

bots='["renovate[bot]", "dependabot[bot]"]'

# Merge commits are checked too: their tree can carry changes no parent has,
# and their associated PR is whatever they merged, so a human merge fails here.
while read -r sha; do
  pr_number="$(gh api "repos/${GH_REPO}/commits/${sha}/pulls" | jq -r --argjson bots "${bots}" '
    [.[] | select((.user.login as $u | $bots | index($u))
                  and .merged_at != null and .base.ref == "main")][0].number // empty')"
  if [[ -z "${pr_number}" ]]; then
    echo "commit ${sha} did not arrive through a merged Renovate or Dependabot PR"
    exit 1
  fi
  # A bot opening the PR is not enough: a human can push a fix onto the bot's
  # branch before it is squash-merged. Every commit in the PR must be the
  # bot's own and GitHub-signed (verification is what stops a human from
  # simply setting the bot's email as their git author).
  if ! gh api "repos/${GH_REPO}/pulls/${pr_number}/commits?per_page=100" | jq -e --argjson bots "${bots}" '
    length > 0 and all(.[];
      (.author.login as $a | $a != null and ($bots | index($a)))
      and .commit.verification.verified == true)
  ' >/dev/null; then
    echo "PR #${pr_number} (commit ${sha}) contains commits that are not the bot's own verified commits"
    exit 1
  fi
done < <(jq -r '.commits[].sha' <<<"${compare}")

echo "all ${total} commits since v${base_version} came from dependency bots"
