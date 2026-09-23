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

  # 1. clone --mirror（PAT 经 http.extraHeader 传递，不进 URL / 日志）
  _timeout git -c "http.extraHeader=Authorization: token $SRC_TOKEN" clone --mirror \
    "https://github.com/$SRC_ACCOUNT/$repo.git" "$WORK_DIR/$repo.git" >/dev/null 2>&1
  log "  clone 完成"

  # 2. 空仓库（无任何分支/tag）标记：仍建仓，但不推送
  local is_empty=false
  if ! git --git-dir="$WORK_DIR/$repo.git" show-ref --quiet 2>/dev/null; then
    is_empty=true
    log "  空仓库（无分支/tag），仅建仓不推送"
  fi

  # 3. 逐个目标平台
  while IFS= read -r p; do
    acct=$(platform_account "$p")
    if [[ -z "$acct" ]]; then
      log "  [warn] $p 未配置 $(platform_var "$p" ACCOUNT)，跳过"
      continue
    fi
    priv=$(resolve_private "$is_private" "$p")
    log "  → $p/$acct (private=$priv)"

    # 3a. 目标仓库不存在则创建
    if platform_repo_exists "$p" "$acct" "$repo"; then
      log "    目标仓库已存在"
    elif platform_create_repo "$p" "$acct" "$repo" "$priv"; then
      log "    目标仓库创建成功"
    else
      log "    [错误] 创建仓库失败 (HTTP $API_CODE): $(printf '%s' "$API_BODY" | sanitize | head -c 300)"
      continue
    fi

    # 3b. 空仓库不推送
    if [[ "$is_empty" == true ]]; then
      log "    空仓库，跳过推送"
      continue
    fi

    # 3c. 增量推送（--mirror: 只推变化 + 删除目标端多余分支/tag）
    if ! _timeout git --git-dir="$WORK_DIR/$repo.git" push --mirror \
        "git@$(platform_host "$p"):$acct/$repo.git" 2>&1 | sanitize; then
      log "    push 失败，重试一次..."
      if ! _timeout git --git-dir="$WORK_DIR/$repo.git" push --mirror \
          "git@$(platform_host "$p"):$acct/$repo.git" 2>&1 | sanitize; then
        log "    [错误] push 失败"
        continue
      fi
    fi
    log "    push 完成"

    # 3d. 修正目标端默认分支（mirror push 不携带远端 HEAD）
    if platform_set_default_branch "$p" "$acct" "$repo" "$def_branch"; then
      log "    默认分支已设为 $def_branch"
    else
      log "    [warn] 设置默认分支失败 (HTTP $API_CODE)"
    fi
  done < <(discover_platforms)

  log "== 同步完成: $repo =="
}
