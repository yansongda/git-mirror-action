# Git Mirror Action

将 GitHub 账号（用户 / 组织）下**全部仓库（含私有）**自动镜像同步到 Gitee、GitCode 等平台。

**零第三方 action 依赖**：仅使用 GitHub runner 自带工具（bash / git / curl / jq / ssh）与官方 `actions/checkout`，无供应链风险。

## 工作原理

```
┌─ 本仓库（调度器 + action 本体）──────────────────────────────┐
│  .github/workflows/mirror.yml   cron 每日 02:00 + 手动触发    │
│         │ uses: ./  （自举引用仓库内 composite action）       │
│         ▼                                                    │
│  scripts/                                                     │
│  ├── mirror.sh   # 编排：校验/列仓库/过滤/并发调度/汇总        │
│  ├── core.sh     # 同步核心（每仓一进程）：clone→建仓→push→默认分支  │
│  ├── common.sh   # 通用基础：日志/脱敏/超时/平台发现与分派/SSH        │
│  ├── gh.sh       # GitHub 源端：仓库列表获取                  │
│  └── platforms/  # 平台插件（加平台=加文件+2个环境变量）      │
│      ├── gitee.sh    #  PLATFORM_HOST / PLATFORM_API          │
│      └── gitcode.sh  #                                        │
└──────────────────────────────────────────────────────────────┘
```

- 新增仓库自动纳入同步（每次运行动态拉取仓库列表），无需逐仓配置
- 增量同步：每次只推变化的分支与 tag；目标端多余的分支/tag 会被删除（镜像语义）；不推送 `refs/pull/*` 等隐藏 ref（避免被目标端拒绝），源端也不拉取这些 ref

## 快速开始

### 1. 准备 Secrets（仓库 Settings → Secrets and variables → Actions）

| Secret 名称 | 来源 | 权限范围 |
|---|---|---|
| `GH_PAT` | GitHub → Settings → Developer settings → Tokens | 仅 `repo`（读取含私有仓库） |
| `GITEE_TOKEN` | gitee.com → 设置 → 私人令牌 | `projects` |
| `GITCODE_TOKEN` | gitcode.com → 设置 → 令牌（token-classic） | `api, read_api, read_repository, write_repository` |
| `MIRROR_PRIVATE_KEY` | 本地 `ssh-keygen -t ed25519 -f mirror_key` 生成 | 私钥存入 secret；**公钥**分别添加到 [Gitee SSH 公钥](https://gitee.com/profile/sshkeys) 与 GitCode 的 SSH 密钥设置 |

> 安全性：令牌只存在 GitHub Secrets 中（日志自动打码）；推送走 SSH 密钥，令牌仅用于建仓 API，不进入 git 配置与日志。

### 2. 修改 workflow 配置

编辑 `.github/workflows/mirror.yml`，替换 `src_account` 与各 `DST_*_ACCOUNT` 为你的用户名。

### 3. 验证

1. 先在 Actions 页面手动触发一次，`with.dry_run` 临时改为 `'true'`：确认仓库列表、过滤结果、目标端建仓判断均正确（不产生任何推送）
2. 确认无误后 `dry_run: 'false'`，再次手动触发完成首次全量同步
3. 检查 Gitee / GitCode 账号下的仓库：数量、最新 commit、默认分支、私有可见性

## 配置清单

### `with` 输入参数

| 参数 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `src_account` | ✅ | — | 源端 GitHub 用户名或组织名 |
| `src_token` | ✅ | — | GitHub PAT（scope: `repo`） |
| `src_account_type` | — | `user` | 源账号类型：`user` / `org` |
| `blacklist` | — | 空 | 不同步的仓库，逗号分隔 |
| `whitelist` | — | 空 | 仅同步列出的仓库，逗号分隔（黑名单仍生效） |
| `skip_forks` | — | `true` | 跳过 fork 仓库 |
| `skip_archived` | — | `false` | 跳过已归档仓库 |
| `dst_private` | — | `auto` | 目标端可见性：`auto`（源私有→目标私有）/ `true`（全部私有）/ `false`（全部公开） |
| `concurrency` | — | `4` | 并发同步仓库数（本仓库示例 workflow 用 `8`） |
| `repo_timeout` | — | `600` | 单个 git 命令超时（秒） |
| `api_timeout` | — | `30` | 单次 HTTP API 调用超时（秒），`0` = 不限制 |
| `strict` | — | `false` | 平台级失败是否使 job 失败（见「同步语义」） |
| `dry_run` | — | `false` | 仅列出仓库清单与建仓检查，不 clone / push |

### 环境变量（目标平台发现 + 密钥）

脚本扫描 `DST_*_ACCOUNT` 自动发现目标平台，**新增平台只需加两个变量**：

| 环境变量 | 说明 |
|---|---|
| `DST_GITEE_ACCOUNT` / `DST_GITEE_TOKEN` | Gitee 账号 + API token |
| `DST_GITCODE_ACCOUNT` / `DST_GITCODE_TOKEN` | GitCode 账号 + API token |
| `DST_<PLATFORM>_PRIVATE`（可选） | 平台级可见性覆盖，如 `DST_GITEE_PRIVATE=true`，优先级高于 `dst_private` |
| `MIRROR_PRIVATE_KEY` | SSH 私钥（所有平台推送共用），公钥须已添加到各目标端账号；即 Secrets 中的 `MIRROR_PRIVATE_KEY` |

### 扩展新平台

**最快路径**：复制 `scripts/platforms/_template.sh` 为 `scripts/platforms/<name>.sh`，按注释补齐实现（参照 `gitee.sh` / `gitcode.sh` 范例）。

#### 平台方法契约（全部必选，运行时自动校验，缺失会提示）

| 方法 | 签名 | 语义 |
|---|---|---|
| `platform_<name>_host` | `() → host` | SSH 主机名（push URL / known_hosts） |
| `platform_<name>_repo_exists` | `(owner repo) → 0/1/2` | 三态：`0`=存在、`1`=明确不存在（HTTP 404）、`2`=无法判定（请求失败/非预期状态码）。只有 `1` 才允许建仓；存在时应从响应解析状态到全局 `DEST_REPO_PRIVATE=true\|false` 与 `DEST_DEFAULT_BRANCH=<分支>`（无法解析则不设） |
| `platform_<name>_create_repo` | `(owner repo private) → 0/1` | 建仓（private=true/false）；新建成功时设置 `DEST_REPO_PRIVATE=private`（不设 `DEST_DEFAULT_BRANCH`，新仓必须执行默认分支校正），幂等兜底（实际已存在）时置空 |
| `platform_<name>_set_visibility` | `(owner repo private) → 0/1` | 校正可见性跟随源（已一致时 core.sh 会跳过调用，省 1 次请求） |
| `platform_<name>_set_default_branch` | `(owner repo branch) → 0/1` | 设置默认分支（已一致时 core.sh 会跳过调用，省 1 次请求） |
| `platform_<name>_supports_lfs`（可选） | `() → 0/1` | LFS 能力声明：`0`=支持镜像 LFS 仓库（**默认，未声明即此**）、`1`=不支持（core.sh 对含 LFS 的仓库跳过该平台，不再无效重试） |
| `platform_<name>_api`（可选） | `() → base url` | request 层内部用 |

#### 步骤

1. 新建 `scripts/platforms/<name>.sh`（复制模板），实现上述方法；平台私有 HTTP 层（认证方式、body 格式）自包含在文件内，勿用全局变量（避免多平台互相污染）
2. workflow 配置 `DST_<NAME>_ACCOUNT` / `DST_<NAME>_TOKEN`（NAME 全大写）
3. 将推送公钥添加到该平台账号
4. 运行（dry-run 或同步）——脚本会在启动时自动校验方法是否齐全，缺失会明确列出

> 若平台的 API 与现有平台差异较大（如 GitLab 的 v4 风格），只需在 request 层按该平台规范实现，不影响其他平台。

## 同步语义与注意事项

- **单向镜像**：目标端只随源变化，被删除的分支/tag 会同步删除；目标端仓库本身（源已删除的仓库）不会自动删除，需手动清理
- **可见性跟随源**：每次同步都会校正目标端仓库可见性与源一致（公开→公开、私有→私有），可自动修复历史同步中可见性不一致的仓库；目标端可见性已一致时自动跳过该请求（省 1 次 API/仓库/平台，降低限流风险）。注意：Gitee 建仓时公开不传 `private`（其建仓接口对 `private=false` 字符串处理有坑，可能误建私有），但**更新可见性必须显式传 `private=false`** 才能把已误建为私有的仓库改回公开
- **仓库列表范围（user 模式）**：仅同步 `src_account` **本人拥有**的全部仓库（含私有）；协作者仓库、组织成员仓库不含（这些仓库的 clone 地址不属于源账号，同步必败）——同步组织请用 `src_account_type: org`。启动时会校验 `src_token` 归属（login 必须等于 `src_account`，不一致立即报错），确保列出的仓库始终是源账号本人的
- **目标端请只读使用**：若有人在目标端直接修改，会被下一次同步覆盖
- **默认分支校正按需执行**：mirror push 不携带远端 HEAD，因此需要 API 设置默认分支；目标端当前默认分支与源一致时自动跳过该请求（省 1 次 API/仓库/平台）
- **Git LFS 限制（GitCode）**：`git` 侧只镜射 LFS **指针**、不搬对象；GitCode 启用 LFS 的项目会在 pre-receive 阶段校验对象存在，缺失直接拒绝整个 push（`LFS objects are missing ... pre-receive hook declined`）。因此对**含 LFS 的仓库**（检测：默认分支 `.gitattributes` 含 `filter=lfs`）在 GitCode 上**直接跳过**（日志 `[skip]`，不建仓不推送也不重试）；Gitee 无此校验，不受影响。检测为 best-effort：不覆盖其他分支 / 子模块 / 手写指针文件，可用 `blacklist` 人工干预
- **首次同步为全量**，之后为增量；几十个仓库通常数分钟内完成
- **空仓库**（无任何提交）只建仓不推送
- 同步失败不中断其他仓库；失败仓库的日志位于 runner 临时目录 `logs/<repo>.log`，汇总时会在任务日志中输出尾部
- **git 命令超时与重试**：单条 git 命令（fetch/push）超过 `repo_timeout`（默认 600s）无响应视为挂起，日志明确提示超时并**不再重试**（挂起重试大概率仍挂起，避免单仓库拖垮整个 job）；认证失败/被拒等快速失败自动重试 1 次（重试前会清理半成品目录）。源端 GitHub API 与**各个目标平台 API** 的瞬时故障（连接失败/5xx/429 限流）同样自动重试 1 次
- **API 超时**：单次 HTTP 调用受 `api_timeout`（默认 30s）与连接超时 10s 约束，避免平台网络黑洞把一次调用拖到分钟级；实测正常调用耗时 2~6s
- **查询失败不建仓**：目标端查询返回非 404 的异常结果（超时/403/5xx）只会判该平台失败并给出 `查询目标仓库失败`，**不会**误当作“仓库不存在”去建仓
- **平台级失败标注与汇总**：仓库级 OK 但某个平台同步失败时（如 GitCode 被拒但 Gitee 成功），最终汇总会标注 `[部分平台失败: <平台>]`、汇总行给出 `平台失败 N`，CI 下额外输出 `::warning::` 注解并写入 Step Summary 表格；`strict: 'true'` 时平台级失败会让 job 失败（默认 `false`，仅告警）
- **最终汇总**：同步结束后输出逐仓库成败与耗时一览表（私有名同样脱敏），便于快速总览

## 安全设计

| 项目 | 做法 |
|---|---|
| 依赖面 | 仅 GitHub 官方 `actions/checkout` + runner 自带工具，零第三方 action |
| 源端认证 | PAT 经 `GIT_ASKPASS` basic auth 传递，不进入 URL / remote 配置 / 日志 |
| 目标端认证 | 推送纯 SSH 密钥；API token 仅用于建仓/查询（日志输出经 `sanitize` 脱敏）；GitCode 经 `PRIVATE-TOKEN` 请求头传递，不进入 URL，Gitee 仍为 `access_token` 表单参数（其 API 惯例） |
| 私有仓库脱敏 | **私有仓库名在日志中只显示开头 4 位 + `***`**（如 `hkgcert-crmeb` → `hkgc***`，可用环境变量 `MASK_REPO_KEEP` 调整位数）；内部文件名、clone/push URL 与状态文件仍用真实名，不影响功能 |
| 防中间人 | `ssh-keyscan` 固定 known_hosts，不使用 `StrictHostKeyChecking=no` |
| 令牌管理 | 全部存 GitHub Secrets，最小权限，建议定期轮换 |

## 本地调试

```bash
# 语法检查（macOS 自带 bash 3.2 亦兼容）
bash -n scripts/*.sh scripts/platforms/*.sh

# 单仓库同步进程可独立运行调试:
bash scripts/core.sh <repo> <is_private> <default_branch>

# dry-run（不推送，需准备环境变量与真实 token）
SRC_ACCOUNT=yourname SRC_TOKEN=xxx \
DST_GITEE_ACCOUNT=yourname DST_GITEE_TOKEN=xxx \
DRY_RUN=true bash scripts/mirror.sh
```

## License

MIT
