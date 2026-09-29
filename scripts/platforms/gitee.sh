#!/usr/bin/env bash
# ============================================================
# Gitee 平台适配（自包含：元数据 + 私有 HTTP 层 + 操作方法）
# API 风格: Gitee API v5，form-urlencoded + access_token
# 注意坑: Gitee 对 private=false 字符串处理异常（可能当作 truthy 建私有），
#         因此公开仓库不传 private 参数，仅私有时显式传 private=true
#
# 设计约束: 平台元数据与内部引用全部使用带平台前缀的函数/局部变量，
#           不依赖任何全局变量（避免多平台 source 时互相覆盖）
# ============================================================

platform_gitee_host() { echo "gitee.com"; }
platform_gitee_api() { echo "https://gitee.com/api/v5"; }

# ---------- 平台私有 HTTP 层 ----------
# 用法: platform_gitee_request <GET|POST|PATCH> <path> [data: "k=v&k2=v2"] → API_CODE / API_BODY
# 瞬时故障（curl 失败 / 5xx / 429 限流）自动重试 1 次：平台网络抖动不再放大成仓库失败；
# 4xx 业务错误不重试（重试无意义）。超时: API_CONNECT_TIMEOUT(默认10s) / API_TIMEOUT(默认30s)
platform_gitee_request() {
  local method="$1" path="$2" data="${3:-}" resp attempt
  local token base
  token=$(platform_token gitee)
  base=$(platform_gitee_api)
  local curlargs=(-sS --connect-timeout "${API_CONNECT_TIMEOUT:-10}" --max-time "${API_TIMEOUT:-30}" -w $'\n%{http_code}')
  if [[ "$method" == GET ]]; then
    curlargs+=(-G)
  else
    curlargs+=(-X "$method")
  fi
  curlargs+=(-d "access_token=$token")
  if [[ -n "$data" ]]; then
    curlargs+=(-d "$data")
  fi
  for attempt in 1 2; do
    if resp=$(curl "${curlargs[@]}" "$base$path"); then
      API_CODE=$(printf '%s' "$resp" | tail -n1)
      API_BODY=$(printf '%s' "$resp" | sed '$d')
    else
      API_CODE="000"
      API_BODY="curl 失败（网络错误或超时）"
    fi
    # 2xx/3xx/4xx 业务结果直接返回；curl 失败 / 5xx / 429 限流 → 重试 1 次
    if [[ "$API_CODE" != "000" && "$API_CODE" != "429" && "$API_CODE" != 5* ]]; then
      return 0
    fi
    if [[ $attempt -eq 2 ]]; then
      return 0
    fi
    log "  [warn] Gitee API 异常 (HTTP $API_CODE)，${API_RETRY_DELAY:-3}s 后重试 (1/1)..."
    sleep "${API_RETRY_DELAY:-3}"
  done
}

# ---------- 操作方法（core.sh 经 platform_call 分派调用，签名统一） ----------
# 状态缓存约定: repo_exists 在三态返回的同时，从响应解析目标端当前状态到全局
#   DEST_REPO_PRIVATE=true|false（无法解析则不设）；DEST_DEFAULT_BRANCH=<分支>（无法解析则不设）；
#   create_repo 新建成功时设置 DEST_REPO_PRIVATE=<private>（默认分支不设，新仓必预 PATCH）。
#   core.sh 据此跳过不必要的 set_visibility / set_default_branch PATCH（各省 1 次请求/仓库/平台）

platform_gitee_repo_exists() { # owner repo → 0=存在 1=明确不存在(404) 2=请求失败
  platform_gitee_request GET "/repos/$1/$2"
  case "$API_CODE" in
    200)
      local v b
      v=$(printf '%s' "$API_BODY" | jq -r '.private' 2>/dev/null || true)
      if [[ "$v" == true || "$v" == false ]]; then
        # shellcheck disable=SC2034   # core.sh 读取的全局状态缓存
        DEST_REPO_PRIVATE="$v"
      fi
      b=$(printf '%s' "$API_BODY" | jq -r '.default_branch' 2>/dev/null || true)
      if [[ -n "$b" && "$b" != null ]]; then
        # shellcheck disable=SC2034   # core.sh 读取的全局默认分支缓存
        DEST_DEFAULT_BRANCH="$b"
      fi
      return 0
      ;;
    404) return 1 ;;
    # 其余（403/5xx/000 等）：已重试过仍无法判定，绝不当作"不存在"去建仓
    *) return 2 ;;
  esac
}

platform_gitee_create_repo() { # owner repo private
  local data="name=$2"
  [[ "$3" == true ]] && data="$data&private=true"
  platform_gitee_request POST "/user/repos" "$data"
  # 幂等: 仓库实际已存在（repo_exists 被限流/超时误判不存在时）→ 422 且含“已存在”也视为成功
  if [[ $API_CODE == "201" ]]; then
    DEST_REPO_PRIVATE="$3"   # 新建可见性即请求值，供上层跳过可见性校正
    return 0
  fi
  if [[ $API_CODE == "422" && "$API_BODY" == *已存在* ]]; then
    # shellcheck disable=SC2034   # core.sh 读取的全局可见性缓存
    DEST_REPO_PRIVATE=""   # 实际已存在但当前可见性未知，置空让上层仍校正
    return 0
  fi
  return 1
}

platform_gitee_set_visibility() { # owner repo private
  # Gitee PATCH 更新仓库: name 为必填参数；private 必须显式传 true/false
  # 公开必须传 private=false 才能把已误建为私有的仓库改回公开
  # （注意: 建仓 POST 对 private=false 字符串有坑才不传；PATCH 更新接口实测有效）
  local data="name=$2&private=$3"
  platform_gitee_request PATCH "/repos/$1/$2" "$data"
  [[ $API_CODE == "200" ]]
}

platform_gitee_set_default_branch() { # owner repo branch
  # name 为 PATCH 必填参数（漏传会 400）
  platform_gitee_request PATCH "/repos/$1/$2" "name=$2&default_branch=$3"
  [[ $API_CODE == "200" ]]
}
