#!/usr/bin/env bash
# ============================================================
# GitCode 平台适配（自包含：元数据 + 私有 HTTP 层 + 操作方法）
# API 风格: GitCode v5 兼容层，但 POST/PATCH 要求 application/json body
# （form-urlencoded 会被拒绝或 boolean 参数被忽略，导致：
#   1. 私有仓库建成 public  2. 可见性校正返回 400）
#
# 设计约束: 平台元数据与内部引用全部使用带平台前缀的函数/局部变量，
#           不依赖任何全局变量（避免多平台 source 时互相覆盖）
# ============================================================

platform_gitcode_host() { echo "gitcode.com"; }
platform_gitcode_api() { echo "https://api.gitcode.com/api/v5"; }

# ---------- 平台私有 HTTP 层（JSON body） ----------
# 用法: platform_gitcode_request <GET|POST|PATCH> <path> [json body] → API_CODE / API_BODY
platform_gitcode_request() {
  local method="$1" path="$2" body="${3:-}" resp
  local token base
  token=$(platform_token gitcode)
  base=$(platform_gitcode_api)
  local curlargs=(-sS --max-time 60 -w $'\n%{http_code}')
  if [[ "$method" == GET ]]; then
    curlargs+=(-G)
    resp=$(curl "${curlargs[@]}" -d "access_token=$token" "$base$path") \
      || { API_CODE="000"; API_BODY="curl 失败"; return 1; }
  else
    curlargs+=(-X "$method")
    resp=$(curl "${curlargs[@]}" -H "Content-Type: application/json" \
      -d "$body" "$base$path?access_token=$token") \
      || { API_CODE="000"; API_BODY="curl 失败"; return 1; }
  fi
  API_CODE=$(printf '%s' "$resp" | tail -n1)
  API_BODY=$(printf '%s' "$resp" | sed '$d')
}

# ---------- 操作方法（core.sh 经 platform_call 分派调用，签名统一） ----------
platform_gitcode_repo_exists() { # owner repo
  platform_gitcode_request GET "/repos/$1/$2"
  [[ $API_CODE == "200" ]]
}

platform_gitcode_create_repo() { # owner repo private
  # 私有时传 private:true；公开时不传（GitCode 默认公开）
  local body="{\"name\":\"$2\"}"
  [[ "$3" == true ]] && body="{\"name\":\"$2\",\"private\":true}"
  platform_gitcode_request POST "/user/repos" "$body"
  [[ $API_CODE == "201" ]]
}

platform_gitcode_set_visibility() { # owner repo private
  # 私有→private:true，公开→private:false（必须显式传，否则不改变）
  local body
  [[ "$3" == true ]] && body='{"private":true}' || body='{"private":false}'
  platform_gitcode_request PATCH "/repos/$1/$2" "$body"
  [[ $API_CODE == "200" ]]
}

platform_gitcode_set_default_branch() { # owner repo branch
  platform_gitcode_request PATCH "/repos/$1/$2" "{\"default_branch\":\"$3\"}"
  [[ $API_CODE == "200" ]]
}
