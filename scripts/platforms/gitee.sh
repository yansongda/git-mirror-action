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
platform_gitee_request() {
  local method="$1" path="$2" data="${3:-}" resp
  local token base
  token=$(platform_token gitee)
  base=$(platform_gitee_api)
  local curlargs=(-sS --max-time 120 -w $'\n%{http_code}')
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

# ---------- 操作方法（core.sh 经 platform_call 分派调用，签名统一） ----------
# 可见性缓存约定: repo_exists 在仓库存在时从响应解析当前可见性并设置全局
#   DEST_REPO_PRIVATE=true|false（无法解析则不设）；create_repo 新建成功时
#   设置 DEST_REPO_PRIVATE=<private>、422 幂等兜底时置空（可见性未知）。
#   core.sh 据此跳过不必要的 set_visibility PATCH（可见性一致时省 1 次请求）

platform_gitee_repo_exists() { # owner repo → 0/1；存在时设置 DEST_REPO_PRIVATE
  platform_gitee_request GET "/repos/$1/$2"
  [[ $API_CODE == "200" ]] || return 1
  local v
  v=$(printf '%s' "$API_BODY" | jq -r '.private' 2>/dev/null || true)
  if [[ "$v" == true || "$v" == false ]]; then
    # shellcheck disable=SC2034   # core.sh 读取的全局可见性缓存
    DEST_REPO_PRIVATE="$v"
  fi
  return 0
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
