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
# that bot's own GitHub-verified commits, or is neutral: it changes only files
# under the release-please config's exclude-paths directories, which
# release-please ignores and which cannot change what ships. Provenance comes
# from GitHub's commit->PR association and commit signatures, not git author
# metadata, which anyone can set. Any other human change in the range means a
# human merges the release.
#
# Requires GH_TOKEN, GH_REPO, RELEASE_BRANCH, MANIFEST_FILE, and
# RELEASE_AUTHORS (space-separated `gh` author logins, e.g.
# "app/github-actions app/bsky-release-bot"). CONFIG_FILE defaults to
# release-please-config.json.
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

# The release-please exclude-paths at main, with the same precedence
# release-please uses (package value, else top-level default). Entries are
# directory prefixes: release-please strips one leading and one trailing "/"
# and matches a file against "<entry>/".
config_file="${CONFIG_FILE:-release-please-config.json}"
excludes="$(gh api "repos/${GH_REPO}/contents/${config_file}?ref=${main_sha}" \
  --jq '.content | gsub("\\s"; "") | @base64d' |
  jq -c '.packages["."]["exclude-paths"] // .["exclude-paths"] // []
         | if type == "array" and all(.[]; type == "string") then .
           else error("exclude-paths must be an array of strings") end
         | map(sub("/$"; "") | sub("^/"; ""))')"

# bot_reason <sha>: prints why the commit is not a dependency bot's, or
# nothing when it is.
bot_reason() {
  local sha="$1" pr_number
  pr_number="$(gh api "repos/${GH_REPO}/commits/${sha}/pulls" | jq -r --argjson bots "${bots}" '
    [.[] | select((.user.login as $u | $bots | index($u))
                  and .merged_at != null and .base.ref == "main")][0].number // empty')"
  if [[ -z "${pr_number}" ]]; then
    echo "commit ${sha} did not arrive through a merged Renovate or Dependabot PR"
    return
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
  fi
}

# neutral <sha>: succeeds when every file the commit changes is under an
# exclude-paths directory, so release-please ignores it and it cannot change
# the shipped artifact, whoever wrote it. A rename's old path counts too:
# release-please sees only the new one, but moving shipped code into docs/
# removes it from what ships. A merge commit lists only its diff against one
# parent, so it is never neutral. The API returns at most 300 files per page,
# so a 300-file list may be truncated.
neutral() {
  local commit
  commit="$(gh api "repos/${GH_REPO}/commits/$1")" || return 1
  jq -e --argjson ex "${excludes}" '
    (.parents | length) == 1
    and (.files | length) > 0 and (.files | length) < 300
    and all(.files[] | .filename, (.previous_filename // empty);
            . as $f | $ex | any(.[]; . as $d | $f | startswith($d + "/")))
  ' <<<"${commit}" >/dev/null
}

# Merge commits are checked too: their tree can carry changes no parent has,
# and their associated PR is whatever they merged, so a human merge fails here.
bot_count=0 neutral_count=0
while read -r sha; do
  reason="$(bot_reason "${sha}")"
  if [[ -z "${reason}" ]]; then
    bot_count=$((bot_count + 1))
  elif neutral "${sha}"; then
    neutral_count=$((neutral_count + 1))
  else
    echo "${reason}"
    exit 1
  fi
done < <(jq -r '.commits[].sha' <<<"${compare}")

# Release-please opens no Release PR for a neutral-only range; one that exists
# anyway is not a dependency release.
if (( bot_count == 0 )); then
  echo "no dependency-bot commit since v${base_version}"
  exit 1
fi

echo "all ${total} commits since v${base_version} came from dependency bots (${bot_count}) or touched only exclude-paths (${neutral_count})"
