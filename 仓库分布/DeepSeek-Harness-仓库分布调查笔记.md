# DeepSeek-Harness 仓库分布调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`0d1f50007f9bca3f52b06e1c3074fa14d5fb0720`（分支：`master`）
>
> 调查方式：旧快照机械统计为基线，使用 `git ls-tree` 与 `git diff --numstat` 按相同扩展名口径更新当前跟踪文件、源码、文档和测试资产数量，并复核 workspace、包清单与新增模块；未运行构建与测试
>
> 调查范围：覆盖模块、语言、文档、测试、跨平台与工程配套分布；排除运行时行为、性能与构建产物；当前仓库为浅克隆，提交历史统计受克隆边界影响
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

当前快照：Git 跟踪文件 11,239 个；可识别源码 4,308 文件，按旧快照与源码 diff 净值估算约 940,328 行；文档 3,538 文件，约 337,095 行；测试资产 2,170 个。行数是沿用既有扩展名口径的更新估算，超大 diff 中仅改名的复合路径不会改变净行数；未重新运行全仓统计脚本。

## 结论摘要

DeepSeek Harness 是 DeepSeek AI 官方的开源 agent harness，以“一切皆插件”为架构主张。仓库仍是 TypeScript monorepo，但产品面已扩到 CLI、Web、Electron、Python SDK、ACP/SDK profiles 与实验性浏览器 worker；包组增加到 51 个，新增 storage、ssh、browser-use、computer-use、ptc-runtime、webhook 等边界。第一方会话 SQLite provider 被移除，JSONL 成为唯一第一方会话持久化 provider。

横向比较字段：

| 字段 | 数值 |
| --- | --- |
| 仓库形态 | TypeScript monorepo（插件集合，含少量 Python/C 与文档站） |
| workspace/构建 | pnpm 11.7 workspace；tsc -b 双编译面 + tsdown；vitest |
| Git 跟踪文件 | 11,239 |
| 源码文件 / 行 | 4,308 / 约 940,328 |
| 主要语言 | TypeScript/TSX 为主体，另含 CSS、Python、C/C++ 与少量 JavaScript；当前未重算行数占比 |
| 主要模块 | 51 个 package group；`core` 是 API 脊柱，`api`/`host`/`client` 构成 Web 面，另有 session、llm、subagent、ssh、ptc-runtime 等能力组 |
| 文档文件数/集中位置 | 3,538 / 约 337,095 行；`.agents/notes`、`docs/` 与 `packages/` 仍是主要集中区 |
| 测试 | 2,170 个测试资产；未重算测试源码行 |
| 产品平台 | 本地优先 agent harness：CLI + Web GUI + Electron + 本地 Host + SDK/ACP |
| 平台代码组织 | 按平台拆 provider 包（sandbox、shell、session 等），非条件编译目录 |
| 生成/第三方代码影响 | Cordis 家族位于 `vendor/`；pi-ai 为 npm 依赖，未 vendored |

产品 API 脊柱集中在 `packages/core`；其余能力按 Service Definition / Provider / Consumer 向外扩展。`packages/client` 当前含 46 个 `ui-*` 包，浏览器对象服务已分别迁入 `packages/api/*-controller` 的 Client face。中英文 README、Agent Notes、生成参考页、Web e2e、session snapshot 回放与 scripts 门禁均在当前树中持续存在。

框架层对两套外部框架的持有方式不同：Cordis 全家被 vendored 进 `vendor/`（9 个包、18 项本地修改清单），Pi 家族的 `@earendil-works/pi-ai` 则以普通 npm 依赖被消费。该适配包 `llm-pi-ai` 与 `dsh-llm-deepseek` 构成同一 LLM 缝隙的 twin 双实现，详见第 1 节 llm 组。

## 统计口径与仓库形态

统计只覆盖当前提交的 Git 跟踪文件。源码按常见程序语言扩展名识别，文档按 md/mdx/rst/adoc/asciidoc/txt 识别，测试按目录与命名模式识别。当前可复算结果为 11,239 个跟踪文件、4,308 个源码文件、3,538 个文档文件和 2,170 个测试资产。源码与文档行数分别约 940,328 和 337,095，来自旧机械统计基线加同扩展名 diff 净值，因此只作为量级估算，不用于目录级精确排名。

Cordis 框架继续在 `vendor/` 中 rescoped；产品包以 peer dependency 解析到该源码。具体包、上游 SHA 和本地修改清单以 `vendor/README.md` 为准。

仓库形态依据：根 `package.json` 声明 pnpm workspace 与构建脚本（`package.json:7-18,19-143`），工作区成员由 pnpm-workspace.yaml 扩为 vendor、packages、apps、website、examples 与 native/landlock-run、python/sdk-runtime 七个层级。构建分“host / client”两个编译面：tsc -b 先出 lib/types，tsdown 再按面对应的 tsdown 配置打包运行时；测试由 6 个 vitest 配置分管单元、真实 API e2e、快照回放与 Web 三档。开发态 `dsh` 命令经 `node --import tsx/esm` 直接跑 `apps/cli/src/bin.ts` 源码。

## 1. 模块分布与量级

顶层职责保持清晰：`packages/` 放产品能力，`apps/` 现含 CLI、Web 与 desktop/desktop-host 装配，`scripts/` 放门禁和生成器，`vendor/` 放 Cordis，`python/` 与 `native/` 放 SDK/runtime 和原生平台层，`.agents/` 与 `docs/` 放决策记录及参考文档。`packages/README.md` 当前列出 51 个组，是 package group 的权威清单。

Web 前端已从旧的 client runtime 集中层进一步拆分：`packages/client` 保留 shell、连接、slots、store 与 46 个 `ui-*` 展示包；Session、Workspace、Settings 和 Terminal 的 Host/Client 对象服务由 `packages/api` controller 家族持有。`apps/web` 仍是 Vite 壳，Electron 装配位于 `apps/desktop` 与 `apps/desktop-host`。

其余组的量级特征如下（并列罗列，非排序）：

- `mcp` 是单包组（mcp-client），`e2b` 组明确标注为 POC，两者是规模最小的能力组。
- `extensions` 组的 `tool-cordis` 让模型直接阅读并修改运行中的插件图，其 `api-catalog.ts` 是全仓最大的单体源文件。
- `examples` 组提供 agent-spine、acp、jsonrpc 三个演示包，被 `examples/` 顶层的可运行叶子消费。
- `sdk` 与 `api` 组共同构成进程外 JSON-RPC SDK（协议、客户端、服务端），`acp` 组是自动化 Agent Client Protocol 服务端。

### llm 组与 pi-ai 复用关系

`packages/llm` 由缝隙包 llm（抽象服务、内容块词汇、流式装配）与四个角色包组成：token-meter、llm-retry 为消费者，llm-deepseek、llm-pi-ai 为并行注册到 `ctx.llm` 的两个 provider 适配器。后者包描述自称是前者的 design-verification twin，即同一缝隙契约的双实现。

`llm-pi-ai`（28 个文件）的全部外部运行时依赖只有 `@earendil-works/pi-ai@^0.82.1` 一个 npm 包（另有 vendored 的 schemastery），Pi 家族包未被 vendored。继承与复用发生在三个层面，实现分别在 config、adapter、catalog 三个模块（`src/{config,adapter,catalog}.ts`）：

- 类型层：路由配置直接映射 pi-ai 的 Provider、Model、ThinkingBudgets 等类型。
- 运行时层：用 createModels 构造 provider 并做流式转换。
- 目录层：从 `@earendil-works/pi-ai/providers/all` 读取内置 provider 与模型目录；命名 pi-ai 已覆盖的路由继承其端点、协议与模型目录，未覆盖的路由在配置中整体声明。

模型询问入口（`src/discovery.ts`）对 pi-ai 目录内的路由直接以目录作答、不发网络请求，只对目录外的 OpenAI 兼容端点做在线列举。

pi-ai 在本仓的配套管理可见于三处：`pnpm-workspace.yaml` 显式 deny 其传递依赖 @google/genai 与 protobufjs 的生命周期脚本，并用 `minimumReleaseAgeExclude` 豁免 pi-ai 的发布年龄门槛；`pi-ai-provider-e2e.yml` 是仅手动触发的 Azure OpenAI + Anthropic 可选 e2e；twin 取舍理由记录在 Agent Note `2026-06-13-twin-llm-adapters.md`。

## 2. 语言分布与运行时分工

| 语言 | 文件 | 行数 | 占比 | 角色 |
| --- | ---: | ---: | ---: | ---: |
| TypeScript（含 tsx） | 2,578 | 564,122 | 95.5% | 全部产品包、scripts、测试 |
| CSS | 111 | 16,700 | 2.8% | `ui-*` 包样式 |
| JavaScript | 39 | 4,495 | 0.8% | mjs 脚本、cjs 覆盖率辅助 |
| Python | 19 | 4,286 | 0.7% | SDK 源码（约 400 行）与 release/校验脚本 |
| Shell | 6 | 399 | 0.1% | CI 辅助 |
| C | 1 | 298 | 0.05% | Landlock 启动器 `entry/src/main.c` |
| C++ | 1 | 195 | 0.03% | Windows ACL ABI 探针 `verify/abi-probe.cpp` |
| HTML | 1 | 14 | — | `apps/web/index.html` |

TypeScript 独占主体，占比未被显著稀释：排除 vendored 后仍为 95.5%；前端样式以独立 CSS 文件存在（111 个文件，是仅次于 TS 的源码类型）。Python 分两处：`python/sdk` 的 deepseek_harness 包（api、client、errors、models 五个模块）与 `python/sdk-runtime` 捆绑运行时包，其余是发布构建脚本（如 `scripts/build-python-release.py`）。C/C++ 都是平台原生层：Landlock 启动器以 C 实现并由 Node 包 entry 调起，Windows ACL 的 ABI 探针以 C++ 编译验证 Windows 内核 API 契约。

运行时分工共四个：Node（引擎 `^22.19 || >=24`，全仓 ESM，开发态经 tsx 跑源码）承载 CLI 与服务端；浏览器（React 18）承载 Web GUI，产物由 `apps/web` 的 vite 构建；Python（>=3.10）作为外部 SDK 经 JSON-RPC 连接运行时；Landlock C 启动器为 Linux 进程隔离提供原生入口。各语言间没有共享业务代码，Python SDK 与 C 启动器都是独立的对外边界。

## 3. 文档分布与数量

当前共识别 3,538 个文档文件，约 337,095 行。主要集中区仍是 `.agents/notes`、`docs/` 和各 package README；本次未重算这些区域的精确分项，避免继续沿用旧快照数字。

双语继续采用“三件套”而非翻译目录：英文 Markdown、中译 `*.zh.md` 与 `.i18n.yaml` 配对清单由门禁检查。`docs/` 按 subsystems、user、cookbook、Cordis 教程/API 和 postmortem 分区；`website/` 投影 docs 源而不复制正文。

`docs/` 中还有一类生成物，由 `scripts/gen-*.ts` 从源码与配置生成，配 `verify-*` 门禁保证与代码同步，`THIRD_PARTY_NOTICES.md` 同样由生成器维护：

- 生成目录（六个）：tool-catalog、config-catalog、persistence-catalog、module-graph、graph-atlas、cordis-catalog

`.agents/notes` 按状态分目录（implemented、archived、proposed、rejected），归档笔记冻结不可改，另有 11 个开发 skill 分布在 `.agents/skills`。

## 4. 测试分布与数量

当前识别出 2,170 个测试资产，包含 TypeScript/Python 测试代码、JSONL 会话快照、期望输出与其它夹具；未重算测试源码行。测试分布于 packages、apps、scripts、Python SDK 与原生层，覆盖单包行为、真实 API e2e、Web keyless replay、构建产物和仓库门禁。

跨模块测试的主要类型如下：

- `apps/web` 的 69 个 e2e：jsdom 中组装构建产物，以 keyless FixtureApiClient 驱动到聊天内容端到端。
- session snapshot 目录与 profile fixtures：JSONL/JSON/期望文本的 keyless 回放，对应 `test:snapshot` 档。
- `apps/cli/tests`：built-bin 与配置装配。

真实 API e2e 在无 `DEEPSEEK_API_KEY` 的环境自跳过。仓库规范要求 packages 源码按文件 100% 覆盖率，并区分 GUI 单测、Web snapshot replay 与 SDK expected-output 表面；该声明和当前覆盖率均未运行验证。

## 5. 跨平台与发布组织

产品平台是本地优先的 agent harness，共有四个对外运行面：CLI（apps/cli 的 `dsh` 命令）、Web GUI（浏览器 React + 本地 HTTP 服务端）、进程外 SDK（JSON-RPC 协议三包与 Python SDK）、自动化协议（ACP 服务端、MCP client 包）。没有移动端；没有云端 SaaS 组装层，api/gateway 只是本机 BFF 装配。

平台差异以“同缝隙多 provider 包”组织，而非目录级条件编译：sandbox 组按后端拆 bwrap/Landlock/Seatbelt 与 Windows ACL 包；shell 组按实现拆 bash 与 pwsh 的 local/sandbox 变体；会话持久化第一方只保留 JSONL，SQLite 仍用于搜索索引和非会话 storage domain。

操作系统专属代码可见三处：`native/landlock-run` 只面向 Linux（x64/arm64 平台包与 prebuilds）；Windows 侧有 `sandbox-windows-acl`（C++ ABI 探针 + 14 个测试）、terminal 组经 node-pty 的 ConPTY 后端、JSONL 落盘经 koffi 的 MoveFileExW 写穿发布；macOS 的 Seatbelt 后端在 sandbox 组文档中声明。

CI 矩阵显示 Linux 走自托管 Ubuntu 24.04 runner，Windows 采用“Wine 跑 Node 的阻塞门禁 + windows-native 完整内核清单”双线策略，由 `scripts/wine-windows-gates.sh` 与 `ci.yml` 落实。

当前产品版本为 `0.1.6-alpha.1`。发布仍按 npm 产品/vendor、Python wheel 与原生平台资产分流；桌面端另有 `apps/desktop` 上传计划。开发工具链使用 pnpm、lefthook、oxlint、jscpd、knip/publint 等仓库级门禁。

## 6. 工程配套与结构特征

`scripts/`（158 文件 / 32,895 行）是工程配套的主干，按用途分三类：仓库门禁由 `run-gates.ts` 编排 check-all/ci 各档，含 `check-workspace-constraints.ts` 与 verify-* 系列约 40 个验证器；生成器是 gen-* 系列约 10 个，输出 docs 下目录并配 verify 命令（gen-cordis-catalog、gen-module-graph、gen-persistence-catalog 等）；发布与清理包括 release 子目录、publish-npm-baseline 与 build-exe-for-python-sdk。其中 `gen-doc-graphs.ts`（1,460 行）与 `publish-npm-baseline.ts`（1,083 行）是最大单体。该目录自带 45 个 spec，意味着仓库治理逻辑本身有测试。

结构特征观察（源码确认，非评价）：

- 根目录 38 个文件，是配置与门禁的中枢：7 个 tsconfig（host/client/base 分面）、6 个 vitest 配置、三份 lint 配置（oxlint、jscpd、knip）、pnpm workspace 与锁文件、lefthook 钩子配置。
- 包命名与依赖方向一致：产品包 `@deepseek-ai/dsh-<pkg>`，vendored 包 `@deepseek-ai/cordis*`；组 README 声明“扩展插件只依赖 Service Definition，不依赖具体 provider”，模块图由 `gen-module-graph` 生成并做 freshness 门禁。
- 历史实现并存是设计内现象：`llm-deepseek`/`llm-pi-ai` 明确以 twin 双实现共存（Agent Note 记录取舍），e2b 组自标 POC，session-title 有 llm/首条提示/全提示三个变体。
- 文档与代码同仓治理：Agent Notes 有状态机（implemented/archived/proposed/rejected）与归档冻结策略，skills 以文件形式随仓库版本控制。

## 7. 设计取舍与已确认边界

已确认的取舍（均有源码或仓内文档依据）：

- 框架层“完全持有”：Cordis 不是 npm 依赖而是 vendored 源码，manifest 钉上游 SHA、18 项本地修改逐条登记（fiber 生命周期加固、事务化 loader/include 配置重载、Windows 落盘可靠性等），换来的代价是每次上游同步要重放修改清单；`vendor/README.md` 与 `scripts/rescope-vendor.ts` 支撑该流程。
- 对比之下 pi-ai 走“消费不持有”：依赖目录、协议与模型目录交给外部包，本仓只写适配与漂移门禁（类型映射、`Record` 键型漂移门），两者形成了框架层“vendor 或依赖”的对照样本。
- 插件颗粒度取到包级：当前 51 个组，界面按 46 个 `ui-*` 包拆分；能力按缝隙角色拆分，依赖方向由生成模块图与约束门禁强制。
- 双语与生成文档的自动化：i18n 三件套 + 生成目录 + freshness 门禁，使 docs 树可机械校验，但也让仓库文档计数远高于单语言仓库。
- 仓库自验证文化：scripts 带测试、CI 工作流本身被 spec 校验、覆盖率门禁按文件 100%、发布前基线检查，治理逻辑与产品逻辑同仓同管。

边界与限制（已确认）：仓库为浅克隆，当前 HEAD 为后续演进状态；`vendor/` 的同步目标在清单中声明为外部 fork（deepseek-harness/cordis 等），本次未核对这些上游 URL 与清单一致性之外的演进；所有统计均为静态口径，行数不等于功能量。

## 8. 未验证事项

- 未运行构建（tsc/tsdown/vite）、测试（vitest 各档）与门禁，覆盖率“按文件 100%”的声明未验证；`packages/client` 的 GUI 行为、键盘与视觉结果需运行验证。
- 未运行网站构建，`docs.ts` 投影行为与死链检查基于静态阅读。
- pi-ai 0.82.1 的模型目录、流式协议与推理参数在运行时是否与适配器注释一致，未验证（专用 e2e 需真实 API key，仅手动触发）。
- 发布流水线（npm 公开发布、PyPI wheel、GitLab tag 触发）与 vendored 同步流程均未实际执行；浅克隆历史不足以回答演进方向类问题。
- Landlock 启动器、Windows ACL 探针与 node-pty/ConPTY 行为只在静态层面确认，未在对应平台运行。
- `docs/` 中双语页“105 页”与 `.agents/notes` 中“684 篇笔记”为文件级计数，未逐页核对内容对应关系与缺失翻译。

## 9. 关键源码索引

- `package.json:7-18,19-143`：workspace、构建、测试、门禁与发布脚本总表
- `pnpm-workspace.yaml:1-21`：工作区成员、vendored 覆盖、构建脚本白名单
- `vendor/README.md`：vendored 清单（上游 SHA）、18 项本地修改日志、同步流程
- `packages/README.md`：51 组职责表与依赖规则
- `packages/llm/llm-pi-ai/package.json:45` 与 `src/{adapter,catalog,config,discovery}.ts`：pi-ai 依赖与适配层
- `apps/cli/src/bin.ts`：`dsh` 源码启动入口
- `apps/web/src/main.ts`、`packages/client/README.md`：Web 壳层与浏览器半区
- `website/docs.ts`：站点投影清单（双语路由）
- `scripts/run-gates.ts`：门禁编排；`scripts/gen-*.ts`：目录生成器
- `.github/workflows/ci.yml`、`.gitlab-ci.yml`：双 CI 平台与 Python 发布
