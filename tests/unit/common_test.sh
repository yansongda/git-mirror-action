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

# ---------- 平台操作方法（mock curl；source 平台插件自包含实现） ----------
export PATH="$PROJECT_ROOT/tests/mocks:$PATH"
export DST_GITEE_TOKEN=fake DST_GITCODE_TOKEN=fake
export CURRENT_PLATFORM=gitee
source "$SCRIPT_DIR/platforms/gitee.sh"
export CURRENT_PLATFORM=gitcode
source "$SCRIPT_DIR/platforms/gitcode.sh"
export CURRENT_PLATFORM=gitee

# Gitee（form + access_token）
t "gitee repo_exists 存在(200)"
platform_gitee_repo_exists test repo-a
assert_status 0 $?

t "gitee repo_exists 不存在(404)"
export MOCK_GITEE_EXISTS=false
platform_gitee_repo_exists test repo-a
assert_status 1 $?
unset MOCK_GITEE_EXISTS

t "gitee create_repo 私有传 private=true(201)"
platform_gitee_create_repo test repo-a true
assert_status 0 $?

t "gitee create_repo 失败(500)"
export MOCK_CREATE_CODE=500
platform_gitee_create_repo test repo-a true
assert_status 1 $?
unset MOCK_CREATE_CODE

t "gitee set_default_branch(200)"
platform_gitee_set_default_branch test repo-a main
assert_status 0 $?

# GitCode（JSON body）
export CURRENT_PLATFORM=gitcode
t "gitcode create_repo 私有传 JSON private:true(201)"
platform_gitcode_create_repo test repo-a true
assert_status 0 $?

t "gitcode set_visibility 公开传 JSON private:false(200)"
platform_gitcode_set_visibility test repo-a false
assert_status 0 $?

t "gitcode set_visibility 失败(500)"
export MOCK_VISIBILITY_CODE=500
platform_gitcode_set_visibility test repo-a true
assert_status 1 $?
unset MOCK_VISIBILITY_CODE

t "gitcode set_default_branch(200)"
platform_gitcode_set_default_branch test repo-a main
assert_status 0 $?

# 分派: 平台未实现方法时报错
t "platform_call 未实现方法报错"
CURRENT_PLATFORM=gitcode
platform_call no_such_op test repo-a
assert_status 1 $?
CURRENT_PLATFORM=gitee

# 平台插件完整性校验
t "platform_validate 完整平台通过"
platform_fake_host() { echo fake; }
platform_fake_repo_exists() { return 0; }
platform_fake_create_repo() { return 0; }
platform_fake_set_visibility() { return 0; }
platform_fake_set_default_branch() { return 0; }
platform_validate fake
assert_status 0 $?

-t "platform_validate 缺失方法时报错"
platform_validate incomplete
assert_status 1 $?

summary
