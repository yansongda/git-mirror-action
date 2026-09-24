#!/usr/bin/env bash
# ============================================================
# git-mirror-action 编排入口
# 主流程见 main()，各步骤拆分为单一职责函数：
#   load_config → validate_config → setup_platforms → prepare_workdir
#   → print_banner → fetch_repos → filter_repos
#   → dry_run_mode | (sync_all + summarize + final_summary)
# 单仓库同步逻辑见 core.sh（每仓库一个独立进程）
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/gh.sh"

# ---------- 读取输入参数（action.yml 的 env 注入，含默认值） ----------
load_config() {
  SRC_ACCOUNT="${SRC_ACCOUNT:-}"
  SRC_TOKEN="${SRC_TOKEN:-}"
  SRC_ACCOUNT_TYPE="${SRC_ACCOUNT_TYPE:-user}"
  BLACKLIST="${BLACKLIST:-}"
  WHITELIST="${WHITELIST:-}"
  SKIP_FORKS="${SKIP_FORKS:-true}"
  SKIP_ARCHIVED="${SKIP_ARCHIVED:-false}"
  DST_PRIVATE="${DST_PRIVATE:-auto}"
  CONCURRENCY="${CONCURRENCY:-4}"
  REPO_TIMEOUT="${REPO_TIMEOUT:-600}"
  DRY_RUN="${DRY_RUN:-false}"
  DEBUG="${DEBUG:-false}"
  MIRROR_PRIVATE_KEY="${MIRROR_PRIVATE_KEY:-}"
  WORK_DIR="${WORK_DIR:-${RUNNER_TEMP:-/tmp}/git-mirror}"
}

# ---------- 参数校验 ----------
validate_config() {
  [[ -n "$SRC_ACCOUNT" ]] || die "SRC_ACCOUNT 不能为空"
  [[ -n "$SRC_TOKEN" ]] || die "SRC_TOKEN 不能为空"
  case "$SRC_ACCOUNT_TYPE" in
    user|org) ;;
    *) die "SRC_ACCOUNT_TYPE 仅支持 user/org (当前: $SRC_ACCOUNT_TYPE)" ;;
  esac
  [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || die "CONCURRENCY 必须为数字 (当前: $CONCURRENCY)"
  case "$DST_PRIVATE" in
    auto|true|false) ;;
    *) die "DST_PRIVATE 仅支持 auto/true/false (当前: $DST_PRIVATE)" ;;
  esac
}

# ---------- 发现目标平台 + 校验插件完整性 ----------
setup_platforms() {
  PLATFORMS=()
  while IFS= read -r p; do PLATFORMS+=("$p"); done < <(discover_platforms)
  [[ ${#PLATFORMS[@]} -gt 0 ]] || die "未发现目标平台，请配置 DST_*_ACCOUNT 环境变量（如 DST_GITEE_ACCOUNT）"
  for p in "${PLATFORMS[@]}"; do
    if ! platform_load "$p"; then
      die "平台插件缺失或加载失败: scripts/platforms/$p.sh"
    fi
    platform_validate "$p" || die "平台插件不完整: $p（参照 scripts/platforms/_template.sh 补齐）"
  done
  if [[ "$DRY_RUN" != true ]]; then
    [[ -n "$MIRROR_PRIVATE_KEY" ]] || die "MIRROR_PRIVATE_KEY 不能为空（推送用 SSH 私钥；dry_run 模式除外）"
  fi
}

# ---------- 初始化工作目录与认证 ----------
prepare_workdir() {
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"/logs "$WORK_DIR"/status/ok "$WORK_DIR"/status/fail
  init_ssh
  init_git_auth
}

# ---------- 打印运行概要 ----------
print_banner() {
  log "========== git-mirror-action =========="
  log "源:   $SRC_ACCOUNT ($SRC_ACCOUNT_TYPE)"
  log "目标: ${PLATFORMS[*]}"
  log "并发: $CONCURRENCY | 单命令超时: ${REPO_TIMEOUT}s | 目标可见性: $DST_PRIVATE"
  log "模式: $([ "$DRY_RUN" = true ] && echo DRY-RUN || echo 实际同步)"
}

# ---------- 拉取 GitHub 仓库列表（gh.sh） ----------
fetch_repos() {
  log "获取 GitHub 仓库列表..."
  gh_list_repos > "$WORK_DIR/repos.tsv"
  TOTAL=$(wc -l < "$WORK_DIR/repos.tsv" | tr -d ' ')
  log "共获取 $TOTAL 个仓库"
}

# ---------- 过滤（黑/白名单、fork、archived），结果写入 final.tsv ----------
filter_repos() {
  : > "$WORK_DIR/final.tsv"
  local skipped=0 name is_private is_fork is_archived def_branch shown
  while IFS=$'\t' read -r name is_private is_fork is_archived def_branch; do
    [[ -n "$name" ]] || continue
    shown=$(mask_repo "$name" "$is_private")
    if [[ -n "$BLACKLIST" ]] && in_list "$name" "$BLACKLIST"; then
      log "  跳过(黑名单): $shown"; skipped=$((skipped + 1)); continue
    fi
    if [[ -n "$WHITELIST" ]] && ! in_list "$name" "$WHITELIST"; then
      log "  跳过(非白名单): $shown"; skipped=$((skipped + 1)); continue
    fi
    if [[ "$SKIP_FORKS" == true && "$is_fork" == true ]]; then
      log "  跳过(fork): $shown"; skipped=$((skipped + 1)); continue
    fi
    if [[ "$SKIP_ARCHIVED" == true && "$is_archived" == true ]]; then
      log "  跳过(archived): $shown"; skipped=$((skipped + 1)); continue
    fi
    printf '%s\t%s\t%s\n' "$name" "$is_private" "$def_branch" >> "$WORK_DIR/final.tsv"
  done < "$WORK_DIR/repos.tsv"
  FINAL_COUNT=$(wc -l < "$WORK_DIR/final.tsv" | tr -d ' ')
  log "过滤后待同步 $FINAL_COUNT 个仓库（跳过 ${skipped}）"
}

# ---------- DRY-RUN：仅检查目标端状态，不产生任何推送 ----------
dry_run_mode() {
  log "===== DRY RUN：仅检查，不推送 ====="
  local name is_private def_branch p shown priv
  while IFS=$'\t' read -r name is_private def_branch; do
    shown=$(mask_repo "$name" "$is_private")
    for p in "${PLATFORMS[@]}"; do
      CURRENT_PLATFORM="$p"
      platform_load "$p" || continue
      acct=$(platform_account "$p")
      priv=$(resolve_private "$is_private" "$p")
      if platform_call repo_exists "$acct" "$name"; then
        printf '  [dry] %-30s → %s/%s: 已存在 (private=%s)\n' "$shown" "$p" "$acct" "$priv"
      else
        printf '  [dry] %-30s → %s/%s: 不存在 (将创建 private=%s)\n' "$shown" "$p" "$acct" "$priv"
      fi
    done
  done < "$WORK_DIR/final.tsv"
  log "DRY RUN 完成"
}

# ---------- 并发同步（每仓库一个 core.sh 进程） ----------
sync_all() {
  export SCRIPT_DIR WORK_DIR SRC_ACCOUNT SRC_TOKEN REPO_TIMEOUT DST_PRIVATE DEBUG
  log "开始同步（并发 ${CONCURRENCY}）..."
  xargs -P "$CONCURRENCY" -n 3 bash "$SCRIPT_DIR/core.sh" < "$WORK_DIR/final.tsv"
}

# ---------- 汇总：失败仓库详情（退出码由 main 统一判断） ----------
summarize() {
  local ok_n=0 fail_n=0 f is_private shown
  [[ -f "$WORK_DIR/status/ok/list" ]] && ok_n=$(wc -l < "$WORK_DIR/status/ok/list" | tr -d ' ')
  [[ -f "$WORK_DIR/status/fail/list" ]] && fail_n=$(wc -l < "$WORK_DIR/status/fail/list" | tr -d ' ')
  log "===== 汇总: 成功 $ok_n / 失败 $fail_n / 共 $FINAL_COUNT ====="
  if [[ "$fail_n" -gt 0 ]]; then
    log "失败仓库详情:"
    while IFS=$'\t' read -r f is_private; do
      shown=$(mask_repo "$f" "$is_private")
      log "  --- $shown ---"
      tail -20 "$WORK_DIR/logs/$f.log" | sed 's/^/      /'
    done < "$WORK_DIR/status/fail/list"
  else
    log "全部同步完成"
  fi
}

# ---------- 最终汇总（逐仓库成败 + 耗时一览表，结尾输出） ----------
final_summary() {
  local ok_n=0 fail_n=0 shown r priv st dur fp
  log "===== 最终汇总 ====="
  if [[ ! -f "$WORK_DIR/status/results.tsv" ]]; then
    log "  无同步记录"
    return
  fi
  while IFS=$'\t' read -r r priv st dur fp; do
    shown=$(mask_repo "$r" "$priv")
    if [[ "$st" == ok ]]; then
      printf '  [ OK ]  %-30s %4ss' "$shown" "$dur"
      # 第 5 列 = 平台级失败明细（仓库 OK 但某平台失败，不再静默吞掉）
      if [[ -n "$fp" ]]; then
        printf '   [部分平台失败: %s]' "$fp"
      fi
      printf '\n'
      ok_n=$((ok_n + 1))
    else
      printf '  [FAIL]  %-30s %4ss\n' "$shown" "$dur"
      fail_n=$((fail_n + 1))
    fi
  done < "$WORK_DIR/status/results.tsv"
  log "===== 成功 $ok_n / 失败 $fail_n / 共 $((ok_n + fail_n)) ====="
}

# ---------- 主流程 ----------
main() {
  load_config
  validate_config
  setup_platforms
  prepare_workdir
  print_banner
  fetch_repos
  filter_repos
  if [[ "$DRY_RUN" == true ]]; then
    dry_run_mode
  else
    sync_all
    summarize
    final_summary
    if [[ -f "$WORK_DIR/status/fail/list" && $(wc -l < "$WORK_DIR/status/fail/list" | tr -d ' ') -gt 0 ]]; then
      exit 1
    fi
  fi
}

main "$@"
