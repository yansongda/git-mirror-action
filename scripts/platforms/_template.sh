#!/usr/bin/env bash
# ============================================================
# 平台插件模板
#
# 复制为 platforms/YOURPLATFORM.sh 后按需修改。脚本会在运行/同步前
# 自动校验以下方法是否齐全（缺失会明确提示补哪个）。
#
# 平台方法契约（全部必选，签名统一）:
#   platform_YOURPLATFORM_host()                  → echo SSH 主机名（push URL 与 known_hosts 用）
#   platform_YOURPLATFORM_repo_exists <owner> <repo>            → 仓库是否存在（返回 0/1）
#   platform_YOURPLATFORM_create_repo <owner> <repo> <private>  → 建仓（private 为 true|false）
#   platform_YOURPLATFORM_set_visibility <owner> <repo> <private> → 校正可见性跟随源
#   platform_YOURPLATFORM_set_default_branch <owner> <repo> <branch> → 设置默认分支
#
# 约定:
#   - 函数名必须带平台前缀；元数据用带前缀的函数返回（勿用全局变量，避免多平台污染）
#   - 认证 token 经 platform_token YOURPLATFORM 读取
#   - HTTP 请求结果写入全局 API_CODE / API_BODY；操作函数以 0/1 返回成败
#   - YOURPLATFORM 必须与 workflow 中 DST_<NAME>_ACCOUNT 的平台名一致（小写）
#
# 完整范例: platforms/gitee.sh（form 风格）、platforms/gitcode.sh（JSON 风格）
# ============================================================

platform_YOURPLATFORM_host() { echo "example.com"; }
# platform_YOURPLATFORM_api() { echo "https://example.com/api/v5"; }   # 可选，request 层内部用

# ---------- 平台私有 HTTP 层（自包含；认证方式/body 格式都在这里） ----------
# 用法: platform_YOURPLATFORM_request <GET|POST|PATCH> <path> [data|json body]
# 结果写入 API_CODE / API_BODY
platform_YOURPLATFORM_request() {
  local method="$1" path="$2" data="${3:-}" resp
  local token base
  token=$(platform_token YOURPLATFORM)
  base=$(platform_YOURPLATFORM_api)
  # ... 参照 gitee.sh / gitcode.sh 实现 curl 调用 ...
  API_CODE="200"
  API_BODY=""
}

# ---------- 操作方法 ----------
platform_YOURPLATFORM_repo_exists() { # owner repo
  platform_YOURPLATFORM_request GET "/repos/$1/$2"
  [[ $API_CODE == "200" ]]
}

platform_YOURPLATFORM_create_repo() { # owner repo private
  platform_YOURPLATFORM_request POST "/user/repos" "name=$2&private=$3"
  [[ $API_CODE == "201" ]]
}

platform_YOURPLATFORM_set_visibility() { # owner repo private
  local data
  [[ "$3" == true ]] && data="private=true" || data="public=true"
  platform_YOURPLATFORM_request PATCH "/repos/$1/$2" "$data"
  [[ $API_CODE == "200" ]]
}

platform_YOURPLATFORM_set_default_branch() { # owner repo branch
  platform_YOURPLATFORM_request PATCH "/repos/$1/$2" "default_branch=$3"
  [[ $API_CODE == "200" ]]
}
