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
platform_load() { # platform
  source "$SCRIPT_DIR/platforms/$1.sh" || return 1
}

platform_host() { # platform → host（用于 SSH push URL 与 known_hosts）
  platform_load "$1" || return 1
  printf '%s' "$PLATFORM_HOST"
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
dst_api() {
  local method="$1" platform="$2" path="$3" data="${4:-}"
  local base token resp
  platform_load "$platform" || return 1
  base="$PLATFORM_API"
  token=$(platform_token "$platform")
  local curlargs=(-sS --max-time 60 -w $'\n%{http_code}')
  if [[ "$method" == GET ]]; then
    curlargs+=(-G)
  else
    curlargs+=(-X "$method")
  fi
  if [[ -n "$data" ]]; then
    resp=$(curl "${curlargs[@]}" -d "access_token=$token" -d "$data" "$base$path") \
      || { API_CODE="000"; API_BODY="curl 失败"; return 1; }
  else
    resp=$(curl "${curlargs[@]}" -d "access_token=$token" "$base$path") \
      || { API_CODE="000"; API_BODY="curl 失败"; return 1; }
  fi
  API_CODE=$(printf '%s' "$resp" | tail -n1)
  API_BODY=$(printf '%s' "$resp" | sed '$d')
}

# ---------- 目标端默认平台操作（基于 v5 API 组合；异构平台可覆盖 dst_api 改变行为） ----------
platform_repo_exists() { # platform owner repo
  dst_api GET "$1" "/repos/$2/$3"
  [[ $API_CODE == "200" ]]
}

platform_create_repo() { # platform owner repo private
  # 注意: Gitee API 对 private=false 字符串处理有坑（可能被当作 truthy 建私有），
  # 因此公开仓库不传 private 参数（默认公开），仅私有时显式传 private=true
  local data="name=$3"
  [[ "$4" == true ]] && data="$data&private=true"
  dst_api POST "$1" "/user/repos" "$data"
  [[ $API_CODE == "201" ]]
}

platform_set_visibility() { # platform owner repo private
  # 校正已存在仓库的可见性，使其与源一致（幂等）
  # 公开: 传 public=true（Gitee 的 public 参数优先级高于 private）
  # 私有: 传 private=true
  local data
  if [[ "$4" == true ]]; then
    data="private=true"
  else
    data="public=true"
  fi
  dst_api PATCH "$1" "/repos/$2/$3" "$data"
  [[ $API_CODE == "200" ]]
}

platform_set_default_branch() { # platform owner repo branch
  dst_api PATCH "$1" "/repos/$2/$3" "default_branch=$4"
  [[ $API_CODE == "200" ]]
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
