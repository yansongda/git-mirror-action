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

# ---------- 操作方法（sync-one.sh 经 platform_call 分派调用，签名统一） ----------
platform_gitee_repo_exists() { # owner repo
  platform_gitee_request GET "/repos/$1/$2"
  [[ $API_CODE == "200" ]]
}

platform_gitee_create_repo() { # owner repo private
  local data="name=$2"
  [[ "$3" == true ]] && data="$data&private=true"
  platform_gitee_request POST "/user/repos" "$data"
  [[ $API_CODE == "201" ]]
}

platform_gitee_set_visibility() { # owner repo private
  # 公开: public=true（Gitee 的 public 参数优先级高于 private）；私有: private=true
  local data
  [[ "$3" == true ]] && data="private=true" || data="public=true"
  platform_gitee_request PATCH "/repos/$1/$2" "$data"
  [[ $API_CODE == "200" ]]
}

platform_gitee_set_default_branch() { # owner repo branch
  platform_gitee_request PATCH "/repos/$1/$2" "default_branch=$3"
  [[ $API_CODE == "200" ]]
}
