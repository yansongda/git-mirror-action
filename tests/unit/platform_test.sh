#!/usr/bin/env bash
# ============================================================
# 平台插件 HTTP 层与契约单测（gitee / gitcode）
# 覆盖:
#   - 快速失败参数（API_CONNECT_TIMEOUT / API_TIMEOUT 落到 curl 参数）
#   - 瞬时故障（000/5xx）重试 1 次；4xx 不重试
#   - repo_exists 三态（0=存在 1=明确不存在(404) 2=无法判定）
#   - 默认分支 / 可见性状态缓存解析
#   - GitCode 走 PRIVATE-TOKEN 请求头（token 不落 URL）
#   - LFS 能力声明（platform_lfs_supported）
# 全离线（mock curl 经 PATH 前置生效）
# ============================================================
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROJECT_ROOT
set -uo pipefail
source "$PROJECT_ROOT/tests/lib/assert.sh"
source "$PROJECT_ROOT/tests/lib/env.sh"
export SCRIPT_DIR="$PROJECT_ROOT/scripts"
source "$SCRIPT_DIR/common.sh"
# 多平台同时 source（验证平台间无全局变量污染）
source "$SCRIPT_DIR/platforms/gitee.sh"
source "$SCRIPT_DIR/platforms/gitcode.sh"

FAKE_ROOT=/tmp/git-mirror-test-platform
rm -rf "$FAKE_ROOT"
setup_fake_env "$FAKE_ROOT"
mkdir -p "$FAKE_ROOT"

export DST_GITEE_ACCOUNT=test DST_GITEE_TOKEN=fake
export DST_GITCODE_ACCOUNT=test DST_GITCODE_TOKEN=fake
export API_RETRY_DELAY=0   # 重试退避不等待（CI 加速）
export MOCK_LOG_FILE="$FAKE_ROOT/api.log"

_req_log() { cat "$MOCK_LOG_FILE" 2>/dev/null || true; }
_req_count() { grep -c "$1" "$MOCK_LOG_FILE" 2>/dev/null || true; }

# ---------- repo_exists 三态: 200 ----------
t "gitee repo_exists 200 → 0 且缓存可见性与默认分支"
rm -f "$MOCK_LOG_FILE"
export MOCK_GITEE_EXISTS=true MOCK_DEST_PRIVATE=true MOCK_DEST_DEFAULT_BRANCH=main
DEST_REPO_PRIVATE=""; DEST_DEFAULT_BRANCH=""
platform_gitee_repo_exists test repo-a
assert_status 0 $?
assert_eq "true" "$DEST_REPO_PRIVATE"
assert_eq "main" "$DEST_DEFAULT_BRANCH"

# ---------- repo_exists 三态: 404（明确不存在才允许建仓） ----------
t "gitee repo_exists 404 → 1（明确不存在）"
export MOCK_GITEE_EXISTS=false
DEST_REPO_PRIVATE=""; DEST_DEFAULT_BRANCH=""
platform_gitee_repo_exists test repo-a
assert_status 1 $?
assert_eq "" "$DEST_REPO_PRIVATE"      # 失败路径不得写入状态缓存
assert_eq "" "$DEST_DEFAULT_BRANCH"

# ---------- 响应缺字段 → 不设缓存（安全降级为照常校正） ----------
t "repo_exists 响应缺字段时缓存留空（降级不误跳过校正）"
export MOCK_GITEE_EXISTS=true
unset MOCK_DEST_DEFAULT_BRANCH
DEST_REPO_PRIVATE=""; DEST_DEFAULT_BRANCH=""
platform_gitee_repo_exists test repo-a
assert_status 0 $?
assert_eq "" "$DEST_DEFAULT_BRANCH"    # 缺 default_branch → 留空 → 上层仍会 PATCH

# ---------- repo_exists 三态: 持续 000 ----------
t "gitee repo_exists 持续 000 → 2（无法判定，绝不当作不存在）"
rm -f "$MOCK_LOG_FILE"
export MOCK_API_FAIL_ALWAYS=000
platform_gitee_repo_exists test repo-a
assert_status 2 $?
assert_eq "2" "$(_req_count 'gitee.com/api/v5/repos')"   # 已重试 1 次
unset MOCK_API_FAIL_ALWAYS

# ---------- 瞬时 5xx 重试后成功 ----------
t "gitee request 瞬时 500 重试一次后成功"
rm -f "$MOCK_LOG_FILE" "$FAKE_ROOT/marker-500"
export MOCK_API_FAIL_ONCE=500 MOCK_API_FAIL_MARKER="$FAKE_ROOT/marker-500" MOCK_GITEE_EXISTS=true
DEST_REPO_PRIVATE=""; DEST_DEFAULT_BRANCH=""
out=$(platform_gitee_repo_exists test repo-a 2>&1)
assert_status 0 $?
assert_contains "$out" "Gitee API 异常 (HTTP 500)"
assert_eq "2" "$(_req_count 'gitee.com/api/v5/repos')"
unset MOCK_API_FAIL_ONCE MOCK_API_FAIL_MARKER

# ---------- curl 失败（000）同样重试 ----------
t "gitee request curl 失败（000）重试一次后成功"
rm -f "$MOCK_LOG_FILE" "$FAKE_ROOT/marker-000"
export MOCK_API_FAIL_ONCE=000 MOCK_API_FAIL_MARKER="$FAKE_ROOT/marker-000"
DEST_REPO_PRIVATE=""; DEST_DEFAULT_BRANCH=""
platform_gitee_repo_exists test repo-a
assert_status 0 $?
assert_eq "2" "$(_req_count 'gitee.com/api/v5/repos')"
unset MOCK_API_FAIL_ONCE MOCK_API_FAIL_MARKER

# ---------- 4xx 不重试（403 业务结果直接返回） ----------
t "gitee request 403 不重试（业务错误）"
rm -f "$MOCK_LOG_FILE"
export MOCK_API_FAIL_ALWAYS=403
platform_gitee_repo_exists test repo-a
assert_status 2 $?                       # 403 → 无法判定
assert_eq "1" "$(_req_count 'gitee.com/api/v5/repos')"   # 未重试
unset MOCK_API_FAIL_ALWAYS

# ---------- 超时参数落到 curl ----------
t "平台 request 层使用 API_TIMEOUT / API_CONNECT_TIMEOUT"
rm -f "$MOCK_LOG_FILE"
export MOCK_GITEE_EXISTS=true API_TIMEOUT=7
DEST_REPO_PRIVATE=""; DEST_DEFAULT_BRANCH=""
platform_gitee_repo_exists test repo-a
assert_contains "$(_req_log)" "--connect-timeout 10"
assert_contains "$(_req_log)" "--max-time 7"
unset API_TIMEOUT

# ---------- GitCode: 三态 + 认证头 ----------
t "gitcode repo_exists 200 → 0 且缓存状态"
rm -f "$MOCK_LOG_FILE"
export MOCK_GITCODE_EXISTS=true MOCK_DEST_PRIVATE=false MOCK_DEST_DEFAULT_BRANCH=main
DEST_REPO_PRIVATE=""; DEST_DEFAULT_BRANCH=""
platform_gitcode_repo_exists test repo-a
assert_status 0 $?
assert_eq "false" "$DEST_REPO_PRIVATE"
assert_eq "main" "$DEST_DEFAULT_BRANCH"

t "gitcode 认证走 PRIVATE-TOKEN 头（token 不落 URL）"
assert_contains "$(_req_log)" "PRIVATE-TOKEN: fake"
assert_not_contains "$(_req_log)" "access_token="

t "gitcode 写操作（PATCH）同样走 PRIVATE-TOKEN 头"
rm -f "$MOCK_LOG_FILE"
platform_gitcode_set_visibility test repo-a true
assert_status 0 $?
assert_contains "$(_req_log)" "PRIVATE-TOKEN: fake"
assert_not_contains "$(_req_log)" "access_token="
assert_contains "$(_req_log)" '"private":true'

t "gitcode repo_exists 404 → 1"
export MOCK_GITCODE_EXISTS=false
DEST_REPO_PRIVATE=""; DEST_DEFAULT_BRANCH=""
platform_gitcode_repo_exists test repo-a
assert_status 1 $?

# ---------- LFS 能力声明 ----------
t "platform_lfs_supported: 未声明平台默认支持"
platform_lfs_supported gitee
assert_status 0 $?

t "platform_lfs_supported: gitcode 声明不支持 LFS 镜像"
platform_lfs_supported gitcode
assert_status 1 $?

summary
