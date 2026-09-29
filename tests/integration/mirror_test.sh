#!/usr/bin/env bash
# ============================================================
# mirror.sh 完整同步集成测试（xargs 并发 → 汇总与退出码）
# 场景1: 全部成功 → 退出码 0
# 场景2: 混入失败仓库 → 退出码 1 + 汇总统计
# ============================================================
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROJECT_ROOT
source "$PROJECT_ROOT/tests/lib/assert.sh"
source "$PROJECT_ROOT/tests/lib/env.sh"

FAKE_ROOT=/tmp/git-mirror-test-full
rm -rf "$FAKE_ROOT"
setup_fake_env "$FAKE_ROOT"

export SRC_ACCOUNT=test SRC_TOKEN=fake SRC_ACCOUNT_TYPE=user
export DST_PRIVATE=auto CONCURRENCY=2 REPO_TIMEOUT=120
export DST_GITEE_ACCOUNT=test DST_GITEE_TOKEN=fake
export DST_GITCODE_ACCOUNT=test DST_GITCODE_TOKEN=fake
export MIRROR_PRIVATE_KEY=fake-key

# ---------- 场景1: 全部成功 ----------
make_source_repo repo-a main
add_source_ref repo-a dev
add_source_ref repo-a t:v1.0
make_empty_dest "$MOCK_GITEE_DIR/test"
make_empty_dest "$MOCK_GITCODE_DIR/test"

export MOCK_GH_REPOS_JSON='[{"name":"repo-a","private":true,"fork":false,"archived":false,"default_branch":"main"}]'
export WORK_DIR="$FAKE_ROOT/workdir-ok"

out=$(env PATH=$PROJECT_ROOT/tests/mocks:$PATH HOME=$FAKE_ROOT/home \
  SRC_ACCOUNT=test SRC_TOKEN=fake SRC_ACCOUNT_TYPE=user \
  BLACKLIST= WHITELIST= SKIP_FORKS=false SKIP_ARCHIVED=false \
  DST_PRIVATE=auto CONCURRENCY=2 REPO_TIMEOUT=120 DRY_RUN=false \
  DST_GITEE_ACCOUNT=test DST_GITEE_TOKEN=fake \
  DST_GITCODE_ACCOUNT=test DST_GITCODE_TOKEN=fake \
  MIRROR_PRIVATE_KEY=fake-key WORK_DIR=$WORK_DIR \
  bash $PROJECT_ROOT/scripts/mirror.sh)
rc=$?

t "场景1: 退出码 0"
assert_status 0 $rc

t "场景1: 汇总 成功 1 / 失败 0"
assert_contains "$out" "汇总: 成功 1 / 失败 0"

t "场景1: 两平台 refs 完整(3)"
assert_eq "3" "$(git --git-dir="$MOCK_GITEE_DIR/test/repo-a.git" show-ref | wc -l | tr -d ' ')"
assert_eq "3" "$(git --git-dir="$MOCK_GITCODE_DIR/test/repo-a.git" show-ref | wc -l | tr -d ' ')"

# ---------- 场景2: 混入失败仓库 ----------
export MOCK_GH_REPOS_JSON='[{"name":"repo-a","private":false,"fork":false,"archived":false,"default_branch":"main"},{"name":"no-such-repo","private":false,"fork":false,"archived":false,"default_branch":"main"}]'
export WORK_DIR="$FAKE_ROOT/workdir-fail"

out=$(env PATH=$PROJECT_ROOT/tests/mocks:$PATH HOME=$FAKE_ROOT/home \
  SRC_ACCOUNT=test SRC_TOKEN=fake SRC_ACCOUNT_TYPE=user \
  BLACKLIST= WHITELIST= SKIP_FORKS=false SKIP_ARCHIVED=false \
  DST_PRIVATE=auto CONCURRENCY=2 REPO_TIMEOUT=120 DRY_RUN=false \
  DST_GITEE_ACCOUNT=test DST_GITEE_TOKEN=fake \
  DST_GITCODE_ACCOUNT=test DST_GITCODE_TOKEN=fake \
  MIRROR_PRIVATE_KEY=fake-key WORK_DIR=$WORK_DIR \
  bash $PROJECT_ROOT/scripts/mirror.sh)
rc=$?

t "场景2: 有失败退出码 1"
assert_status 1 $rc

t "场景2: 汇总 成功 1 / 失败 1"
assert_contains "$out" "汇总: 成功 1 / 失败 1"

t "场景2: 失败仓库清单输出"
assert_contains "$out" "失败仓库"
assert_contains "$out" "no-such-repo"

# ---------- 场景3: 最终汇总表（含私有仓库脱敏 + 耗时） ----------
t "场景3: 最终汇总表输出"
# 场景2 中 repo-a 为公开、no-such-repo 公开失败，但为验证私有脱敏单独构造
assert_contains "$out" "最终汇总"
assert_contains "$out" "成功 1 / 失败 1"

# ---------- 场景3: 全私有仓库最终汇总脱敏 ----------
export MOCK_GH_REPOS_JSON='[{"name":"private-one","private":true,"fork":false,"archived":false,"default_branch":"main"}]'
# 源仓库 private-one 不存在 → clone 失败，走失败路径
out=$(env PATH=$PROJECT_ROOT/tests/mocks:$PATH HOME=$FAKE_ROOT/home \
  SRC_ACCOUNT=test SRC_TOKEN=fake SRC_ACCOUNT_TYPE=user \
  BLACKLIST= WHITELIST= SKIP_FORKS=false SKIP_ARCHIVED=false \
  DST_PRIVATE=auto CONCURRENCY=2 REPO_TIMEOUT=120 DRY_RUN=false \
  DST_GITEE_ACCOUNT=test DST_GITEE_TOKEN=fake \
  DST_GITCODE_ACCOUNT=test DST_GITCODE_TOKEN=fake \
  MIRROR_PRIVATE_KEY=fake-key WORK_DIR=$FAKE_ROOT/workdir-priv \
  bash $PROJECT_ROOT/scripts/mirror.sh)
rc=$?
t "场景3: 私有仓库在最终汇总中脱敏"
assert_status 1 $rc
assert_contains "$out" "priv***"      # private-one → 前4位+***
assert_not_contains "$out" "private-one"

# ---------- 场景4: 平台级失败可见性（汇总计数 + annotation + Step Summary + strict） ----------
export MOCK_GH_REPOS_JSON='[{"name":"repo-a","private":true,"fork":false,"archived":false,"default_branch":"main"}]'
export WORK_DIR="$FAKE_ROOT/workdir-pfail"
export MOCK_PUSH_TIMEOUT=true    # 仅 gitee 的 push 超时 → 仓库 OK 但 gitee 平台失败
export GITHUB_STEP_SUMMARY="$FAKE_ROOT/step-summary.md"; rm -f "$GITHUB_STEP_SUMMARY"

out=$(env PATH=$PROJECT_ROOT/tests/mocks:$PATH HOME=$FAKE_ROOT/home \
  SRC_ACCOUNT=test SRC_TOKEN=fake SRC_ACCOUNT_TYPE=user \
  BLACKLIST= WHITELIST= SKIP_FORKS=false SKIP_ARCHIVED=false \
  DST_PRIVATE=auto CONCURRENCY=2 REPO_TIMEOUT=120 DRY_RUN=false API_RETRY_DELAY=0 \
  GITHUB_ACTIONS=true STRICT=false \
  DST_GITEE_ACCOUNT=test DST_GITEE_TOKEN=fake \
  DST_GITCODE_ACCOUNT=test DST_GITCODE_TOKEN=fake \
  MIRROR_PRIVATE_KEY=fake-key WORK_DIR=$WORK_DIR \
  bash $PROJECT_ROOT/scripts/mirror.sh)
rc=$?

t "场景4: strict 默认 false → 平台级失败不影响退出码"
assert_status 0 $rc

t "场景4: 汇总行含平台失败计数"
assert_contains "$out" "平台失败 1"
assert_contains "$out" "存在平台级失败"

t "场景4: 平台级失败显式列出 + CI annotation"
assert_contains "$out" "[平台失败] repo***: gitee"
assert_contains "$out" "::warning::repo*** 平台同步失败: gitee"

t "场景4: Step Summary 写入 markdown 表格（私有名脱敏）"
assert_file_contains "$GITHUB_STEP_SUMMARY" "| 仓库 | 可见性 | 状态 | 耗时 | 失败平台 |"
assert_file_contains "$GITHUB_STEP_SUMMARY" "| repo*** | private | ok |"
assert_file_contains "$GITHUB_STEP_SUMMARY" "gitee"
assert_not_contains "$(cat "$GITHUB_STEP_SUMMARY")" "repo-a"

t "场景4/5: strict=true 时平台级失败使 job 失败（退出码 1）"
out=$(env PATH=$PROJECT_ROOT/tests/mocks:$PATH HOME=$FAKE_ROOT/home \
  SRC_ACCOUNT=test SRC_TOKEN=fake SRC_ACCOUNT_TYPE=user \
  BLACKLIST= WHITELIST= SKIP_FORKS=false SKIP_ARCHIVED=false \
  DST_PRIVATE=auto CONCURRENCY=2 REPO_TIMEOUT=120 DRY_RUN=false API_RETRY_DELAY=0 \
  GITHUB_ACTIONS=true STRICT=true \
  DST_GITEE_ACCOUNT=test DST_GITEE_TOKEN=fake \
  DST_GITCODE_ACCOUNT=test DST_GITCODE_TOKEN=fake \
  MIRROR_PRIVATE_KEY=fake-key WORK_DIR=$WORK_DIR \
  bash $PROJECT_ROOT/scripts/mirror.sh)
rc=$?
assert_status 1 $rc
assert_contains "$out" "strict=true 且存在平台级失败"
unset MOCK_PUSH_TIMEOUT GITHUB_STEP_SUMMARY

summary
