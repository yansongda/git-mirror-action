#!/usr/bin/env bash
# ============================================================
# git-mirror-action 单仓库同步进程
# 由 mirror.sh 通过 xargs 并发调用；也可单独运行调试:
#   bash scripts/sync-one.sh <repo> <is_private> <default_branch>
# 职责: 日志重定向 + 状态标记；不含同步业务逻辑（见 core.sh）
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/core.sh"

repo="${1:-}"
is_private="${2:-}"
def_branch="${3:-}"
[[ -n "$repo" ]] || die "缺少参数: <repo> <is_private> <default_branch>"

WORK_DIR="${WORK_DIR:-${RUNNER_TEMP:-/tmp}/git-mirror}"
mkdir -p "$WORK_DIR"/logs "$WORK_DIR"/status/ok "$WORK_DIR"/status/fail

logfile="$WORK_DIR/logs/$repo.log"

# 实时进度：开始行 + 耗时统计
start_ts=$(date +%s)
printf '  [sync] %-30s 开始同步 (默认分支: %s)\n' "$repo" "$def_branch"

# 子 shell 隔离执行：显式 set -e（子 shell 会继承外层的 set +e 状态，
# 且 if 条件上下文会禁用 errexit，因此必须在子 shell 内重新启用），
# sync_one 内任何命令失败即整体非零；输出 tee 到 stdout（实时可见）并归档日志
set +e
( set -e; sync_one "$repo" "$is_private" "$def_branch" ) 2>&1 | tee "$logfile"
rc=${PIPESTATUS[0]}
set -e

dur=$(( $(date +%s) - start_ts ))
if [[ $rc -eq 0 ]]; then
  printf '  [ OK ] %-30s (%ss)\n' "$repo" "$dur"
  echo "$repo" >> "$WORK_DIR/status/ok/list"
else
  printf '  [FAIL] %-30s (%ss)\n' "$repo" "$dur"
  echo "$repo" >> "$WORK_DIR/status/fail/list"
fi
exit 0
