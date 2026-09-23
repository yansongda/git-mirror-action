#!/usr/bin/env bash
# ============================================================
# core.sh 集成测试（独立进程：成功/失败路径 + 状态文件）
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

SYNC_ONE="env PATH=$PROJECT_ROOT/tests/mocks:$PATH HOME=$FAKE_ROOT/home bash $PROJECT_ROOT/scripts/core.sh"

# ---------- 成功路径（私有仓库 → 日志名脱敏） ----------
t "core.sh 成功: [OK] + 状态文件 + 目标同步（私有名脱敏）"
out=$(mkdir -p "$FAKE_ROOT/home" && $SYNC_ONE repo-a true main)
assert_status 0 $?
assert_contains "$out" "[ OK ] repo***"      # repo-a(private) → 前4位+***
assert_not_contains "$out" "[ OK ] repo-a"   # 真实名不得出现在日志
assert_file_contains "$WORK_DIR/status/ok/list" "repo-a"   # 内部状态文件仍用真实名
assert_eq "2" "$(git --git-dir="$MOCK_GITEE_DIR/test/repo-a.git" show-ref | wc -l | tr -d ' ')"

# ---------- 成功路径（公开仓库 → 日志名不脱敏） ----------
t "core.sh 成功: 公开仓库日志名不脱敏"
make_source_repo repo-pub main
make_empty_dest "$MOCK_GITEE_DIR/test" repo-pub
make_empty_dest "$MOCK_GITCODE_DIR/test" repo-pub
out=$($SYNC_ONE repo-pub false main)
assert_status 0 $?
assert_contains "$out" "[ OK ] repo-pub"
assert_contains "$out" "[sync] repo-pub"

# ---------- 失败路径（源仓库不存在 → clone 失败，日志名脱敏） ----------
t "core.sh 失败: [FAIL] + 状态文件（私有名脱敏）"
out=$($SYNC_ONE no-such-repo true main)
assert_status 0 $?
assert_contains "$out" "[FAIL] no-s***"      # no-such-repo(private) → 前4位+***
assert_not_contains "$out" "no-such-repo"
assert_file_contains "$WORK_DIR/status/fail/list" "no-such-repo"   # 状态文件仍存真实名

# ---------- 状态隔离 ----------
t "状态文件 ok/fail 互不串扰"
assert_eq "2" "$(wc -l < "$WORK_DIR/status/ok/list" | tr -d ' ')"   # repo-a + repo-pub
assert_eq "1" "$(wc -l < "$WORK_DIR/status/fail/list" | tr -d ' ')"
assert_not_contains "$(cat "$WORK_DIR/status/ok/list")" "no-such-repo"

# ---------- 缺参数 ----------
t "core.sh 缺参数报错退出"
out=$(bash "$PROJECT_ROOT/scripts/core.sh" 2>&1)
assert_status 1 $?
assert_contains "$out" "缺少参数"

summary
