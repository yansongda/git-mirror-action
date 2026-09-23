#!/usr/bin/env bash
# ============================================================
# 测试环境 helper：创建 fake 仓库环境并导出环境变量
# 用法（测试文件中）:
#   source tests/lib/env.sh
#   setup_fake_env /tmp/xxx        # 创建 fake 环境根目录
#   make_source_repo repo-a main   # 造源仓库（含 1 个提交）
#   make_empty_dest <dir>          # 造空目标仓库
# ============================================================

PROJECT_ROOT="${PROJECT_ROOT:?需先设置 PROJECT_ROOT}"

setup_fake_env() { # <fake 根目录>
  FAKE_ROOT="${1:?需要 fake 环境根目录}"
  export FAKE_ROOT
  export MOCK_GH_DIR="$FAKE_ROOT/fake-github"
  export MOCK_GITEE_DIR="$FAKE_ROOT/fake-gitee"
  export MOCK_GITCODE_DIR="$FAKE_ROOT/fake-gitcode"
  # 将 tests/mocks 加入 PATH（mock curl/git 优先）
  export PATH="$PROJECT_ROOT/tests/mocks:$PATH"
}

# 造一个源仓库（含 1 个提交，可指定默认分支）
make_source_repo() { # repo 名 [默认分支]
  local repo="$1" branch="${2:-main}" account="${SRC_ACCOUNT:-test}"
  local dir="$MOCK_GH_DIR/$account/$repo.git"
  rm -rf "$dir"
  git init --bare -b "$branch" "$dir" -q
  local tmp="$FAKE_ROOT/work"
  rm -rf "$tmp" && mkdir -p "$tmp"
  (
    cd "$tmp"
    git clone -q "$dir" w && cd w
    git config user.email test@test && git config user.name test
    echo hi > f.txt && git add . && git commit -qm init
    git push -q origin "$branch"
  )
  rm -rf "$tmp"
}

# 追加一个分支或 tag 到源仓库
add_source_ref() { # repo ref（如 dev 或 v1.0，tag 前缀 t:）
  local repo="$1" ref="$2" account="${SRC_ACCOUNT:-test}"
  local dir="$MOCK_GH_DIR/$account/$repo.git"
  local tmp="$FAKE_ROOT/work2"
  rm -rf "$tmp" && mkdir -p "$tmp"
  (
    cd "$tmp"
    git clone -q "$dir" w && cd w
    git config user.email test@test && git config user.name test
    if [[ "$ref" == t:* ]]; then
      git tag "${ref#t:}"
      git push -q origin "${ref#t:}"
    else
      git branch "$ref"
      git push -q origin "$ref"
    fi
  )
  rm -rf "$tmp"
}

# 造空目标仓库
make_empty_dest() { # 目标仓库目录
  mkdir -p "$1"
  git init --bare "$1/repo-a.git" -q
}
