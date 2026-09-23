#!/usr/bin/env bash
# ============================================================
# GitCode 平台适配（兼容 Gitee API v5 风格，但 body 用 JSON）
#
# GitCode 的差异：
#   1. POST/PATCH 要求 application/json body（form-urlencoded 会被拒，
#      或 boolean 参数被忽略导致私有仓库建成 public / 校正 400）
#   2. boolean 语义见 JSON 中的 true/false
# 因此建仓、可见性校正、默认分支均覆盖为 JSON 实现
# ============================================================

PLATFORM_HOST="gitcode.com"
PLATFORM_API="https://api.gitcode.com/api/v5"

# 建仓：私有时传 private:true；公开时不传（GitCode 默认公开）
# 签名: platform_<name>_<op> (owner repo private)，平台由 CURRENT_PLATFORM 指定
platform_gitcode_create_repo() { # owner repo private
  local data="{\"name\":\"$2\"}"
  [[ "$3" == true ]] && data="{\"name\":\"$2\",\"private\":true}"
  dst_api POST "$CURRENT_PLATFORM" "/user/repos" "$data"
  [[ $API_CODE == "201" ]]
}

# 校正可见性：私有→private:true，公开→private:false（必须显式传，否则不改变）
platform_gitcode_set_visibility() { # owner repo private
  local data
  [[ "$3" == true ]] && data='{"private":true}' || data='{"private":false}'
  dst_api PATCH "$CURRENT_PLATFORM" "/repos/$1/$2" "$data"
  [[ $API_CODE == "200" ]]
}

# 设置默认分支
platform_gitcode_set_default_branch() { # owner repo branch
  dst_api PATCH "$CURRENT_PLATFORM" "/repos/$1/$2" "{\"default_branch\":\"$3\"}"
  [[ $API_CODE == "200" ]]
}
