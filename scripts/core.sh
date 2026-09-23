#!/usr/bin/env bash
# ============================================================
# git-mirror-action 同步核心：sync_one
# 被 sync-one.sh 进程加载，在单仓库独立进程内运行
# 依赖: common.sh（已 source，使用 log/sanitize/_timeout/
#       platform_account/platform_var/resolve_private/
#       platform_repo_exists/platform_create_repo/
#       platform_set_default_branch/discover_platforms）
# 需要环境变量: SRC_ACCOUNT / SRC_TOKEN / WORK_DIR / REPO_TIMEOUT
# ============================================================

# 同步单个仓库到全部目标平台
# 用法: sync_one <repo> <is_private:true|false> <default_branch>
sync_one() {
  local repo="$1" is_private="$2" def_branch="$3"
  local p acct priv

  log "== 开始同步: $repo (默认分支: $def_branch) =="

  # 1. clone --mirror（源端认证走 GIT_ASKPASS basic auth，token 不进 URL / 日志）
  if ! clone_out=$(_timeout git clone --mirror \
      "https://github.com/$SRC_ACCOUNT/$repo.git" "$WORK_DIR/$repo.git" 2>&1); then
    log "    [错误] clone 失败: $(printf '%s' "$clone_out" | sanitize | tail -3 | tr '\n' ' ')"
    return 1
  fi
  log "  clone 完成"

  # 2. 空仓库（无任何分支/tag）标记：仍建仓，但不推送
  local is_empty=false
  if ! git --git-dir="$WORK_DIR/$repo.git" show-ref --quiet 2>/dev/null; then
    is_empty=true
    log "  空仓库（无分支/tag），仅建仓不推送"
  fi

  # 3. 逐个目标平台
  local platform_ok=0
  while IFS= read -r p; do
    CURRENT_PLATFORM="$p"
    acct=$(platform_account "$p")
    if [[ -z "$acct" ]]; then
      log "  [warn] $p 未配置 $(platform_var "$p" ACCOUNT)，跳过"
      continue
    fi
    priv=$(resolve_private "$is_private" "$p")
    log "  → $p/$acct (private=$priv)"

    # 3a. 目标仓库不存在则创建
    if platform_call repo_exists "$acct" "$repo"; then
      log "    目标仓库已存在"
    elif platform_call create_repo "$acct" "$repo" "$priv"; then
      log "    目标仓库创建成功"
    else
      log "    [错误] 创建仓库失败 (HTTP $API_CODE): $(printf '%s' "$API_BODY" | sanitize | head -c 300)"
      continue
    fi

    # 3b. 校正可见性（跟随源，可修复历史误建为私有的公开仓库）
    if platform_call set_visibility "$acct" "$repo" "$priv"; then
      log "    可见性校正为 $([ "$priv" == true ] && echo private || echo public)"
    else
      log "    [warn] 校正可见性失败 (HTTP $API_CODE)"
    fi

    # 3c. 空仓库不推送（建仓即视为该平台成功）
    if [[ "$is_empty" == true ]]; then
      log "    空仓库，跳过推送"
      platform_ok=1
      continue
    fi

    # 3d. 增量推送（--mirror: 只推变化 + 删除目标端多余分支/tag）
    if ! push_out=$(_timeout git --git-dir="$WORK_DIR/$repo.git" push --mirror \
        "git@$(platform_host "$p"):$acct/$repo.git" 2>&1); then
      log "    [错误] push 失败（$(printf '%s' "$push_out" | sanitize | tail -2 | tr '\n' ' ')，重试一次..."
      if ! push_out=$(_timeout git --git-dir="$WORK_DIR/$repo.git" push --mirror \
          "git@$(platform_host "$p"):$acct/$repo.git" 2>&1); then
        log "    [错误] push 失败（重试后仍失败）: $(printf '%s' "$push_out" | sanitize | tail -2 | tr '\n' ' ')"
        continue
      fi
    fi
    log "    push 完成"
    platform_ok=1

    # 3e. 修正目标端默认分支（mirror push 不携带远端 HEAD）
    if platform_call set_default_branch "$acct" "$repo" "$def_branch"; then
      log "    默认分支已设为 $def_branch"
    else
      log "    [warn] 设置默认分支失败 (HTTP $API_CODE)"
    fi
  done < <(discover_platforms)

  # 4. 所有目标平台均失败才判定仓库同步失败（单平台失败不再被静默吞掉）
  if [[ $platform_ok -eq 0 ]]; then
    log "  [错误] 所有目标平台均同步失败"
    return 1
  fi

  log "== 同步完成: $repo =="
}
