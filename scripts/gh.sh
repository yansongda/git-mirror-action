#!/usr/bin/env bash
# ============================================================
# git-mirror-action GitHub 源端操作
# 需要环境变量: SRC_ACCOUNT / SRC_ACCOUNT_TYPE / SRC_TOKEN
# 依赖: common.sh（已 source，使用 log/die/sanitize）+ jq
# ============================================================

# GitHub API（结果在 API_CODE / API_BODY）
# 瞬时故障（curl 失败 / 5xx / 429 限流）自动重试 1 次，避免偶发抖动废掉整个 job；
# 4xx 业务错误（如 401 token 无效）重试无意义，不重试
# 退避秒数可经 GH_RETRY_DELAY 覆盖（测试设 0）
gh_api() { # method path → API_CODE / API_BODY；curl 失败/5xx/429 重试 1 次
  local method="$1" path="$2" resp i
  for i in 1 2; do
    if resp=$(curl -sS --connect-timeout "${API_CONNECT_TIMEOUT:-10}" --max-time "${API_TIMEOUT:-30}" -w $'\n%{http_code}' -X "$method" \
      -H "Authorization: token $SRC_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com$path"); then
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
    [[ $i -eq 2 ]] && return 0
    log "  [warn] GitHub API 异常 (HTTP $API_CODE)，${GH_RETRY_DELAY:-3}s 后重试 (1/1)..."
    sleep "${GH_RETRY_DELAY:-3}"
  done
}

# ---------- 校验 token 归属（仅 user 模式） ----------
# /user/repos 列出的是 token 认证用户的仓库：token 不属于 SRC_ACCOUNT 时
# 会列出错误账号的仓库，必须启动即拦截
gh_validate_token_owner() { # → 归属不一致时 die
  [[ "${SRC_ACCOUNT_TYPE:-user}" == org ]] && return 0
  gh_api GET "/user"
  [[ "$API_CODE" == "200" ]] \
    || die "GitHub token 校验失败 (HTTP $API_CODE): $(printf '%s' "$API_BODY" | sanitize | head -c 200)"
  local login
  login=$(printf '%s' "$API_BODY" | jq -r '.login')
  [[ "$login" == "$SRC_ACCOUNT" ]] || \
    die "SRC_TOKEN 属于 '$login'，与 SRC_ACCOUNT '$SRC_ACCOUNT' 不一致（user 模式要求 token 属于源账号本人）"
}

# 分页拉取账号下全部仓库（含私有），输出 TSV: name<TAB>private<TAB>fork<TAB>archived<TAB>default_branch
# user 模式用 /user/repos?affiliation=owner（仅 token 主人本人拥有的仓库，含私有）:
#   - 不用 /users/{username}/repos：该端点即使本人 token 认证也只返回公开仓库（无私有）
#   - 不用默认 affiliation（owner,collaborator,organization_member）：会拉入协作者/
#     组织成员仓库，而 clone URL 按 SRC_ACCOUNT 拼接，非本人仓库必然失败；
#     组织仓库请用 org 模式（path 按 SRC_ACCOUNT 定，另配 SRC_ACCOUNT_TYPE=org）
gh_list_repos() {
  local api_path page=1 count
  if [[ "$SRC_ACCOUNT_TYPE" == org ]]; then
    api_path="/orgs/$SRC_ACCOUNT/repos?per_page=100"
  else
    api_path="/user/repos?affiliation=owner&visibility=all&per_page=100"
  fi
  gh_validate_token_owner
  while :; do
    gh_api GET "$api_path&page=$page"
    if [[ "$API_CODE" != "200" ]]; then
      die "GitHub API 失败 (HTTP $API_CODE): $(printf '%s' "$API_BODY" | sanitize | head -c 300)"
    fi
    count=$(printf '%s' "$API_BODY" | jq 'length')
    printf '%s' "$API_BODY" | jq -r '.[] | [.name, .private, .fork, .archived, .default_branch] | @tsv'
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
}
