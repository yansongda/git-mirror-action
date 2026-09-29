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
export GH_RETRY_DELAY=0   # 重试退避不等待（CI 加速）

t "gh_list_repos 单页 TSV 输出"
export MOCK_GH_REPOS_JSON='[{"name":"repo-a","private":true,"fork":false,"archived":false,"default_branch":"main"},{"name":"repo-b","private":false,"fork":true,"archived":false,"default_branch":"master"}]'
assert_eq $'repo-a\ttrue\tfalse\tfalse\tmain\nrepo-b\tfalse\ttrue\tfalse\tmaster' "$(gh_list_repos)"

t "gh_list_repos org 模式路径"
export SRC_ACCOUNT_TYPE=org MOCK_GH_REPOS_JSON='[{"name":"org-repo","private":false,"fork":false,"archived":false,"default_branch":"main"}]'
assert_eq $'org-repo\tfalse\tfalse\tfalse\tmain' "$(gh_list_repos)"
unset SRC_ACCOUNT_TYPE

t "gh_list_repos org 模式跳过 token 归属校验"
export SRC_ACCOUNT_TYPE=org MOCK_GH_LOGIN=otheruser MOCK_GH_REPOS_JSON='[{"name":"org-repo","private":false,"fork":false,"archived":false,"default_branch":"main"}]'
assert_eq $'org-repo\tfalse\tfalse\tfalse\tmain' "$(gh_list_repos)"   # 不因 login 不一致而报错
unset SRC_ACCOUNT_TYPE MOCK_GH_LOGIN

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

t "gh_api 瞬时 5xx 自动重试 1 次后成功"
export MOCK_GH_FAIL_ONCE=true MOCK_GH_MARKER=/tmp/git-mirror-test-gh-retry-marker
rm -f "$MOCK_GH_MARKER"
export MOCK_GH_REPOS_JSON='[{"name":"repo-a","private":false,"fork":false,"archived":false,"default_branch":"main"}]'
out=$(gh_list_repos)
assert_status 0 $?
assert_contains "$out" "GitHub API 异常"          # 第一次失败输出了重试日志
assert_contains "$out" $'repo-a\tfalse\tfalse\tfalse\tmain'   # 重试后拿到正常数据
unset MOCK_GH_FAIL_ONCE MOCK_GH_MARKER

t "gh_api 持续 5xx 重试后仍失败"
export MOCK_GH_CODE=500
# 注意: 不用 out=$(gh_api ...) ——命令替换子 shell 内的全局变量不会传回
gh_api GET "/user/repos" >"$PROJECT_ROOT/tests/.gh-5xx.log" 2>&1
assert_eq "0" "$?"                          # 请求流程结束（成败看 API_CODE）
assert_eq "500" "$API_CODE"
assert_contains "$(cat "$PROJECT_ROOT/tests/.gh-5xx.log")" "GitHub API 异常"   # 输出了重试日志
rm -f "$PROJECT_ROOT/tests/.gh-5xx.log"
unset MOCK_GH_CODE

t "gh_api 状态码解析"
export MOCK_GH_REPOS_JSON='[]'
gh_api GET "/user/repos"
assert_status 0 $?
assert_eq "200" "$API_CODE"

t "gh_list_repos user 模式请求含 affiliation=owner（仅本人仓库）"
export MOCK_LOG_FILE=/tmp/git-mirror-test-gh-url.log; rm -f "$MOCK_LOG_FILE"
gh_list_repos >/dev/null
assert_contains "$(cat "$MOCK_LOG_FILE")" "affiliation=owner"
assert_contains "$(cat "$MOCK_LOG_FILE")" "visibility=all"
unset MOCK_LOG_FILE

t "gh_api 请求带连接超时与 API_TIMEOUT"
export API_TIMEOUT=9 MOCK_LOG_FILE=/tmp/git-mirror-test-gh-params.log
rm -f "$MOCK_LOG_FILE"
export MOCK_GH_REPOS_JSON='[]'
gh_api GET "/user/repos"
assert_status 0 $?
assert_contains "$(cat "$MOCK_LOG_FILE")" "--connect-timeout 10"
assert_contains "$(cat "$MOCK_LOG_FILE")" "--max-time 9"
unset MOCK_LOG_FILE API_TIMEOUT

t "token 归属校验: login 与 SRC_ACCOUNT 不一致时 die"
export MOCK_GH_LOGIN=otheruser
out=$(gh_list_repos 2>&1); rc=$?
assert_status 1 $rc
assert_contains "$out" "SRC_TOKEN 属于"
unset MOCK_GH_LOGIN

summary
