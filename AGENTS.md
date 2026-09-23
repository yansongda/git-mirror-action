# AGENTS.md — 仓库开发指令（面向 AI 编码代理）

> 本文件为 AI 编码代理提供开发约束与架构背景。修改本仓库代码前必读；
> 使用方式（配置参数、Secrets、扩展平台步骤）见 README.md。

## 项目概述

将 GitHub 账号（用户/组织）下全部仓库（含私有）镜像同步到 Gitee / GitCode 等目标平台。
零第三方 action 依赖，仅用 runner 自带工具（bash / git / curl / jq / ssh）。

核心链路：

```
mirror.sh（编排）→ fetch_repos(gh.sh) → filter_repos → sync_all
  → xargs 并发按行调 core.sh（每仓库一个独立进程）
    → sync_one → clone_mirror → 逐平台 sync_to_platform
      → repo_exists → create_repo → set_visibility → mirror_push → set_default_branch
```

## 仓库结构

```
action.yml              composite action 元数据：inputs 映射为环境变量注入
scripts/
  mirror.sh             编排入口：load_config → validate_config → setup_platforms
                        → prepare_workdir → print_banner → fetch_repos → filter_repos
                        → dry_run_mode | (sync_all + summarize + final_summary)
  core.sh               单仓库同步业务（sync_one 及子函数）+ 进程入口 main；
                        source 时仅加载函数供测试，被直接执行时跑 main
  common.sh             通用基础库（幂等可重复 source）：日志/脱敏/超时/列表判断/
                        平台发现/账号读取/插件加载/分派/校验/可见性计算/认证与 SSH
  gh.sh                 GitHub 源端：gh_api + gh_list_repos（分页 TSV 输出）
  platforms/
    _template.sh        新增平台的模板（含方法契约注释）
    gitee.sh / gitcode.sh  平台插件范例（form 风格 / JSON 风格）
tests/
  run.sh                统一入口：unit/ 与 integration/ 各文件独立 bash 进程
  unit/                 common/core/gh 的函数级单测（source 加载，全离线）
  integration/          mirror（全链路+xargs 并发）/ sync_one（独立进程）/ dry_run
  lib/assert.sh         最小断言库：t / assert_eq / assert_contains / assert_status
                        / assert_file_contains / summary（失败返回非零）
  lib/env.sh            fake 环境：setup_fake_env / make_source_repo / add_source_ref
                        / make_empty_dest
  mocks/                 mock curl / git（加入 PATH 前置，全离线测试）
.github/workflows/
  ci.yml                bash -n + tests/run.sh，ubuntu + macos（验证 bash 3.2 兼容）
  mirror.yml            实际使用示例（cron + 手动触发，自举引用本仓库 action）
```

## 架构与设计决策（改代码前必读）

### 平台插件契约
- 平台文件**自包含**实现 HTTP 层（认证方式、body 格式都在文件内），`common.sh` 不提供任何平台 API 实现
- 必选方法（`platform_validate` 启动时自动校验，缺失明确报错）：
  `platform_<name>_host`、`_repo_exists <owner> <repo>`、`_create_repo <owner> <repo> <private>`、
  `_set_visibility <owner> <repo> <private>`、`_set_default_branch <owner> <repo> <branch>`（均返回 0/1）
- 可选：`platform_<name>_api` → API base URL（request 层内部用）
- HTTP 结果写入全局 `API_CODE` / `API_BODY`；认证 token 经 `platform_token <name>` 读取
- **禁止用全局变量传平台私有状态**（多平台 source 时互相污染）；元数据用带平台前缀的函数返回
- 新增平台 = 复制 `_template.sh` → 实现方法 → workflow 加 `DST_<NAME>_ACCOUNT/TOKEN` → 测试

### 推送语义（历史踩坑沉淀）
- **禁用 `git push --mirror`**：会连 GitHub 的 `refs/pull/*` 隐藏 ref 一起推，
  目标端拒绝（deny updating a hidden ref）导致整批失败
- 必须显式推 `+refs/heads/*:refs/heads/*` + `+refs/tags/*:refs/tags/*`，加 `--prune` 保持镜像语义（删除多余分支/tag）
- 空仓库（`git show-ref` 无输出）只建仓不推送
- 默认分支经 API `set_default_branch` 修正（mirror push 不携带远端 HEAD）
- push 失败自动重试 1 次

### 脱敏红线
- token 永不落入日志：URL 参数、请求体经 `sanitize`（access_token / Authorization 头）
- 私有仓库日志名 `mask_repo`：前 `MASK_REPO_KEEP`（默认 4）位 + `***`；`redact_repo` 用于错误文本内替换
- **日志/输出用脱敏名，内部文件名、WORK_DIR 目录、状态文件仍用真实名**（功能不受影响，测试有断言覆盖）
- 源端认证走 `GIT_ASKPASS` basic auth（GitHub 不接受 header Bearer），token 不进 URL / git 配置 / 磁盘

### 可见性优先级
`DST_<PLATFORM>_PRIVATE`（平台覆盖）> `DST_PRIVATE`（true/false）> 跟随源可见性（auto）
- 每次同步都执行 `set_visibility` 校正（可修复历史误建）

### 平台坑位（修复记录，勿回退）
| 平台 | 坑 | 正确做法 |
|---|---|---|
| Gitee | 建仓接口对 `private=false` 字符串处理异常（可能误建私有） | 建仓仅私有时传 `private=true`，公开不传 |
| Gitee | PATCH 更新接口 | 必须显式传 `private=true/false`（否则公开改不回）+ `name` 必填（漏传 400） |
| Gitee | 建仓 422 + body 含"已存在" | 幂等视为成功（repo_exists 被限流/超时误判时兜底） |
| GitCode | POST/PATCH 要求 `application/json`，form 会被拒绝或 boolean 被忽略 | JSON body |
| GitCode | 建仓成功返回 **200** 非 201 | `200 || 201` 均视为成功 |
| GitCode | set_visibility 必须显式传 `private:true/false` | 否则可见性不改变 |

### core.sh 进程模型
- `IS_EMPTY` 用全局传值而非命令替换：函数内 log 走 stdout，命令替换会吞日志
- main 内子 shell `( set -e; sync_one ... )`：必须显式 `set -e`（外层是 set +e，且 if 上下文禁用 errexit）
- 主进程**统一 exit 0**：失败经 `status/fail/list` 上报，避免 xargs 因单仓库非零中断整个并发批次
- 状态文件：`status/ok/list`、`status/fail/list`、`status/results.tsv`（repo\tprivate\tok|fail\tdur）、`logs/<repo>.log`

## 开发规范

- **bash 3.2 兼容**（macOS 自带；CI 有 macos 矩阵验证）：禁止 bash 4+ 特性——
  `declare -A`、`${var,,}` / `${var^^}`、`readarray` 等；小写转换用 `tr 'A-Z' 'a-z'`
- 注释与日志用中文；函数签名注释保持既有风格：`fn() { # <args> → 返回值`
- 顶部块注释声明：职责 / 执行方式（bash 执行 or source）/ 依赖 / 需要环境变量
- `mirror.sh` 用 `set -euo pipefail`；`common.sh` 需幂等可重复 source，不 `set -e`
- 环境变量默认值集中在 `mirror.sh load_config`；新增输入需同步 `action.yml`
- 单步小变更：一次改动聚焦一个问题；不改动与任务无关的格式

## 测试规范

```bash
bash -n scripts/*.sh scripts/platforms/*.sh tests/*.sh tests/lib/*.sh tests/mocks/*
bash tests/run.sh          # 全量：unit + integration
bash tests/unit/common_test.sh   # 单文件调试
```

- 测试全离线：`tests/mocks/` 的 mock curl/git 通过 PATH 前置生效，不触网
- mock 开关（环境变量）：`MOCK_GH_REPOS_JSON` / `MOCK_GH_CODE`、`MOCK_GITEE_EXISTS`、
  `MOCK_CREATE_CODE` / `MOCK_PATCH_CODE` / `MOCK_VISIBILITY_CODE`、`MOCK_FAIL_PUSH`、
  `MOCK_LOG_FILE`（记录 mock curl 收到的请求便于断言）
- 用例风格：`t "用例描述"; <命令>; assert_*; ...; summary` 结尾
- 新增函数/平台/修复必须补测试；测试文件开头声明覆盖范围
- **本机环境注意**：本地需安装 `jq`（gh.sh 与分页测试依赖）；
  macOS 本机 PATH 含空格目录时 integration 的多行 `env` 写法会报错（CI runner 无此问题，
  勿因本机失败误判代码）

## 变更检查清单

改 scripts/ 后逐项自查：
1. token 是否可能落日志？（新增请求/日志路径时过 `sanitize` / `redact_repo`）
2. 是否触碰 `--mirror` 或 refs/pull？（保持显式 refs + `--prune`）
3. 新增平台方法是否满足契约、自包含、无全局变量污染？
4. 是否用了 bash 4+ 特性？（macOS 3.2 会挂）
5. 可见性/幂等语义是否被破坏？（Gitee/GitCode 坑位表）
6. `bash -n` + `bash tests/run.sh` 是否通过（对照本机环境注意事项）？
7. 注释是否与代码同步更新（本仓库要求注释即文档）？
