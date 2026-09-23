#!/usr/bin/env bash
# ============================================================
# gh.sh 单元测试（GitHub 源端列表获取）
# ============================================================
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROJECT_ROOT
source "$PROJECT_ROOT/tests/lib/assert.sh"
export SCRIPT_DIR="$PROJECT_ROOT/scripts"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/gh.sh"
export PATH="$PROJECT_ROOT/tests/mocks:$PATH"

export SRC_ACCOUNT=test SRC_TOKEN=fake

t "gh_list_repos 单页 TSV 输出"
export MOCK_GH_REPOS_JSON='[{"name":"repo-a","private":true,"fork":false,"archived":false,"default_branch":"main"},{"name":"repo-b","private":false,"fork":true,"archived":false,"default_branch":"master"}]'
assert_eq $'repo-a\ttrue\tfalse\tfalse\tmain\nrepo-b\tfalse\ttrue\tfalse\tmaster' "$(gh_list_repos)"

t "gh_list_repos org 模式路径"
export SRC_ACCOUNT_TYPE=org MOCK_GH_REPOS_JSON='[{"name":"org-repo","private":false,"fork":false,"archived":false,"default_branch":"main"}]'
assert_eq $'org-repo\tfalse\tfalse\tfalse\tmain' "$(gh_list_repos)"
unset SRC_ACCOUNT_TYPE

t "gh_list_repos 分页(101 个仓库)"
export MOCK_GH_REPOS_JSON="$(jq -cn '[range(0;100) | {name:("repo-"+tostring), private:false, fork:false, archived:false, default_branch:"main"}]')"
export MOCK_GH_PAGE2_JSON='[{"name":"repo-100","private":false,"fork":false,"archived":false,"default_branch":"main"}]'
assert_eq "101" "$(gh_list_repos | wc -l | tr -d ' ')"
assert_contains "$(gh_list_repos)" "repo-100"
unset MOCK_GH_PAGE2_JSON

t "gh_list_repos API 失败退出非零"
export MOCK_GH_CODE=500
( gh_list_repos ) >/dev/null 2>&1
assert_status 1 $?
unset MOCK_GH_CODE

t "gh_api 状态码解析"
export MOCK_GH_REPOS_JSON='[]'
gh_api GET "/user/repos"
assert_status 0 $?
assert_eq "200" "$API_CODE"

summary
