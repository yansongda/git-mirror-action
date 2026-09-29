#!/usr/bin/env bash
# ============================================================
# GitCode 平台适配（自包含：元数据 + 私有 HTTP 层 + 操作方法）
# API 风格: GitCode v5 兼容层，但 POST/PATCH 要求 application/json body
# （form-urlencoded 会被拒绝或 boolean 参数被忽略，导致：
#   1. 私有仓库建成 public  2. 可见性校正返回 400）
# 认证: PRIVATE-TOKEN 请求头（token 不进 URL，避免落入代理日志 / ps / 历史记录）
#
# 设计约束: 平台元数据与内部引用全部使用带平台前缀的函数/局部变量，
#           不依赖任何全局变量（避免多平台 source 时互相覆盖）
# ============================================================

platform_gitcode_host() { echo "gitcode.com"; }
platform_gitcode_api() { echo "https://api.gitcode.com/api/v5"; }

# 能力声明: 不支持含 LFS 对象的仓库镜像
# 该项目启用 LFS 时，pre-receive 会校验本次 push 范围内 LFS 指针引用的对象是否存在于
# 服务端 LFS 存储，缺失则拒绝整个 push（LFS objects are missing ... pre-receive hook declined）。
# 而 git clone --mirror 只取指针不取对象，因此直接跳过该平台（不再白跑建仓/推送与重试）。
# Gitee 无此校验（实测接受指针推送），故不声明。
platform_gitcode_supports_lfs() { return 1; }

# ---------- 平台私有 HTTP 层（JSON body） ----------
# 用法: platform_gitcode_request <GET|POST|PATCH> <path> [json body] → API_CODE / API_BODY
# 瞬时故障（curl 失败 / 5xx / 429 限流）自动重试 1 次：平台网络抖动不再放大成仓库失败；
# 4xx 业务错误不重试（重试无意义）。超时: API_CONNECT_TIMEOUT(默认10s) / API_TIMEOUT(默认30s)
platform_gitcode_request() {
  local method="$1" path="$2" body="${3:-}" resp attempt
  local token base
  token=$(platform_token gitcode)
  base=$(platform_gitcode_api)
  local curlargs=(-sS --connect-timeout "${API_CONNECT_TIMEOUT:-10}" --max-time "${API_TIMEOUT:-30}" -w $'\n%{http_code}')
  if [[ "$method" != GET ]]; then
    curlargs+=(-X "$method" -H "Content-Type: application/json")
  fi
  curlargs+=(-H "PRIVATE-TOKEN: $token")
  if [[ -n "$body" ]]; then
    curlargs+=(-d "$body")
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
    log "  [warn] GitCode API 异常 (HTTP $API_CODE)，${API_RETRY_DELAY:-3}s 后重试 (1/1)..."
    sleep "${API_RETRY_DELAY:-3}"
  done
}

# ---------- 操作方法（core.sh 经 platform_call 分派调用，签名统一） ----------
# 状态缓存约定: repo_exists 在三态返回的同时，从响应解析目标端当前状态到全局
#   DEST_REPO_PRIVATE=true|false（无法解析则不设）；DEST_DEFAULT_BRANCH=<分支>（无法解析则不设）；
#   create_repo 新建成功时设置 DEST_REPO_PRIVATE=<private>（默认分支不设，新仓必预 PATCH）。
#   core.sh 据此跳过不必要的 set_visibility / set_default_branch PATCH

platform_gitcode_repo_exists() { # owner repo → 0=存在 1=明确不存在(404) 2=请求失败
  platform_gitcode_request GET "/repos/$1/$2"
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

platform_gitcode_create_repo() { # owner repo private
  # 私有时传 private:true；公开时不传（GitCode 默认公开）
  local body="{\"name\":\"$2\"}"
  [[ "$3" == true ]] && body="{\"name\":\"$2\",\"private\":true}"
  platform_gitcode_request POST "/user/repos" "$body"
  # GitCode 建仓成功返回 200（非 201），两者均视为成功
  if [[ $API_CODE == "200" || $API_CODE == "201" ]]; then
    # shellcheck disable=SC2034   # core.sh 读取的全局可见性缓存
    DEST_REPO_PRIVATE="$3"   # 新建可见性即请求值，供上层跳过可见性校正
    return 0
  fi
  return 1
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
