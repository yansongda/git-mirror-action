#!/usr/bin/env bash
# ============================================================
# git-mirror-action 通用基础库（幂等，可重复 source）
# 包含: 日志/脱敏/超时/列表判断/平台发现与账号读取/可见性计算/
#       SSH 初始化/目标端 API 封装与默认平台操作
# 需要环境变量: SCRIPT_DIR（平台插件目录定位）
# ============================================================

# ---------- 日志 ----------
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "错误: $*" >&2; exit 1; }

# ---------- 脱敏（token 永不落入日志） ----------
sanitize() {
  sed -E 's#(access_token=)[^&"[:space:]]+#\1***#g; s#(Authorization: (token|Bearer) )[^"[:space:]]+#\1***#g'
}

# ---------- 私有仓库名称脱敏（公开仓库原样输出） ----------
# 私有仓库日志中只显示开头 N 位 + ***（N = MASK_REPO_KEEP，默认 4，可覆盖）
mask_repo() { # <repo> <is_private:true|false> → 日志显示名
  local repo="$1" is_private="$2" len=${#1} keep="${MASK_REPO_KEEP:-4}" n
  [[ "$is_private" == true ]] || { printf '%s' "$repo"; return; }
  n=$keep
  if (( n >= len )); then
    # 仓库名过短时至少保留 1 位，避免完整暴露
    n=$(( len > 1 ? len - 1 : 0 ))
  fi
  printf '%s%s' "${repo:0:n}" '***'
}

# ---------- 错误文本内私有仓库名脱敏（URL / API body 中的仓库名替换为显示名） ----------
# 需先经 mask_repo 得到显示名；公开仓库（显示名==原名）直接原样返回
redact_repo() { # <text> <owner> <repo> → 替换后的文本
  local text="$1" owner="$2" repo="$3" shown
  shown=$(mask_repo "$repo" "${REPO_MASK_PRIVATE:-false}")
  [[ "$shown" == "$repo" ]] && { printf '%s' "$text"; return; }
  # 先替换 owner/repo 形态（URL / full_name），再替换裸仓库名
  text="${text//$owner\/$repo/$owner/$shown}"
  printf '%s' "${text//$repo/$shown}"
}

# ---------- 命令超时（Linux 用 timeout；macOS 无则直接执行） ----------
if command -v timeout >/dev/null 2>&1; then
  _timeout() { timeout "${REPO_TIMEOUT:-600}" "$@"; }
else
  _timeout() { "$@"; }
fi

# ---------- 列表判断（逗号分隔） ----------
in_list() { # item "csv,list"
  local item="$1" x
  local IFS=','
  for x in $2; do
    [[ "$item" == "$x" ]] && return 0
  done
  return 1
}

# ---------- 平台账号 / token 读取（环境变量 DST_<PLATFORM>_ACCOUNT / DST_<PLATFORM>_TOKEN） ----------
platform_var() { printf 'DST_%s_%s' "$(printf '%s' "$1" | tr 'a-z' 'A-Z')" "$2"; }
platform_account() { local v; v=$(platform_var "$1" ACCOUNT); printf '%s' "${!v:-}"; }
platform_token()   { local v; v=$(platform_var "$1" TOKEN);   printf '%s' "${!v:-}"; }

# 扫描环境变量发现目标平台列表
discover_platforms() {
  env | sed -n 's/^DST_\([A-Z0-9_]*\)_ACCOUNT=.*/\1/p' | sort -u | tr 'A-Z' 'a-z'
}

# ---------- 平台插件加载（source platforms/<name>.sh，声明变量 / 可选覆盖 dst_api） ----------
platform_load() { # platform（加载插件：元数据函数 + 操作方法）
  local file="$SCRIPT_DIR/platforms/$1.sh"
  if [[ ! -f "$file" ]]; then
    log "  [错误] 平台插件文件不存在: platforms/$1.sh"
    return 1
  fi
  source "$file" || { log "  [错误] 平台插件加载失败: platforms/$1.sh"; return 1; }
}

platform_host() { # platform → host（用于 SSH push URL 与 known_hosts）
  local fn="platform_${1}_host"
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn"
  else
    echo "$1"
  fi
}

# ---------- 目标端可见性计算 ----------
# 优先级: DST_<PLATFORM>_PRIVATE > dst_private(auto/true/false) > 跟随源仓库可见性
resolve_private() { # is_private platform → true|false
  local override_var override
  override_var=$(platform_var "$2" PRIVATE)
  override="${!override_var:-}"
  if [[ -n "$override" ]]; then
    [[ "$override" == false ]] && echo false || echo true
    return
  fi
  case "${DST_PRIVATE:-auto}" in
    true)  echo true ;;
    false) echo false ;;
    *)     [[ "$1" == true ]] && echo true || echo false ;;
  esac
}

# ---------- 目标端 API（Gitee v5 风格默认实现；平台插件可覆盖 dst_api 适配异构平台） ----------
# 用法: dst_api <GET|POST|PATCH> <platform> <path> [data: "k=v&k2=v2"] → API_CODE / API_BODY
# ---------- 平台操作分派 ----------
# 平台插件（platforms/<name>.sh）必须自包含实现 platform_<name>_<op> 方法
# （含平台私有的 HTTP 层），common.sh 不提供任何平台 API 实现
# 用法: platform_call <op> <args...>  需先设置 CURRENT_PLATFORM
# 约定签名（各平台统一）: repo_exists <owner> <repo>
#                        create_repo <owner> <repo> <private>
#                        set_visibility <owner> <repo> <private>
#                        set_default_branch <owner> <repo> <branch>
platform_call() {
  local op="$1"; shift
  local fn="platform_${CURRENT_PLATFORM:-}_${op}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    log "  [错误] 平台 $CURRENT_PLATFORM 未实现 $op 方法（插件不完整）"
    return 1
  fi
  "$fn" "$@"
}

# ---------- 平台插件完整性校验 ----------
# 新增平台时，按方法契约实现以下方法（缺失会在此一次性列出）:
#   platform_<name>_host                 → echo SSH 主机名
#   platform_<name>_repo_exists o r      → 仓库是否存在
#   platform_<name>_create_repo o r priv → 建仓
#   platform_<name>_set_visibility o r priv
#   platform_<name>_set_default_branch o r branch
# 模板参照 scripts/platforms/_template.sh
platform_validate() { # platform
  local p="$1" op fn
  local missing=()
  for op in host repo_exists create_repo set_visibility set_default_branch; do
    fn="platform_${p}_${op}"
    declare -F "$fn" >/dev/null 2>&1 || missing+=("$fn")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "  [错误] 平台 $p 插件不完整，缺少方法: ${missing[*]}"
    log "          参照 scripts/platforms/_template.sh 补齐后重试"
    return 1
  fi
  return 0
}

# ---------- 源端 HTTPS 认证（GIT_ASKPASS + basic auth） ----------
# GitHub 的 git 端点不接受 Authorization: Bearer/token header（一律 401），
# 只接受 basic auth；通过 askpass 脚本提供用户名/密码，
# token 经环境变量读取，不进入 URL / git 配置 / 日志 / 磁盘
init_git_auth() {
  export GIT_TERMINAL_PROMPT=0
  cat > "$HOME/.git-askpass" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) echo "x-access-token" ;;
  *) echo "${SRC_TOKEN:-}" ;;
esac
EOF
  chmod 700 "$HOME/.git-askpass"
  export GIT_ASKPASS="$HOME/.git-askpass"
}

# ---------- SSH 初始化（推送密钥 + 固定 known_hosts 防中间人） ----------
init_ssh() {
  [[ -n "${MIRROR_KEY:-}" ]] || return 0
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  printf '%s\n' "$MIRROR_KEY" > "$HOME/.ssh/id_mirror"
  chmod 600 "$HOME/.ssh/id_mirror"
  : > "$HOME/.ssh/known_hosts"
  local p h
  while IFS= read -r p; do
    h=$(platform_host "$p")
    ssh-keyscan -t ed25519,rsa "$h" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
  done < <(discover_platforms)
  chmod 644 "$HOME/.ssh/known_hosts" 2>/dev/null || true
  export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_mirror -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
}
