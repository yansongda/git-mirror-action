#!/usr/bin/env bash
# ============================================================
# mirror.sh dry-run 集成测试（过滤 + 建仓检查 + 不产生推送）
# ============================================================
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROJECT_ROOT
source "$PROJECT_ROOT/tests/lib/assert.sh"
source "$PROJECT_ROOT/tests/lib/env.sh"

FAKE_ROOT=/tmp/git-mirror-test-dryrun
rm -rf "$FAKE_ROOT"
setup_fake_env "$FAKE_ROOT"

export SRC_ACCOUNT=test SRC_TOKEN=fake SRC_ACCOUNT_TYPE=user
export DST_PRIVATE=auto CONCURRENCY=2 REPO_TIMEOUT=60
export DST_GITEE_ACCOUNT=test DST_GITEE_TOKEN=fake
export DST_GITCODE_ACCOUNT=test DST_GITCODE_TOKEN=fake
export MIRROR_PRIVATE_KEY=unused WORK_DIR="$FAKE_ROOT/workdir"

# GitHub 返回 4 个仓库: 私有/公开/黑名单/fork
export MOCK_GH_REPOS_JSON='[{"name":"private-repo","private":true,"fork":false,"archived":false,"default_branch":"main"},{"name":"public-repo","private":false,"fork":false,"archived":false,"default_branch":"main"},{"name":"black-repo","private":false,"fork":false,"archived":false,"default_branch":"main"},{"name":"fork-repo","private":false,"fork":true,"archived":false,"default_branch":"main"}]'
# gitee 已有 public-repo，其余不存在
export MOCK_GITEE_EXISTS=false

RUN="env PATH=$PROJECT_ROOT/tests/mocks:$PATH \
SRC_ACCOUNT=test SRC_TOKEN=fake SRC_ACCOUNT_TYPE=user \
BLACKLIST=black-repo WHITELIST= SKIP_FORKS=true SKIP_ARCHIVED=false \
DST_PRIVATE=auto CONCURRENCY=2 REPO_TIMEOUT=60 DRY_RUN=true DEBUG=false \
DST_GITEE_ACCOUNT=test DST_GITEE_TOKEN=fake \
DST_GITCODE_ACCOUNT=test DST_GITCODE_TOKEN=fake \
MIRROR_PRIVATE_KEY=unused WORK_DIR=$FAKE_ROOT/workdir \
bash $PROJECT_ROOT/scripts/mirror.sh"

out=$($RUN)
rc=$?

t "dry-run 退出码 0"
assert_status 0 $rc

t "dry-run 过滤黑名单"
assert_contains "$out" "跳过(黑名单): black-repo"

t "dry-run 过滤 fork"
assert_contains "$out" "跳过(fork): fork-repo"

t "dry-run 可见性跟随源（私有→private=true）"
assert_contains "$out" "private=true"

t "dry-run 建仓判断输出"
assert_contains "$out" "不存在 (将创建"
assert_contains "$out" "DRY RUN 完成"

t "dry-run 不产生任何 clone（无 git 调用）"
assert_not_contains "$out" "clone"

summary
