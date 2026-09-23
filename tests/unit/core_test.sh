#!/usr/bin/env bash
# ============================================================
# core.sh 单元测试（sync_one 同步核心）
# 使用 fake 仓库 + mock git/curl，全离线
# ============================================================
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROJECT_ROOT
set -uo pipefail   # 与 sync-one.sh 一致：管道失败需真实传播
source "$PROJECT_ROOT/tests/lib/assert.sh"
source "$PROJECT_ROOT/tests/lib/env.sh"
export SCRIPT_DIR="$PROJECT_ROOT/scripts"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/core.sh"

FAKE_ROOT=/tmp/git-mirror-test-core
rm -rf "$FAKE_ROOT"
setup_fake_env "$FAKE_ROOT"

export SRC_ACCOUNT=test SRC_TOKEN=fake DST_PRIVATE=auto REPO_TIMEOUT=60
export DST_GITEE_ACCOUNT=test DST_GITEE_TOKEN=fake
export DST_GITCODE_ACCOUNT=test DST_GITCODE_TOKEN=fake
WORK_DIR="$FAKE_ROOT/workdir"
mkdir -p "$WORK_DIR"

# 准备环境: 源仓库 repo-a（main+dev+v1.0），两平台空目标
make_source_repo repo-a main
add_source_ref repo-a dev
add_source_ref repo-a t:v1.0
make_empty_dest "$MOCK_GITEE_DIR/test"
make_empty_dest "$MOCK_GITCODE_DIR/test"

# ---------- 成功全链路 ----------
t "sync_one 全链路: 建仓+推送+默认分支"
( set -e; sync_one repo-a true main ) >"$WORK_DIR/sync.log" 2>&1
assert_status 0 $?
assert_eq "3" "$(git --git-dir="$MOCK_GITEE_DIR/test/repo-a.git" show-ref | wc -l | tr -d ' ')"
assert_eq "3" "$(git --git-dir="$MOCK_GITCODE_DIR/test/repo-a.git" show-ref | wc -l | tr -d ' ')"
assert_file_contains "$WORK_DIR/sync.log" "默认分支已设为 main"

# ---------- 空仓库 ----------
t "sync_one 空仓库仅建仓不推送"
git init --bare "$MOCK_GH_DIR/test/empty-repo.git" -q
( set -e; sync_one empty-repo true main ) >"$WORK_DIR/empty.log" 2>&1
assert_status 0 $?
assert_file_contains "$WORK_DIR/empty.log" "仅建仓不推送"
assert_file_contains "$WORK_DIR/empty.log" "目标仓库创建成功"   # 空仓库也要建仓
assert_not_contains "$(cat "$WORK_DIR/empty.log")" "push 完成"  # 但不推送
rm -rf "$WORK_DIR/empty-repo.git"

# ---------- 建仓失败不中断其他平台（放最后：会删除 gitee 目标仓库） ----------
t "sync_one 建仓失败仅跳过该平台"
export MOCK_GITEE_EXISTS=false MOCK_GITCODE_EXISTS=true MOCK_CREATE_CODE=500
rm -rf "$MOCK_GITEE_DIR/test/repo-a.git" "$WORK_DIR/repo-a.git"
( set -e; sync_one repo-a true main ) >"$WORK_DIR/createfail.log" 2>&1
assert_status 0 $?
assert_file_contains "$WORK_DIR/createfail.log" "创建仓库失败"
assert_file_contains "$WORK_DIR/createfail.log" "push 完成"     # gitcode 不受影响
unset MOCK_GITEE_EXISTS MOCK_GITCODE_EXISTS MOCK_CREATE_CODE
rm -rf "$WORK_DIR/repo-a.git"

# ---------- push 失败重试（需先恢复 gitee 目标仓库） ----------
t "sync_one push 失败自动重试成功"
export MOCK_FAIL_PUSH=true MOCK_FAIL_MARKER="$FAKE_ROOT/push-fail-marker"
rm -f "$MOCK_FAIL_MARKER"
mkdir -p "$MOCK_GITEE_DIR/test"
git init --bare "$MOCK_GITEE_DIR/test/repo-a.git" -q
( set -e; sync_one repo-a true main ) >"$WORK_DIR/retry.log" 2>&1
assert_status 0 $?
assert_file_contains "$WORK_DIR/retry.log" "push 失败，重试一次"
assert_file_contains "$WORK_DIR/retry.log" "push 完成"
unset MOCK_FAIL_PUSH MOCK_FAIL_MARKER
rm -rf "$WORK_DIR/repo-a.git"

# ---------- 默认分支失败仅警告 ----------
t "sync_one 默认分支设置失败仅警告"
export MOCK_PATCH_CODE=500
( set -e; sync_one repo-a true main ) >"$WORK_DIR/patchfail.log" 2>&1
assert_status 0 $?
assert_file_contains "$WORK_DIR/patchfail.log" "[warn] 设置默认分支失败"
unset MOCK_PATCH_CODE

summary
