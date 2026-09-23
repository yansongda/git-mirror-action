#!/usr/bin/env bash
# ============================================================
# git-mirror-action 单仓库同步（业务函数 + 进程入口）
#
# 执行（由 mirror.sh 经 xargs 并发调用，也可单独调试）:
#   bash scripts/core.sh <repo> <is_private> <default_branch>
# source（供测试加载 sync_one 函数）:
#   source scripts/core.sh
#
# 职责: 同步业务逻辑（sync_one + 子函数 clone_mirror/mirror_push/
#        sync_to_platform）+ 进程入口（main）
# 依赖: common.sh（log/sanitize/_timeout/platform_*）
# 需要环境变量: SRC_ACCOUNT / SRC_TOKEN / WORK_DIR / REPO_TIMEOUT / DST_PRIVATE
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

source "$SCRIPT_DIR/common.sh"

# ---------- 错误摘要（脱敏 + 截断 + 单行化，token 永不落入日志） ----------
err_tail() { # <行数> <文本> [最大字符数]
  local out
  out=$(printf '%s' "$2" | sanitize | tail -"$1" | tr '\n' ' ')
  if [[ -n "${3:-}" ]]; then
    printf '%s' "$out" | head -c "$3"
  else
    printf '%s' "$out"
  fi
}

# ---------- 克隆镜像仓库（源端认证走 GIT_ASKPASS basic auth，token 不进 URL / 日志） ----------
# 通过全局 IS_EMPTY 传值（同 common.sh 的 CURRENT_PLATFORM 模式）：
# 函数内 log 走 stdout，若用命令替换捕获返回值会把日志一起吞掉
clone_mirror() { # <repo> → 设置 IS_EMPTY=true(空)|false；非零退出 = clone 失败
  local repo="$1" clone_out

  if ! clone_out=$(_timeout git clone --mirror \
      "https://github.com/$SRC_ACCOUNT/$repo.git" "$WORK_DIR/$repo.git" 2>&1); then
    log "    [错误] clone 失败: $(err_tail 3 "$clone_out")"
    return 1
  fi
  log "  clone 完成"

  # 空仓库（无任何分支/tag）标记：仍建仓，但不推送
  if git --git-dir="$WORK_DIR/$repo.git" show-ref --quiet 2>/dev/null; then
    IS_EMPTY=false
  else
    log "  空仓库（无分支/tag），仅建仓不推送"
    IS_EMPTY=true
  fi
}

# ---------- 镜像推送（--mirror: 只推变化 + 删除目标端多余分支/tag；失败重试一次） ----------
mirror_push() { # <acct> <repo> → 0/1
  local acct="$1" repo="$2" url push_out attempt
  url="git@$(platform_host "$CURRENT_PLATFORM"):$acct/$repo.git"

  for attempt in 1 2; do
    if push_out=$(_timeout git --git-dir="$WORK_DIR/$repo.git" push --mirror "$url" 2>&1); then
      return 0
    fi
    log "    [错误] push 失败（第 $attempt 次）: $(err_tail 2 "$push_out")"
  done
  return 1
}

# ---------- 同步单个目标平台 ----------
# 步骤: 加载/校验插件 → 建仓 → 校正可见性 → 推送 → 设默认分支
sync_to_platform() { # <platform> <repo> <is_private> <def_branch> <is_empty> → 0/1
  local p="$1" repo="$2" is_private="$3" def_branch="$4" is_empty="$5" acct priv

  CURRENT_PLATFORM="$p"
  platform_load "$p" || { log "  [warn] $p 插件加载失败，跳过"; return 1; }
  platform_validate "$p" || { log "  [warn] $p 插件不完整，跳过"; return 1; }
  acct=$(platform_account "$p")
  if [[ -z "$acct" ]]; then
    log "  [warn] $p 未配置 $(platform_var "$p" ACCOUNT)，跳过"
    return 1
  fi
  priv=$(resolve_private "$is_private" "$p")
  log "  → $p/$acct (private=$priv)"

  # 目标仓库不存在则创建
  if platform_call repo_exists "$acct" "$repo"; then
    log "    目标仓库已存在"
  elif platform_call create_repo "$acct" "$repo" "$priv"; then
    log "    目标仓库创建成功"
  else
    log "    [错误] 创建仓库失败 (HTTP $API_CODE): $(err_tail 1 "$API_BODY" 300)"
    return 1
  fi

  # 校正可见性（跟随源，可修复历史误建为私有的公开仓库）
  if platform_call set_visibility "$acct" "$repo" "$priv"; then
    log "    可见性校正为 $([ "$priv" == true ] && echo private || echo public)"
  else
    log "    [warn] 校正可见性失败 (HTTP $API_CODE)"
  fi

  # 空仓库不推送（建仓即视为该平台成功）
  if [[ "$is_empty" == true ]]; then
    log "    空仓库，跳过推送"
    return 0
  fi

  # 增量推送（--mirror: 只推变化 + 删除目标端多余分支/tag）
  if ! mirror_push "$acct" "$repo"; then
    return 1
  fi
  log "    push 完成"

  # 修正目标端默认分支（mirror push 不携带远端 HEAD）
  if platform_call set_default_branch "$acct" "$repo" "$def_branch"; then
    log "    默认分支已设为 $def_branch"
  else
    log "    [warn] 设置默认分支失败 (HTTP $API_CODE)"
  fi
  return 0
}

# ---------- 同步单个仓库到全部目标平台 ----------
# 用法: sync_one <repo> <is_private:true|false> <default_branch>
sync_one() {
  local repo="$1" is_private="$2" def_branch="$3" p platform_ok=0
  IS_EMPTY=false

  log "== 开始同步: $repo (默认分支: $def_branch) =="

  # 1. 克隆镜像仓库 + 空仓库检测（IS_EMPTY 由 clone_mirror 设置）
  clone_mirror "$repo" || return 1

  # 2. 逐个目标平台（任一平台成功即仓库整体成功）
  while IFS= read -r p; do
    sync_to_platform "$p" "$repo" "$is_private" "$def_branch" "$IS_EMPTY" \
      && platform_ok=1
  done < <(discover_platforms)

  # 3. 所有目标平台均失败才判定仓库同步失败（单平台失败不再被静默吞掉）
  if [[ $platform_ok -eq 0 ]]; then
    log "  [错误] 所有目标平台均同步失败"
    return 1
  fi

  log "== 同步完成: $repo =="
}

# ---------- 进程入口（仅被直接执行时；被 source 时只加载函数供测试） ----------
main() {
  set -euo pipefail

  local repo="${1:-}" is_private="${2:-}" def_branch="${3:-}"
  local logfile rc start_ts dur
  [[ -n "$repo" ]] || die "缺少参数: <repo> <is_private> <default_branch>"

  WORK_DIR="${WORK_DIR:-${RUNNER_TEMP:-/tmp}/git-mirror}"
  mkdir -p "$WORK_DIR"/logs "$WORK_DIR"/status/ok "$WORK_DIR"/status/fail

  logfile="$WORK_DIR/logs/$repo.log"

  # 实时进度：开始行 + 耗时统计
  start_ts=$(date +%s)
  printf '  [sync] %-30s 开始同步 (默认分支: %s)\n' "$repo" "$def_branch"

  # 子 shell 隔离执行：显式 set -e（子 shell 会继承外层的 set +e 状态，
  # 且 if 条件上下文会禁用 errexit，因此必须在子 shell 内重新启用），
  # sync_one 内任何命令失败即整体非零；输出经 sed 加仓库名前缀（并发可区分）
  # 并 tee 到 stdout（实时可见）与日志文件
  set +e
  ( set -e; sync_one "$repo" "$is_private" "$def_branch" ) 2>&1 \
    | sed "s/^/[$repo] /" | tee "$logfile"
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

  # 统一 exit 0：失败经 status/fail/list 上报（mirror.sh 的 summarize 汇总），
  # 避免 xargs 因单仓库非零而中断整个并发批次
  exit 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
