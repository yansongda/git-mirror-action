#!/usr/bin/env bash
# ============================================================
# git-mirror-action 测试统一入口
# 用法: bash tests/run.sh
# 每个测试文件独立 bash 进程运行，隔离环境
# ============================================================
cd "$(dirname "$0")"

fail=0
files=$(ls unit/*_test.sh integration/*_test.sh 2>/dev/null)
total=$(echo "$files" | wc -l | tr -d ' ')
i=0

for f in $files; do
  i=$((i + 1))
  printf '[%d/%s] %s ...\n' "$i" "$total" "$f"
  if bash "$f"; then
    printf '  ✓ %s\n' "$f"
  else
    printf '  ✗ %s\n' "$f"
    fail=1
  fi
done

echo ""
if [[ $fail -eq 0 ]]; then
  echo "全部测试通过"
else
  echo "存在失败测试"
  exit 1
fi
