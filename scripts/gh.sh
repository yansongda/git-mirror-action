#!/usr/bin/env bash
# ============================================================
# git-mirror-action GitHub 源端操作
# 需要环境变量: SRC_ACCOUNT / SRC_ACCOUNT_TYPE / SRC_TOKEN
# 依赖: common.sh（已 source，使用 log/die/sanitize）
# ============================================================

# GitHub API（结果在 API_CODE / API_BODY）
gh_api() { # method path
  local method="$1" path="$2" resp
  resp=$(curl -sS --max-time 60 -w $'\n%{http_code}' -X "$method" \
    -H "Authorization: token $SRC_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com$path") || { API_CODE="000"; API_BODY="curl 失败"; return 1; }
  API_CODE=$(printf '%s' "$resp" | tail -n1)
  API_BODY=$(printf '%s' "$resp" | sed '$d')
}

# 分页拉取账号下全部仓库（含私有），输出 TSV: name<TAB>private<TAB>fork<TAB>archived<TAB>default_branch
gh_list_repos() {
  local api_path page=1 count
  if [[ "$SRC_ACCOUNT_TYPE" == org ]]; then
    api_path="/orgs/$SRC_ACCOUNT/repos"
  else
    api_path="/user/repos"
  fi
  while :; do
    gh_api GET "$api_path?per_page=100&page=$page"
    if [[ "$API_CODE" != "200" ]]; then
      die "GitHub API 失败 (HTTP $API_CODE): $(printf '%s' "$API_BODY" | sanitize | head -c 300)"
    fi
    count=$(printf '%s' "$API_BODY" | jq 'length')
    printf '%s' "$API_BODY" | jq -r '.[] | [.name, .private, .fork, .archived, .default_branch] | @tsv'
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
}
