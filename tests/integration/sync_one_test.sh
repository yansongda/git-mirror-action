#!/usr/bin/env bash
# ============================================================
# sync-one.sh 集成测试（独立进程：成功/失败路径 + 状态文件）
# ============================================================
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROJECT_ROOT
source "$PROJECT_ROOT/tests/lib/assert.sh"
source "$PROJECT_ROOT/tests/lib/env.sh"

FAKE_ROOT=/tmp/git-mirror-test-sync1
rm -rf "$FAKE_ROOT"
setup_fake_env "$FAKE_ROOT"

export SRC_ACCOUNT=test SRC_TOKEN=fake DST_PRIVATE=auto REPO_TIMEOUT=60
export DST_GITEE_ACCOUNT=test DST_GITEE_TOKEN=fake
export DST_GITCODE_ACCOUNT=test DST_GITCODE_TOKEN=fake
export WORK_DIR="$FAKE_ROOT/workdir"

make_source_repo repo-a main
add_source_ref repo-a dev
make_empty_dest "$MOCK_GITEE_DIR/test"
make_empty_dest "$MOCK_GITCODE_DIR/test"

SYNC_ONE="env PATH=$PROJECT_ROOT/tests/mocks:$PATH HOME=$FAKE_ROOT/home bash $PROJECT_ROOT/scripts/sync-one.sh"

# ---------- 成功路径 ----------
t "sync-one.sh 成功: [OK] + 状态文件 + 目标同步"
out=$(mkdir -p "$FAKE_ROOT/home" && $SYNC_ONE repo-a true main)
assert_status 0 $?
assert_contains "$out" "[ OK ] repo-a"
assert_file_contains "$WORK_DIR/status/ok/list" "repo-a"
assert_eq "2" "$(git --git-dir="$MOCK_GITEE_DIR/test/repo-a.git" show-ref | wc -l | tr -d ' ')"

# ---------- 失败路径（源仓库不存在 → clone 失败） ----------
t "sync-one.sh 失败: [FAIL] + 状态文件"
out=$($SYNC_ONE no-such-repo true main)
assert_status 0 $?
assert_contains "$out" "[FAIL] no-such-repo"
assert_file_contains "$WORK_DIR/status/fail/list" "no-such-repo"

# ---------- 状态隔离 ----------
t "状态文件 ok/fail 互不串扰"
assert_eq "1" "$(wc -l < "$WORK_DIR/status/ok/list" | tr -d ' ')"
assert_eq "1" "$(wc -l < "$WORK_DIR/status/fail/list" | tr -d ' ')"
assert_not_contains "$(cat "$WORK_DIR/status/ok/list")" "no-such-repo"

# ---------- 缺参数 ----------
t "sync-one.sh 缺参数报错退出"
out=$(bash "$PROJECT_ROOT/scripts/sync-one.sh" 2>&1)
assert_status 1 $?
assert_contains "$out" "缺少参数"

summary
