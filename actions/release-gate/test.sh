#!/usr/bin/env bash
# Scenario tests for the release gate. Puts fake `gh` and `date` binaries on
# PATH; each scenario writes the JSON the fake gh serves and asserts on the
# exit status and on the mutating gh calls (pr merge) it recorded.
#
# Usage: bash actions/release-gate/test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"

cat >"${work}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fake gh: serves fixtures from $FIXTURES, logs every call to $FIXTURES/calls.
set -euo pipefail
echo "$*" >>"${FIXTURES}/calls"
jq_filter=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" == --jq ]] && jq_filter="${args[i+1]}"
done
serve() {
  if [[ -n "${jq_filter}" ]]; then jq -r "${jq_filter}" "$1"; else cat "$1"; fi
}
# runs-all.json holds every action_required run at the release head, in the
# order GitHub lists them. `run list` honors --limit (gh's default is 20);
# `api .../actions/runs` serves per_page-sized pages, all of them only with
# --paginate.
case "$1 $2" in
  "pr list") serve "${FIXTURES}/pr-list.json" ;;
  "pr view") serve "${FIXTURES}/pr-view.json" ;;
  "pr update-branch" | "pr merge") ;;
  "run list")
    limit=20
    for ((i = 0; i < ${#args[@]}; i++)); do
      [[ "${args[i]}" == --limit ]] && limit="${args[i+1]}"
    done
    jq --argjson n "${limit}" '[.[:$n][] | {databaseId: .id}]' "${FIXTURES}/runs-all.json" >"${FIXTURES}/runs.json"
    serve "${FIXTURES}/runs.json"
    ;;
  api*)
    path="" paginate=false
    for ((i = 1; i < ${#args[@]}; i++)); do
      case "${args[i]}" in
        --method) exit 0 ;;
        --paginate) paginate=true ;;
        --jq) i=$((i + 1)) ;;
        *) [[ -z "${path}" ]] && path="${args[i]}" ;;
      esac
    done
    case "${path}" in
      */actions/runs\?*)
        per_page=30
        [[ "${path}" =~ per_page=([0-9]+) ]] && per_page="${BASH_REMATCH[1]}"
        jq -c --argjson n "${per_page}" --argjson all "${paginate}" '
          [range(0; if length == 0 then 1 else length end; $n) as $o
           | {total_count: length, workflow_runs: .[$o:$o + $n]}]
          | if $all then .[] else .[0] end' "${FIXTURES}/runs-all.json"
        ;;
      */git/ref/heads/main) serve "${FIXTURES}/main-ref.json" ;;
      */contents/release-please-config.json*) serve "${FIXTURES}/config-contents.json" ;;
      */contents/*) serve "${FIXTURES}/manifest-contents.json" ;;
      */compare/*...*) serve "${FIXTURES}/compare.json" ;;
      */commits/*/pulls) serve "${FIXTURES}/pulls-$(basename "$(dirname "${path}")").json" ;;
      */commits/*) serve "${FIXTURES}/commit-$(basename "${path}").json" ;;
      */pulls/*/commits*)
        n="${path#*/pulls/}"
        serve "${FIXTURES}/prcommits-${n%%/*}.json"
        ;;
      *) echo "fake gh: unexpected api path ${path}" >&2; exit 9 ;;
    esac
    ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 9 ;;
esac
EOF
cat >"${work}/bin/date" <<'EOF'
#!/usr/bin/env bash
# Fake date: weekday/hour from $FAKE_DOW / $FAKE_HOUR.
case "$1" in
  +%u) echo "${FAKE_DOW}" ;;
  +%H) echo "${FAKE_HOUR}" ;;
  *) exec /bin/date "$@" ;;
esac
EOF
chmod +x "${work}/bin/gh" "${work}/bin/date"
export PATH="${work}/bin:${PATH}"
export GH_REPO=bluesky-social/example GH_TOKEN=fake APP_SLUG=bsky-release-bot
export RELEASE_BRANCH=release-please--branches--main--components--example
export MANIFEST_FILE=.release-please-manifest.json

failures=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

# bot_pr <sha> <pr-number> <pr-author> [base]: the PR a commit maps to.
bot_pr() {
  jq -n --arg u "$3" --argjson n "$2" --arg base "${4:-main}" \
    '[{number: $n, user: {login: $u}, merged_at: "2026-10-27T17:00:00Z", base: {ref: $base}}]' \
    >"${FIXTURES}/pulls-$1.json"
}
# bot_commits <pr-number> <author-login> <verified> [<author-login> <verified>]...
bot_commits() {
  local n="$1"; shift
  local out="[]"
  while (( $# )); do
    out="$(jq --arg a "$1" --argjson v "$2" '. + [{author: {login: $a}, commit: {verification: {verified: $v}}}]' <<<"${out}")"
    shift 2
  done
  printf '%s\n' "${out}" >"${FIXTURES}/prcommits-${n}.json"
}
# commit_files <sha> <parent-count> <file>...: what GET commits/<sha> serves.
# A file given as old=>new is a rename.
commit_files() {
  local sha="$1" parents="$2"; shift 2
  local files="[]" f
  for f in "$@"; do
    if [[ "${f}" == *"=>"* ]]; then
      files="$(jq --arg o "${f%%=>*}" --arg n "${f#*=>}" \
        '. + [{filename: $n, previous_filename: $o, status: "renamed"}]' <<<"${files}")"
    else
      files="$(jq --arg n "${f}" '. + [{filename: $n, status: "modified"}]' <<<"${files}")"
    fi
  done
  jq -n --arg sha "${sha}" --argjson p "${parents}" --argjson files "${files}" \
    '{sha: $sha, parents: [range($p) | {sha: "parent\(.)"}], files: $files}' \
    >"${FIXTURES}/commit-${sha}.json"
}
# set_config <json>: the release-please config served at main, base64 wrapped
# at 60 columns the way the contents API returns it.
set_config() {
  jq -n --arg c "$(printf '%s' "$1" | base64 | tr -d '\n' | fold -w 60)" '{content: $c}' \
    >"${FIXTURES}/config-contents.json"
}

# fixture <name>: reset fixtures to an eligible two-commit Renovate range.
fixture() {
  export FIXTURES="${work}/$1"
  mkdir -p "${FIXTURES}"
  : >"${FIXTURES}/calls"
  export FAKE_DOW=2 FAKE_HOUR=10 GITHUB_EVENT_NAME=schedule
  cat >"${FIXTURES}/pr.json" <<'EOF'
{"number": 42, "title": "chore(main): release 1.2.4",
 "author": {"is_bot": true, "login": "app/bsky-release-bot"},
 "baseRefName": "main",
 "headRefName": "release-please--branches--main--components--example",
 "headRefOid": "headsha", "isCrossRepository": false,
 "files": [{"path": "CHANGELOG.md"}, {"path": ".release-please-manifest.json"}],
 "labels": [], "autoMergeRequest": null}
EOF
  jq -s '.' "${FIXTURES}/pr.json" >"${FIXTURES}/pr-list.json"
  cp "${FIXTURES}/pr.json" "${FIXTURES}/pr-view.json"
  echo '{"object": {"sha": "mainsha"}}' >"${FIXTURES}/main-ref.json"
  jq -n --arg c "$(printf '{".": "1.2.3"}' | base64)" '{content: $c}' \
    >"${FIXTURES}/manifest-contents.json"
  # The fake serves compare for both ancestry checks and the range check.
  echo '{"status": "ahead", "total_commits": 2, "commits": [{"sha": "c1"}, {"sha": "c2"}]}' \
    >"${FIXTURES}/compare.json"
  for n in 1 2; do
    bot_pr "c${n}" "${n}" "renovate[bot]"
    bot_commits "${n}" "renovate[bot]" true
    commit_files "c${n}" 1 main.go
  done
  set_config '{"packages": {".": {"exclude-paths": ["docs", ".github"]}}}'
  echo '[]' >"${FIXTURES}/runs-all.json"
}

# run_at_head <id> <head-repo> <head-branch>: append an action_required run at
# the release head.
run_at_head() {
  jq --argjson id "$1" --arg repo "$2" --arg branch "$3" \
    '. + [{id: $id, head_sha: "headsha", status: "action_required",
           head_repository: {full_name: $repo}, head_branch: $branch}]' \
    "${FIXTURES}/runs-all.json" >"${FIXTURES}/runs.tmp" && mv "${FIXTURES}/runs.tmp" "${FIXTURES}/runs-all.json"
}
approved() { grep -q "^api --method POST repos/${GH_REPO}/actions/runs/$1/approve\$" "${FIXTURES}/calls"; }

# set_pr <jq-expr>: edit the served Release PR.
set_pr() {
  jq "$1" "${FIXTURES}/pr.json" >"${FIXTURES}/pr.tmp" && mv "${FIXTURES}/pr.tmp" "${FIXTURES}/pr.json"
  jq -s '.' "${FIXTURES}/pr.json" >"${FIXTURES}/pr-list.json"
  cp "${FIXTURES}/pr.json" "${FIXTURES}/pr-view.json"
}

run_gate() { MODE="$1" bash "${here}/gate.sh" >"${FIXTURES}/out" 2>&1; }
merged_auto() { grep -q '^pr merge 42 --auto' "${FIXTURES}/calls"; }
disarmed() { grep -q '^pr merge 42 --disable-auto' "${FIXTURES}/calls"; }

check_eligible() {
  local name="$1"
  if run_gate gate && merged_auto; then pass "${name}"; else fail "${name}" "expected auto-merge; $(cat "${FIXTURES}/out")"; fi
}
check_waits() {
  local name="$1"
  run_gate gate || true
  if merged_auto; then fail "${name}" "auto-merge was queued"; else pass "${name}"; fi
}

fixture renovate-only
check_eligible "renovate-only range in window queues auto-merge"

fixture dependabot
bot_pr c2 2 "dependabot[bot]"; bot_commits 2 "dependabot[bot]" true
check_eligible "dependabot commit counts as bot provenance"

fixture legacy-author
set_pr '.author.login = "app/github-actions"'
check_eligible "Release PR opened by github-actions before the App is still eligible"

fixture human-commit
bot_pr c2 2 some-human
check_waits "a human-merged commit in range waits for a human"

fixture direct-push
echo '[]' >"${FIXTURES}/pulls-c1.json"
check_waits "a direct push (no associated PR) waits for a human"

fixture neutral-docs
bot_pr c1 1 some-human
commit_files c1 1 docs/runbook.md
check_eligible "a human commit touching only excluded paths is neutral"

fixture mixed-docs-and-code
bot_pr c1 1 some-human
commit_files c1 1 docs/runbook.md main.go
check_waits "a human commit touching excluded and other paths waits"

# Release-please sees only the new path and ignores this commit, but moving the
# file removes it from what ships.
fixture rename-into-excluded
bot_pr c1 1 some-human
commit_files c1 1 'cmd/tool.go=>docs/tool.go'
check_waits "moving a file into an excluded path waits"

fixture neutral-only
for n in 1 2; do
  bot_pr "c${n}" "${n}" some-human
  commit_files "c${n}" 1 docs/runbook.md
done
check_waits "a range with no dependency-bot commit waits"

# Release-please excludes everything for ".", so the gate must never read it
# as "every path is neutral".
for entry in . ''; do
  fixture "root-exclude-${entry:-empty}"
  set_config "$(jq -cn --arg e "${entry}" '{packages: {".": {"exclude-paths": [$e]}}}')"
  bot_pr c1 1 some-human
  check_waits "an exclude-paths entry of '${entry}' neutralizes nothing"
done

fixture exclude-trailing-slash
set_config '{"packages": {".": {"exclude-paths": ["/docs/"]}}}'
bot_pr c1 1 some-human
commit_files c1 1 docs/runbook.md
check_eligible "exclude-paths entries are normalized like release-please's"

for value in '{"x": "docs"}' '"docs"' '["docs", 1]'; do
  fixture "exclude-not-string-array"
  set_config "{\"packages\": {\".\": {\"exclude-paths\": ${value}}}}"
  bot_pr c1 1 some-human
  commit_files c1 1 docs/runbook.md
  check_waits "exclude-paths of ${value} fails closed"
done

fixture exclude-top-level
set_config '{"exclude-paths": ["docs"], "packages": {".": {}}}'
bot_pr c1 1 some-human
commit_files c1 1 docs/runbook.md
check_eligible "a top-level exclude-paths applies when the package sets none"

fixture exclude-package-overrides
set_config '{"exclude-paths": ["docs"], "packages": {".": {"exclude-paths": []}}}'
bot_pr c1 1 some-human
commit_files c1 1 docs/runbook.md
check_waits "a package exclude-paths replaces the top-level one"

# A merge commit's files are its diff against one parent; whatever the other
# parent brings in is not listed.
fixture neutral-merge-commit
echo '[]' >"${FIXTURES}/pulls-c1.json"
commit_files c1 2 docs/runbook.md
check_waits "a merge commit is never neutral"

fixture neutral-no-files
bot_pr c1 1 some-human
commit_files c1 1
check_waits "a commit listing no files is not neutral"

# The commit API returns at most 300 files per page, so 300 may be truncated.
fixture neutral-300-files
bot_pr c1 1 some-human
jq -n '{sha: "c1", parents: [{sha: "p"}],
        files: [range(300) | {filename: "docs/f\(.).md", status: "added"}]}' \
  >"${FIXTURES}/commit-c1.json"
check_waits "a commit listing 300 files is not neutral"

fixture bot-pr-other-base
bot_pr c1 1 "renovate[bot]" dev
check_waits "a bot PR merged into another base does not count"

fixture extra-file
set_pr '.files += [{"path": "go.mod"}]'
check_waits "a Release PR touching more than manifest+changelog waits"

fixture manual-label
set_pr '.labels = [{"name": "release:manual"}]'
check_waits "release:manual label holds the release"

fixture human-author
set_pr '.author = {"is_bot": false, "login": "some-human"}'
check_waits "a human-authored release branch PR waits"

fixture weekend
export FAKE_DOW=6
check_waits "Saturday waits"

fixture after-hours
export FAKE_HOUR=16
check_waits "16:00 PT is outside the window"

fixture empty-range
echo '{"status": "ahead", "total_commits": 0, "commits": []}' >"${FIXTURES}/compare.json"
check_waits "an empty range does not release"

fixture push-batches
export GITHUB_EVENT_NAME=push
check_waits "an eligible range on a push run waits for the scheduled run"
if grep -q "next scheduled run queues it" "${FIXTURES}/out"; then pass "push run reports eligibility"; else fail "push run reports eligibility" "$(cat "${FIXTURES}/out")"; fi

fixture dispatch-arms
export GITHUB_EVENT_NAME=workflow_dispatch
check_eligible "a manual dispatch queues an eligible release"

fixture approve-own-runs-only
run_at_head 101 "${GH_REPO}" "${RELEASE_BRANCH}"
run_at_head 102 attacker/example "${RELEASE_BRANCH}"
run_at_head 103 attacker/example patch-1
run_at_head 104 "${GH_REPO}" feature
run_gate gate || true
if approved 101 && ! approved 102 && ! approved 103 && ! approved 104 && merged_auto; then
  pass "approves only the release branch's own held runs, never a fork's at the same SHA"
else
  fail "approves only the release branch's own held runs, never a fork's at the same SHA" "$(grep approve "${FIXTURES}/calls" || echo 'no approvals')"
fi

fixture approve-past-first-page
for ((n = 1000; n < 1150; n++)); do run_at_head "${n}" attacker/example "${RELEASE_BRANCH}"; done
run_at_head 101 "${GH_REPO}" "${RELEASE_BRANCH}"
run_gate gate || true
if approved 101 && ! grep -q '/actions/runs/1[01][0-9][0-9]/approve' "${FIXTURES}/calls" && merged_auto; then
  pass "finds the release run behind 150 fork runs at the same SHA"
else
  fail "finds the release run behind 150 fork runs at the same SHA" "approved 101: $(approved 101 && echo yes || echo no); fork approvals: $(grep -c '/actions/runs/1[01][0-9][0-9]/approve' "${FIXTURES}/calls" || true)"
fi

fixture human-commit-on-bot-pr
bot_commits 2 "renovate[bot]" true some-human true
check_waits "a human commit pushed onto a bot PR waits for a human"

fixture unverified-bot-commit
bot_commits 1 "renovate[bot]" false
check_waits "an unsigned commit claiming to be the bot waits for a human"

fixture unlinked-author
echo '[{"author": null, "commit": {"verification": {"verified": true}}}]' >"${FIXTURES}/prcommits-1.json"
check_waits "a commit with no linked GitHub author waits for a human"

fixture error-disarms
set_pr '.autoMergeRequest = {"enabledBy": {"is_bot": true, "login": "app/bsky-release-bot"}}'
# Refresh can't read main's head, so the gate errors out after arming checks.
rm "${FIXTURES}/main-ref.json"
run_gate gate && rc=0 || rc=$?
if (( rc != 0 )) && disarmed; then pass "an error mid-gate withdraws the App's auto-merge"; else fail "an error mid-gate withdraws the App's auto-merge" "rc=${rc} $(cat "${FIXTURES}/calls")"; fi

fixture multi-package
jq -n --arg c "$(printf '{"cmd/example": "1.0.0"}' | base64)" '{content: $c}' >"${FIXTURES}/manifest-contents.json"
if run_gate gate; then fail "multi-package manifest fails closed" "gate exited 0"; elif merged_auto; then fail "multi-package manifest fails closed" "queued"; else pass "multi-package manifest fails closed"; fi

fixture disarm-ours
set_pr '.autoMergeRequest = {"enabledBy": {"is_bot": true, "login": "app/bsky-release-bot"}}'
if run_gate disarm && disarmed; then pass "disarm withdraws the App's auto-merge"; else fail "disarm withdraws the App's auto-merge" "$(cat "${FIXTURES}/out")"; fi

fixture disarm-human
set_pr '.autoMergeRequest = {"enabledBy": {"is_bot": false, "login": "some-human"}}'
run_gate disarm
if disarmed; then fail "disarm leaves a human's auto-merge alone" "disabled it"; else pass "disarm leaves a human's auto-merge alone"; fi

fixture withdraw-ineligible
set_pr '.autoMergeRequest = {"enabledBy": {"is_bot": true, "login": "app/bsky-release-bot"}}'
bot_pr c1 1 some-human
run_gate gate || true
if disarmed && ! merged_auto; then pass "gate withdraws the App's auto-merge when ineligible"; else fail "gate withdraws the App's auto-merge when ineligible" "$(cat "${FIXTURES}/calls")"; fi

fixture no-release-pr
echo '[]' >"${FIXTURES}/pr-list.json"
if run_gate gate && ! grep -q '^pr merge' "${FIXTURES}/calls"; then pass "no Release PR is a no-op"; else fail "no Release PR is a no-op" "$(cat "${FIXTURES}/out")"; fi

if (( failures > 0 )); then
  echo "${failures} scenario(s) failed"
  exit 1
fi
echo "all scenarios passed"
