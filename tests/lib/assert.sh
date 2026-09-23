#!/usr/bin/env bash
# ============================================================
# 最小断言库（零依赖，bash 3.2 兼容）
# 用法: source 本文件后
#   t "用例描述"; <命令>; assert_status 0 $?; ...
#   summary   # 输出统计并按失败返回非零
# ============================================================

PASS=0
FAIL=0
_T=""

t() { _T="$1"; }

_ok() { PASS=$((PASS + 1)); }
_bad() { FAIL=$((FAIL + 1)); printf '  ✗ [%s] %s\n' "$_T" "$*"; }

assert_eq() { # expected actual
  if [[ "$1" == "$2" ]]; then _ok; else _bad "期望: [$1] 实际: [$2]"; fi
}

assert_ne() { # expected actual
  if [[ "$1" != "$2" ]]; then _ok; else _bad "不应相等: [$1]"; fi
}

assert_contains() { # haystack needle
  if [[ "$1" == *"$2"* ]]; then _ok; else _bad "输出不包含: [$2]"; fi
}

assert_not_contains() { # haystack needle
  if [[ "$1" != *"$2"* ]]; then _ok; else _bad "输出不应包含: [$2]"; fi
}

assert_status() { # expected actual
  if [[ "$1" == "$2" ]]; then _ok; else _bad "退出码 期望: $1 实际: $2"; fi
}

assert_file_contains() { # file needle
  if [[ -f "$1" ]] && grep -qF -- "$2" "$1" 2>/dev/null; then _ok; else _bad "文件 $1 不含: [$2]"; fi
}

summary() {
  printf '  通过 %d / 失败 %d\n' "$PASS" "$FAIL"
  [[ $FAIL -eq 0 ]]
}
