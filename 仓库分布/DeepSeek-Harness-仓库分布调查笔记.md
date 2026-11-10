# DeepSeek-Harness 仓库分布调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`8bd073392eef6f54e921a093b95076248eb08cbb`（分支：`master`）
>
> 调查方式：在当前 HEAD 上用 `git ls-tree -r` 枚举全部跟踪文件、用 `git grep -c ""` 按扩展名累计行数，直接统计文件数与行数；再核对根 `package.json`、`pnpm-workspace.yaml`、`packages/README.md`、`vendor/README.md`、`apps/` 与 CI 工作流清单。未运行构建与测试
>
> 调查范围：覆盖模块、语言、文档、测试、跨平台与工程配套分布；排除运行时行为、性能与构建产物；仓库为浅克隆，历史长度受克隆边界影响
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

当前快照：Git 跟踪文件 20,531 个；可识别源码 7,712 文件、1,595,947 行；文档 5,237 文件、460,605 行；按 tests 目录与 spec/test 命名识别的测试代码 4,338 个，另有 1,999 个快照与夹具文件（其中顶层 `snapshots/` 目录 1,943 个）。统计口径是当前提交的 Git 跟踪文件，行数由逐文件 grep 计数求和，未计入二进制文件。

## 结论摘要

DeepSeek Harness 是 DeepSeek AI 官方的开源 agent harness，以“一切皆插件”为架构主张。仓库仍是 TypeScript monorepo，产品面已扩到 CLI、Web、Electron 桌面端、Python SDK、ACP/SDK profiles 与实验性浏览器/桌面自动化 worker；包组 53 个，`packages/` 下 11,048 个文件、`apps/` 1,559 个、`.agents/` 4,068 个。与 2026-09 快照相比，仓库规模接近翻倍，主要增量来自实验能力组、桌面端装配、模板快照回放语料与测试代码。

横向比较字段：

| 字段 | 数值 |
| --- | --- |
| 仓库形态 | TypeScript monorepo（插件集合，另含 Swift/C/C++/Python 原生与 SDK 层） |
| workspace/构建 | pnpm 11.28.5 workspace，7 个成员层级；`scripts/build.ts` 统一构建/检查图，tsc -b 分 host/client 两面 + tsdown 打包；vitest 9 个配置 |
| Git 跟踪文件 | 20,531 |
| 源码文件 / 行 | 7,712 / 1,595,947 |
| 主要语言 | TypeScript/TSX 约占源码行 94%；CSS、Python、Swift、Shell、C/C++ 为局部层 |
| 主要模块 | 53 个 package group；`core` 是 API 脊柱，`api`/`host`/`client` 构成 Web 面，另有 session、llm、experimental、bundle 等 |
| 文档文件数/集中位置 | 5,237 / 460,605 行；`.agents/notes`（4,022 文件）、`docs/` 与各包 README 为主要集中区 |
| 测试 | 4,338 个测试代码文件，1,999 个快照/夹具文件；测试源码行未重算 |
| 产品平台 | 本地优先 agent harness：CLI + Web GUI + Electron 桌面端 + 本地 Host + SDK/ACP |
| 平台代码组织 | 按平台拆 provider 包（sandbox、shell、terminal、native/system 等），非条件编译目录 |
| 生成/第三方代码影响 | Cordis 家族 9 个包位于 `vendor/`；pi-ai 以 npm 依赖 `^1.3.0` 消费，未 vendored |

产品 API 脊柱集中在 `packages/core`；其余能力按 Service Definition / Provider / Consumer 向外扩展。`packages/client` 现有 60 个 `ui-*` 包与 12 个非 UI 包（connection、web、modules、store 等），浏览器对象服务已迁入 `packages/api/*-controller` 的 Client face。中英双语 README、Agent Notes、生成参考页、Web e2e、`snapshots/` 回放语料与 scripts 门禁都在当前树中持续存在。

框架层对两套外部框架的持有方式不同：Cordis 全家被 vendored 进 `vendor/`（9 个包、本地修改清单 V1–V27），Pi 家族的 `@earendil-works/pi-ai` 则以 npm 依赖被消费，另有 `@earendil-works/pi-telemetry`。适配包 `llm-pi-ai` 与 `dsh-llm-deepseek` 构成同一 LLM 缝隙的 twin 双实现，详见第 1 节 llm 组。

## 统计口径与仓库形态

统计只覆盖当前提交的 Git 跟踪文件。源码按常见程序语言扩展名识别，文档按 md/mdx/rst/adoc/asciidoc/txt 识别，测试按 tests 目录与 `*.spec.*`/`*.test.*` 命名识别。文件数可精确复算；行数来自 `git grep -c ""` 求和，跳过了被判定为二进制的文件，因此与文本编辑器行数可能有极小差异。

工作区范围与构建流程由根目录配置确定。根 `package.json` 声明 workspace 并登记 246 条脚本，这些脚本集中在 scripts 段（`package.json:1-300`）；工作区成员由 `pnpm-workspace.yaml` 扩为七个层级：

- `vendor/*`
- `packages/*/*`
- `native/system` 及其 `packages/*`
- `apps/*`
- `benchmarks`
- `website`
- `python/sdk-runtime`

构建入口是 `scripts/build.ts`，按 `--scope` 分 artifacts、check、typecheck 三条流程，并调用 `compile-referenced-projects.ts` 生成 Typert 声明、驱动 tsc 工程引用。host 与 client 两个编译面分别由 `tsconfig.host.json`、`tsconfig.client.json` 定义，产物再经 tsdown 打包。开发态 `dsh` 命令以 `node --import tsx/esm apps/cli/src/bin.ts` 直接跑源码。

顶层目录按职责分工：

- `packages/`：产品能力
- `apps/`：CLI、Web、desktop、desktop-host 与 plugin-market-generator
- `scripts/`：门禁和生成器
- `vendor/`：Cordis
- `python/`、`native/`：SDK/runtime 与原生平台层
- `.agents/`、`docs/`：决策记录及参考文档
- `snapshots/`：跨端回放语料
- `benchmarks/`：私有基准包
- `patches/`：依赖补丁

## 1. 模块分布与量级

顶层目录的跟踪文件数如下：

| 目录 | 文件数 | 职责 |
| --- | ---: | --- |
| `packages/` | 11,048 | 产品能力包，53 个组 |
| `.agents/` | 4,068 | Agent Notes（4,022 文件）与 23 个开发 skill |
| `snapshots/` | 1,943 | acp/sdk/session/web 四套回放语料 |
| `apps/` | 1,559 | CLI、Web、Electron 桌面端与装配 |
| `docs/` | 1,015 | 双语参考文档与生成目录 |
| `scripts/` | 456 | 门禁、生成器、发布 |
| `vendor/` | 82 | vendored Cordis 家族 |
| `native/` | 79 | `native/system` 原生启动器与平台包 |
| `python/` | 70 | Python SDK 与捆绑运行时 |
| `benchmarks/` | 48 | 仓库级基准依赖与场景 |
| `website/` | 37 | docs 投影站 |
| `patches/` | 12 | 依赖补丁 |
| 根目录 | 47 | 配置与门禁中枢 |

包组清单以 `packages/README.md` 的 53 行表格为准，与 `packages/` 下 53 个组目录一一对应。组目录的归类约定有两条：

- deliverables、document、team、telemetry 各自独立成组。
- hooks、runtime-diagnostics、webhook 的能力归入 `experimental/` 组。

仓库内不提供 e2b provider，相关决策记录见 `.agents/notes/implemented/simplification/2026-09-11-remove-e2b-providers.md`。

`packages/experimental` 是规模最大的单组，含 60 余个子包，覆盖 CUA（含 macOS Swift 原生辅助程序）、browser-use 的 playwright/stagehand/chrome-devtools 后端、插件市场与 forge、liveshare、webhook、webworker、语音转写、worktree、session inspector/search、ralph 与多套 bundle。实验包的地位由该组 README 的 status 政策单独声明，与发布/安装无关。

`packages/client` 的 60 个 `ui-*` 包承载浏览器半区，壳与对象层由同组十个非 UI 包提供：

```
connection  web  modules  store  locale
resources  hmr  file-upload  shortcuts  product-analytics
```

`packages/api` 的 controller 族除 Session、Workspace、Settings、Terminal 外，另有 account、job、remote-access 三族。

`apps/` 下五个成员：

- `cli` 提供 `dsh` bin 与 profile 启动
- `web` 是 Vite 构建的前端入口，649 文件，其中 tests 目录 629 文件
- `desktop` 是 Electron 壳，668 文件
- `desktop-host` 是桌面端私有的 Node host 进程
- `plugin-market-generator`

### llm 组与 pi-ai 复用关系

`packages/llm` 组以缝隙包 llm 为核心，它定义抽象服务、内容块词汇与流式装配，其余包按角色分成三类：

- token-meter 与 llm-retry：缝隙的消费方
- llm-deepseek 与 llm-pi-ai：并行注册到 `ctx.llm` 的两个 provider 适配器
- llm-deepseek-account 与 llm-deepseek-api-key：第一方两种认证形态

后者包描述仍自称是前者的 design-verification twin，即同一缝隙契约的双实现。

`llm-pi-ai` 的外部运行时依赖只有 `@earendil-works/pi-ai@^1.3.0` 一个 npm 包（另有 vendored 的 schemastery），Pi 家族包未被 vendored。继承与复用发生在三个层面：路由配置直接映射 pi-ai 的 Provider、Model、ThinkingBudgets 类型；运行时用 createModels 构造 provider 并做流式转换；目录层从 `@earendil-works/pi-ai/providers/all` 读取内置 provider 与模型目录。模型询问入口对 pi-ai 目录内的路由直接以目录作答、不发网络请求，只对目录外的 OpenAI 兼容端点做在线列举。

pi-ai 的配套管理分布在三处：

- `pnpm-workspace.yaml` 对其传递依赖 `@google/genai` 与 `protobufjs` 显式 deny 生命周期脚本。同一文件用 `minimumReleaseAgeExclude` 把 pi-ai 与 pi-telemetry 排除在发布年龄门槛之外。
- `pi-ai-provider-e2e.yml` 提供仅手动触发的 Azure OpenAI + Anthropic 可选 e2e。
- twin 取舍理由记录在 Agent Note `2026-06-13-twin-llm-adapters.md`。

## 2. 语言分布与运行时分工

| 语言 | 文件 | 行数 | 占源码行 | 角色 |
| --- | ---: | ---: | ---: | --- |
| TypeScript（.ts/.tsx/.mts） | 6,987 | 1,501,310 | 94.1% | 全部产品包、scripts、测试与 Web 前端 |
| CSS | 262 | 39,544 | 2.5% | `ui-*` 包样式 |
| Swift | 56 | 7,407 | 0.5% | `experimental/cua-macos/native` 的 macOS 辅助程序 |
| Python | 84 | 21,230 | 1.3% | SDK 源码、捆绑运行时与 release/校验脚本 |
| JavaScript（mjs/cjs） | 257 | 20,459 | 1.3% | 脚本、覆盖率辅助 |
| Shell（sh/ps1） | 37 | 3,983 | 0.2% | CI 与本地辅助 |
| C/C++ | 13 | 1,794 | 0.1% | `native/system` 启动器与 Windows ACL ABI 探针 |
| HTML | 16 | 220 | — | 各前端入口页 |

TypeScript 独占主体。前端样式以独立 CSS 文件存在，是仅次于 TS 的源码类型。Swift 是新出现的原生层，集中在 macOS 的辅助功能自动化（CUA）驱动；C/C++ 分两处：`native/system` 的原生启动器与 `sandbox-windows-acl` 的 ABI 探针。Python 分两处：`python/` 下的 SDK 与 `sdk-runtime` 捆绑运行时，其余是发布构建脚本。

运行时分工共五个：Node（引擎 `>=24.9.0`，全仓 ESM，开发态经 tsx 跑源码）承载 CLI、Host 与桌面 host 进程；浏览器（React 18.3 + Vite 6）承载 Web GUI；Electron 承载桌面壳；Python（SDK 与捆绑运行时）作为外部边界经 JSON-RPC 连接；原生层（C 启动器、C++ 探针、Swift 辅助程序）做进程隔离与系统级交互。各语言间没有共享业务代码，Python SDK、桌面壳与原生程序都是独立对外边界。

## 3. 文档分布与数量

当前共识别 5,237 个文档文件、460,605 行。主要集中区是 `.agents/notes`（4,022 文件）、`docs/`（1,015 文件）和各包 README；`docs/` 顶层有 23 篇英文主文档，配对 317 组 i18n 页面清单。

双语继续采用“三件套”而非翻译目录：英文 Markdown、中译 `*.zh.md` 与 `.i18n.yaml` 配对清单由门禁检查。`docs/` 按 subsystems、user（guide/develop）、cookbook、cordis 教程/API、postmortem、defensive-patterns、upgrade-guide 与 persistence-changes 分区；`website/` 投影 docs 源而不复制正文。

`docs/` 中还有一类生成物，由 `scripts/gen-*.ts` 从源码与配置生成，配 `verify-*` 门禁保证与代码同步，`THIRD_PARTY_NOTICES.md` 同样由生成器维护：

- 生成目录（六个）：tool-catalog、config-catalog、persistence-catalog、experimental-persistence-catalog、module-graph、graph-atlas
- 生成数据：`dependency-catalog.json`、`persistence-schema.json`

`.agents/notes` 按状态分目录（implemented、archived、proposed、rejected），归档笔记冻结不可改，另有 23 个开发 skill 分布在 `.agents/skills`。

## 4. 测试分布与数量

按 tests 目录与 spec/test 命名识别出 4,338 个测试代码文件，另有 1,999 个快照、期望输出与夹具文件。顶层 `snapshots/` 按 acp、sdk、session、web 四套场景组织（1,943 文件），其中会话快照同时保留 `session.v2/v3/v4.jsonl` 三个格式代，用于跨格式回放。测试分布于 packages、apps、scripts、Python SDK 与原生层，覆盖单包行为、真实 API e2e、Web keyless replay、构建产物和仓库门禁。

跨模块测试的主要类型如下：

- `apps/web/tests`：629 个文件的 keyless 回放语料，先在 jsdom 中组装构建产物，再由 FixtureApiClient 驱动，一直跑到聊天内容的端到端验证。
- `snapshots/` 与 profile fixtures：JSONL、JSON 与期望文本组成的 keyless 回放，对应 `test:snapshot` 档。
- `apps/cli/tests`：覆盖 built-bin 与配置装配。
- `native/system/test` 与 `sandbox-windows-acl`：原生层与 Windows ACL 的契约测试。

真实 API e2e 在无 `DEEPSEEK_API_KEY` 的环境自跳过。仓库规范要求 packages 源码按文件 100% 覆盖率，并区分 GUI 单测、Web snapshot replay 与 SDK expected-output 表面；该声明和当前覆盖率均未运行验证。

## 5. 跨平台与发布组织

产品平台是本地优先的 agent harness，共有五个对外运行面：CLI（`apps/cli` 的 `dsh` 命令）、Web GUI（浏览器 React + 本地 HTTP 服务端）、Electron 桌面端（`apps/desktop` 与 `apps/desktop-host`，含自动更新与安装器脚本）、进程外 SDK（JSON-RPC 协议三包与 Python SDK）、自动化协议（ACP 服务端、MCP client 包）。没有移动端；没有云端 SaaS 组装层，api/gateway 只是本机 BFF 装配。

平台差异以“同缝隙多 provider 包”组织，而非目录级条件编译：sandbox 组收敛为四个包，`sandbox-local` 内部按 Linux bwrap→Landlock、macOS Seatbelt、Windows 受限令牌分后端，Windows 写限制另由 `sandbox-windows-acl` 挂载；shell 组按实现拆 bash 与 pwsh 的 local/sandbox 变体；会话持久化第一方只保留 JSONL，SQLite 仍用于搜索索引和非会话 storage domain。

操作系统专属代码可见四处：`native/system` 提供 Linux/macOS 原生启动器与按平台拆分的预构建包（linux-x64/arm64、darwin-x64/arm64）；Windows 侧有 `sandbox-windows-acl`（C++ ABI 探针与测试）、terminal 组经 node-pty 的 ConPTY 后端、JSONL 落盘经 koffi 的 MoveFileExW 写穿发布；macOS 除 Seatbelt 外还有 CUA 的 Swift 辅助程序与打包/签名工作流。

CI 现有 31 个工作流，按平台与产物分线。`ci.yml` 是主干门禁，其余工作流按用途分布，常见的有：

- 分支、平台与 e2e：ci-master.yml、ci-windows.yml、ci-python.yml、e2e.yml
- 打包：macos-package.yml、windows-package.yml、macos-intel-package.yml
- 发布与辅助：desktop-publish.yml、release*.yml、cua-helper-package.yml
- 原生 addon：node-addon-system*.yml

Windows 侧另用双线策略：一条以 Wine 跑 Node 作为阻塞门禁，一条维护 windows-native 的完整内核清单，分别由 `scripts/wine-windows-gates.sh` 与 `ci-windows.yml` 落实。

当前产品版本为 `0.2.2-alpha.3`（根 `package.json` 与 apps 各包一致）。发布仍按 npm 产品/vendor、Python wheel 与原生平台资产分流；桌面端经 `desktop-publish.yml` 发布 NSIS 安装器与自动更新通道。开发工具链使用 pnpm、lefthook、oxlint、jscpd、knip/publint 等仓库级门禁。

## 6. 工程配套与结构特征

`scripts/`（456 文件 / 111,997 行）是工程配套的主干，按用途分三类：仓库门禁由 `run-gates.ts` 编排 check-all/ci 各档，含 `check-workspace-constraints.ts` 与 verify-* 系列验证器；生成器是 gen-* 系列，输出 docs 下目录并配 verify 命令；发布与清理包括 release 子目录、publish-npm-baseline、build-exe-for-python-sdk 与原生包构建。该目录自带大量 `.spec.ts`，意味着仓库治理逻辑本身有测试。

结构特征观察（源码确认，非评价）：

- 根目录 47 个文件，是配置与门禁的中枢：6 个 tsconfig（host/client/base 分面）、9 个 vitest 配置（unit、e2e、snapshot、expected、web、web-stress、web-perf、bench、shared）、三份 lint 配置、pnpm workspace 与锁文件、lefthook 钩子、Makefile 与 pytest.ini。
- 包命名与依赖方向一致：产品包 `@deepseek-ai/dsh-<pkg>`，vendored 包 `@deepseek-ai/cordis*`；组 README 声明“扩展插件只依赖 Service Definition，不依赖具体 provider”，模块图由 `gen-module-graph` 生成并做 freshness 门禁。
- 历史实现并存是设计内现象：`llm-deepseek`/`llm-pi-ai` 明确以 twin 双实现共存（Agent Note 记录取舍），第一方 DeepSeek 适配器又按认证形态拆出 account/api-key 两包；session-title 有 llm、首条提示等多个变体且旧变体移入 experimental。
- 文档与代码同仓治理：Agent Notes 有状态机（implemented/archived/proposed/rejected）与归档冻结策略，skills 以文件形式随仓库版本控制。

## 7. 设计取舍与已确认边界

已确认的取舍（均有源码或仓内文档依据）：

- 框架层“完全持有”：Cordis 以 vendored 源码形式随仓维护，不经 npm 依赖引入，manifest 钉上游 SHA、本地修改逐条登记（V1–V27，下一条为 V28），换来的代价是每次上游同步要重放修改清单；`vendor/README.md` 与 `scripts/rescope-vendor.ts` 支撑该流程，另有 `cordis-rc11-upgrade-plan.md` 记录升级计划。
- 对比之下 pi-ai 走“消费不持有”：依赖目录、协议与模型目录交给外部包，本仓只写适配与漂移门禁，两者形成了框架层“vendor 或依赖”的对照样本。
- 插件颗粒度取到包级：53 个组、60 个 `ui-*` 包；能力按缝隙角色拆分，依赖方向由生成模块图与约束门禁强制。
- 实验能力集中托管：无法稳定承诺的能力（CUA、browser-use 后端、插件市场、liveshare、worktree 等）统一归入 `experimental/`，以状态政策隔离发布承诺，避免主组数量继续膨胀。
- 双语与生成文档的自动化：i18n 三件套 + 生成目录 + freshness 门禁，使 docs 树可机械校验，但也让仓库文档计数远高于单语言仓库。
- 仓库自验证文化：scripts 带测试、CI 工作流本身被 spec 校验、覆盖率门禁按文件 100%、发布前基线检查，治理逻辑与产品逻辑同仓同管；测试代码文件数（4,338）已接近源码文件数的一半。

边界与限制（已确认）：仓库为浅克隆，历史统计受克隆边界影响；`vendor/` 的同步目标在清单中声明为外部 fork，本次未核对这些上游 URL 与清单一致性之外的演进；所有统计均为静态口径，行数只反映代码规模。

## 8. 未验证事项

- 未运行构建（`scripts/build.ts` 各 scope）、测试（vitest 各档）与门禁，覆盖率“按文件 100%”的声明未验证。
- 未运行网站构建，`docs.ts` 投影行为与死链检查基于静态阅读。
- pi-ai 1.3.0 的模型目录、流式协议与推理参数在运行时是否与适配器注释一致，未验证（专用 e2e 需真实 API key，仅手动触发）。
- Electron 桌面端的打包、签名、自动更新与 NSIS 安装器未实际执行；发布流水线（npm、PyPI wheel、原生资产）同样未执行。
- macOS CUA 的 Swift 辅助程序、`native/system` 启动器、Windows ACL 探针与 node-pty/ConPTY 行为只在静态层面确认，未在对应平台运行。
- `docs/` 中 317 组 i18n 页面为文件级计数，未逐页核对内容对应关系与缺失翻译。
- 源码行数由 `git grep -c ""` 统计，含生成代码与测试代码；未按“产品代码/测试/生成物”再拆分占比。

## 9. 关键源码索引

- `package.json`：workspace、246 条构建/测试/门禁/发布脚本
- `pnpm-workspace.yaml`：七个工作区层级、依赖覆盖、允许/拒绝生命周期脚本清单
- `vendor/README.md`：vendored 清单（上游 SHA）、本地修改日志 V1–V27、升级流程
- `packages/README.md`：53 组职责表与依赖规则
- `packages/experimental/README.md`：实验能力清单与 status 政策
- `packages/llm/llm-pi-ai/package.json` 与 `src/{adapter,catalog,config,discovery}.ts`：pi-ai 依赖与适配层
- `scripts/build.ts`、`scripts/compile-referenced-projects.ts`、`tsconfig.host.json`、`tsconfig.client.json`：双编译面构建图
- `apps/cli/src/bin.ts`：`dsh` 源码启动入口；`apps/desktop/package.json`：Electron 桌面壳与打包脚本
- `apps/web/src/main.ts`、`apps/web/vite.config.ts`：Web 壳构建
- `native/system/`：原生启动器与按平台拆分的包
- `docs/{tool,config,persistence,experimental-persistence}-catalog.md`、`docs/module-graph.md`、`docs/graph-atlas.md`：生成目录
- `scripts/run-gates.ts`：门禁编排；`.github/workflows/ci.yml` 等 31 个工作流：CI 与发布
