#!/usr/bin/env bash
# ============================================================
# common.sh 单元测试
# ============================================================
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROJECT_ROOT
source "$PROJECT_ROOT/tests/lib/assert.sh"
export SCRIPT_DIR="$PROJECT_ROOT/scripts"
source "$SCRIPT_DIR/common.sh"

# ---------- in_list ----------
t "in_list 命中"
in_list "repo-a" "repo-a,repo-b"
assert_status 0 $?

t "in_list 未命中"
in_list "repo-c" "repo-a,repo-b"
assert_status 1 $?

t "in_list 空列表"
in_list "repo-a" ""
assert_status 1 $?

# ---------- platform_var / account / token ----------
t "platform_var 命名"
assert_eq "DST_GITEE_ACCOUNT" "$(platform_var gitee ACCOUNT)"

t "platform_account 读取"
export DST_GITEE_ACCOUNT=mygitee
assert_eq "mygitee" "$(platform_account gitee)"
unset DST_GITEE_ACCOUNT

t "platform_account 未配置返回空"
assert_eq "" "$(platform_account gitee)"

t "platform_token 读取"
export DST_GITCODE_TOKEN=mysecret
assert_eq "mysecret" "$(platform_token gitcode)"
unset DST_GITCODE_TOKEN

# ---------- discover_platforms ----------
t "discover_platforms 多平台排序去重"
export DST_GITEE_ACCOUNT=a DST_GITEE_TOKEN=should-not-match DST_GITCODE_ACCOUNT=b
assert_eq $'gitcode\ngitee' "$(discover_platforms)"
unset DST_GITEE_ACCOUNT DST_GITEE_TOKEN DST_GITCODE_ACCOUNT

t "discover_platforms 无平台返回空"
assert_eq "" "$(discover_platforms)"

# ---------- resolve_private ----------
t "resolve_private auto 跟随源(私有)"
export DST_PRIVATE=auto
assert_eq "true" "$(resolve_private true gitee)"

t "resolve_private auto 跟随源(公开)"
assert_eq "false" "$(resolve_private false gitee)"

t "resolve_private 全局强制私有"
export DST_PRIVATE=true
assert_eq "true" "$(resolve_private false gitee)"

t "resolve_private 全局强制公开"
export DST_PRIVATE=false
assert_eq "false" "$(resolve_private true gitee)"

t "resolve_private 平台覆盖优先于全局"
export DST_PRIVATE=auto DST_GITEE_PRIVATE=true
assert_eq "true" "$(resolve_private false gitee)"
assert_eq "false" "$(resolve_private false gitcode)"
unset DST_GITEE_PRIVATE

t "resolve_private 平台覆盖 false"
export DST_GITEE_PRIVATE=false
assert_eq "false" "$(resolve_private true gitee)"
unset DST_GITEE_PRIVATE

# ---------- sanitize ----------
t "sanitize 脱敏 access_token"
assert_contains "$(printf 'a access_token=abc123 b' | sanitize)" 'access_token=***'
assert_not_contains "$(printf 'a access_token=abc123 b' | sanitize)" 'abc123'

t "sanitize 脱敏 Authorization 头"
assert_contains "$(printf 'Authorization: token abc123' | sanitize)" 'Authorization: token ***'

t "sanitize 原文无 token 不变"
assert_eq "hello world" "$(printf 'hello world' | sanitize)"

# ---------- dst_api（mock curl） ----------
export PATH="$PROJECT_ROOT/tests/mocks:$PATH"
export DST_GITEE_TOKEN=fake DST_GITCODE_TOKEN=fake

t "dst_api GET 仓库存在(200)"
dst_api GET gitee "/repos/test/repo-a"
assert_status 0 $?
assert_eq "200" "$API_CODE"

t "dst_api GET 仓库不存在(404)"
export MOCK_GITEE_EXISTS=false
dst_api GET gitee "/repos/test/repo-a"
assert_status 0 $?   # dst_api 只负责请求与状态解析，业务成败由上层函数判断
assert_eq "404" "$API_CODE"
unset MOCK_GITEE_EXISTS

t "dst_api POST 建仓(201)"
dst_api POST gitee "/user/repos" "name=repo-a&private=true"
assert_status 0 $?
assert_eq "201" "$API_CODE"

t "dst_api POST 建仓失败(500) 状态解析"
export MOCK_CREATE_CODE=500
dst_api POST gitee "/user/repos" "name=repo-a&private=true"
assert_status 0 $?
assert_eq "500" "$API_CODE"
unset MOCK_CREATE_CODE

t "dst_api PATCH 默认分支(200)"
dst_api PATCH gitcode "/repos/test/repo-a" "default_branch=main"
assert_status 0 $?
assert_eq "200" "$API_CODE"

t "dst_api PATCH 失败(500) 状态解析"
export MOCK_PATCH_CODE=500
dst_api PATCH gitee "/repos/test/repo-a" "default_branch=main"
assert_status 0 $?
assert_eq "500" "$API_CODE"
unset MOCK_PATCH_CODE

summary
