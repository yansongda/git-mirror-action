#!/usr/bin/env bash
# ============================================================
# GitCode 平台适配（兼容 Gitee API v5 风格）
#
# 差异点：GitCode 的 boolean 参数使用 1/0 而非 true/false
#（PATCH 响应中 private 为 integer 类型），因此建仓与可见性
# 校正覆盖默认实现，避免 true/false 字符串被忽略导致：
#   1. 私有仓库建成 public
#   2. 可见性校正不生效
# ============================================================

PLATFORM_HOST="gitcode.com"
PLATFORM_API="https://api.gitcode.com/api/v5"

# 建仓：私有时传 private=1；公开时不传（GitCode 默认公开）
# 签名: platform_<name>_<op> (owner repo private)，平台由 CURRENT_PLATFORM 指定
platform_gitcode_create_repo() { # owner repo private
  local data="name=$2"
  [[ "$3" == true ]] && data="$data&private=1"
  dst_api POST "$CURRENT_PLATFORM" "/user/repos" "$data"
  [[ $API_CODE == "201" ]]
}

# 校正可见性：私有→private=1，公开→private=0（必须显式传，否则不改变）
platform_gitcode_set_visibility() { # owner repo private
  local data
  [[ "$3" == true ]] && data="private=1" || data="private=0"
  dst_api PATCH "$CURRENT_PLATFORM" "/repos/$1/$2" "$data"
  [[ $API_CODE == "200" ]]
}
