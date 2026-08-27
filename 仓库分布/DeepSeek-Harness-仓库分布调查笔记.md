# DeepSeek-Harness 仓库分布调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`（分支：`master`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`）与源码复核；复核 pnpm workspace、包清单、构建/测试入口与 CI 配置；未运行构建与测试
>
> 调查范围：覆盖模块、语言、文档、测试、跨平台与工程配套分布；排除运行时行为、性能与构建产物；当前仓库为浅克隆，提交历史统计受克隆边界影响
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-08-27）：Git 跟踪文件 7903 个；可识别源码 2973 文件 / 644118 行；文档 2575 文件 / 180765 行；测试 1918 文件 / 338071 源码行。主线提交节奏：历史跨度 9 天共 112 次，折算 373.33 次/30天，近90天 112 次（浅克隆，历史可能不完整）。

## 结论摘要

DeepSeek Harness（npm 包族 `@deepseek-ai/dsh-*`，产品命令 `dsh`）是 DeepSeek AI 官方的开源 agent harness，以“一切皆插件”为架构主张：框架运行时是在 `vendor/` 源码 vendored 并 rescoped 的 Cordis，产品逻辑则全部拆成 46 组、226 个可独立发布的 npm 包。仓库是单一 TypeScript monorepo，采用 pnpm workspace、tsc + tsdown 构建、vitest 测试，同时夹带 Python SDK、Linux Landlock C 启动器与 VitePress 站点投影。

横向比较字段：

| 字段 | 数值 |
| --- | --- |
| 仓库形态 | TypeScript monorepo（插件集合，含少量 Python/C 与文档站） |
| workspace/构建 | pnpm 11.7 workspace；tsc -b 双编译面 + tsdown；vitest |
| Git 跟踪文件 | 7903 |
| 源码文件 / 行 | 2,973 / 644,118 |
| 前三种语言及占比 | TypeScript 95.5%、CSS 2.8%、JavaScript 0.8% |
| 主要模块及量级 | `packages/client` 组 153,754 行（26%）；`core` 40,745；`subagent` 24,486；`host` 22,412；`session` 21,442 |
| 文档文件数/集中位置 | 2,575 / 180,765 行；`.agents/notes`、`docs/` 与 `packages/` 仍是主要集中区 |
| 测试 | 1918 文件 / 338071 源码行 |
| 测试/源码文件比 | 64%（含夹具与快照资源），仅代码测试文件为 38% |
| 产品平台 | 本地优先 agent harness：CLI + Web GUI + 本地 HTTP 服务端 |
| 平台代码组织 | 按平台拆 provider 包（sandbox、shell、session 等），非条件编译目录 |
| 生成/第三方代码影响 | `vendor/` 9 包 6,566 行（源码行 1.1%）；pi-ai 为 npm 依赖，未 vendored |

产品 API 脊柱集中在 `packages/core` 组（会话、提示词、工具、agent 与主循环五个包），其余能力组按 Service Definition / Service Provider / Consumer 三件套向外扩展；`packages/client` 是体积最大的区域，包含 39 个 `ui-*` 界面插件，以及连接、运行时与 web-react 壳层包。文档系统是仓库的显著特征：`docs/` 有 105 页中英双语文档，`.agents/notes` 收编 684 篇双语 Agent Notes，226 个包全部带 README 三件套。测试方面所有 226 个包都有测试文件，另有组装级 Web e2e、examples 快照回放和 scripts 仓库自检三类跨模块测试。

框架层的“双持有”关系值得单独记录：Cordis 全家被 vendored 进 `vendor/`（9 个包、18 项本地修改清单），而 Pi 家族的 `@earendil-works/pi-ai` 以普通 npm 依赖被消费。该适配包 `llm-pi-ai` 与 `dsh-llm-deepseek` 构成同一 LLM 缝隙的 twin 双实现，详见第 1 节 llm 组。

## 统计口径与仓库形态

统计遵循类别指南的统一口径：只统计当前提交的 Git 跟踪文件，行数含空行与注释，JSON/YAML/锁文件/图片不计源码行，文档按 md/mdx/rst/adoc/asciidoc/txt 扩展名识别，测试按目录名与文件名模式识别，机械统计由 `统计仓库.ps1` 完成，最终结论结合 workspace 声明、包清单与构建入口复核。

全仓口径与排除 vendored 代码后的口径如下：

| 指标 | 全仓口径 | 排除 `vendor/` 后 |
| --- | ---: | ---: |
| 跟踪文件 | 7,903 | 7,829 |
| 源码文件 / 行 | 2,973 / 644,118 | 2,899 / 637,552 |
| TypeScript 行 | 564,122（95.5%） | 约 557,600（95.5%） |
| 文档文件 / 行 | 2,575 / 180,765 | 2,563 / 179,947 |
| 测试文件 | 1,918 | 1,918（vendor 无测试） |

vendored 代码占比很小但属于结构核心：`vendor/` 的 74 个文件包含 cordis 框架本体及 loader、include、group、timer、hmr、logger-console、cosmokit、schemastery 共 9 个包，全部 rescoped 为 `@deepseek-ai` 名下，清单与 18 项本地修改日志见 `vendor/README.md`；所有产品包把 `@deepseek-ai/cordis` 声明为 peer dependency，`pnpm-workspace.yaml` 通过 linkWorkspacePackages 与 overrides 把保留的上游 semver 解析到 vendored 源码。

仓库形态依据：根 `package.json` 声明 pnpm workspace 与构建脚本（`package.json:7-18,19-143`），工作区成员由 pnpm-workspace.yaml 扩为 vendor、packages、apps、website、examples 与 native/landlock-run、python/sdk-runtime 七个层级。构建分“host / client”两个编译面：tsc -b 先出 lib/types，tsdown 再按面对应的 tsdown 配置打包运行时；测试由 6 个 vitest 配置分管单元、真实 API e2e、快照回放与 Web 三档。开发态 `dsh` 命令经 `node --import tsx/esm` 直接跑 `apps/cli/src/bin.ts` 源码。

## 1. 模块分布与量级

顶层结构按文件与源码行计（源码行只含可识别语言扩展名）：

| 一级目录 | 文件 | 源码行 | 主要职责 |
| --- | ---: | ---: | --- |
| `packages/` | 3,748 | 513,936 | 226 个产品包（46 组） |
| `scripts/` | 158 | 32,895 | 仓库门禁与生成器 |
| `apps/` | 273 | 23,866 | cli 与 web 两个产品装配层 |
| `examples/` | 596 | 6,170 | 可运行 cordis.yml 叶子与回放夹具 |
| `vendor/` | 74 | 6,566 | vendored Cordis 框架层 |
| `python/` | 33 | 2,629 | Python SDK 与捆绑运行时 |
| `native/` | 51 | 1,635 | Landlock 启动器 C 源码与平台包 |
| `.github/` | 27 | 1,119 | CI 工作流 |
| `website/` | 7 | 866 | VitePress 站点投影 |
| `.agents/` | 2,078 | 279 | Agent Notes 与 skills（1,386 个 md + 690 个 yaml） |
| 根目录 | 38 | 548 | 构建、lint、文档验证配置 |

代码主体集中在 `packages/`（87%）。按组排序的前 15 大区域：

| 组 | 文件 | 源码行 | 内容 |
| --- | ---: | ---: | --- |
| `client` | 1,140 | 153,754 | Web 浏览器半区：`ui-*` 界面插件、runtime、connection、web-react |
| `core` | 152 | 40,745 | 产品 API 脊柱：session、system-prompt、tools、agent、agent-loop |
| `subagent` | 150 | 24,486 | 子代理缝隙与 in-process 驱动 |
| `host` | 144 | 22,412 | 网关半区：API 代理、webserver、插件清单 |
| `session` | 146 | 21,442 | 会话持久化（JSONL/SQLite）、投影、标题、遥测 |
| `extensions` | 87 | 21,050 | 运行时自修改：模型编写插件挂载（含 4,751 行的 `api-catalog.ts`） |
| `llm` | 116 | 20,414 | LLM 缝隙、DeepSeek 与 pi-ai 双适配器、token 计量 |
| `typert` | 87 | 15,181 | 类型图生成器、加载器、运行时注册表 |
| `test-support` | 129 | 13,344 | 测试基础设施：快照、回放、mock LLM |
| `fs` | 95 | 13,044 | 文件系统缝隙与策略、文件工具 |
| `session-query` | 71 | 12,319 | 会话检索家族与 SQLite 全文搜索 |
| `shell` | 96 | 10,405 | bash/pwsh 执行缝隙与本地实现 |
| `context` | 52 | 10,251 | 模型可见请求上下文 |
| `sandbox` | 73 | 9,235 | 进程隔离缝隙，bwrap/Landlock/Seatbelt/Windows ACL |
| `compaction` | 54 | 8,032 | 上下文压缩缝隙与基础实现 |

`packages/client` 内部不是单个大包，而是 48 个小包：39 个 `ui-*` 插件各自独立，另有一批支撑包与壳层包。最大的几个界面插件按文件数排序如下表，其余 ui 插件多为 15-30 个文件的中等规模：

| 包 | 文件数 | 包 | 文件数 |
| --- | ---: | --- | ---: |
| `ui-primitives` | 140 | `ui-tool` | 51 |
| `ui-conversation` | 125 | `ui-trajectory` | 50 |
| `runtime` | 75 | `connection` | 35 |

apps/web 只是 vite 壳（其 src 仅 main 与一个 node 桩），真正的界面代码在 client 组的 web 与 web-react 两个包。

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

文档按位置分布（行数含空行与代码块）：

| 位置 | 文件 | 行数 | 说明 |
| --- | ---: | ---: | --- |
| `.agents/notes` | 1,372 | 75,331 | Agent Notes：implemented 505 篇、archived 143、proposed 25、rejected 11，均含中英副本与配对元数据 |
| `docs/` | 215 | 54,584 | 规范文档树：110 个英文页 + 105 个中译页 + i18n 配对 yaml |
| `packages/` | 593 | 29,158 | 268 组 README 三件套（226 个包 + 组级 README）+ 包内 docs 与测试区 README |
| `apps/` | 114 | 4,819 | cli/web 装配层文档与 `apps/web/tests` 测试区文档 |
| `examples/` | 57 | 2,615 | 示例说明与回放夹具说明 |
| `vendor/` | 12 | 818 | vendoring 清单（上游 SHA、本地修改日志） |
| `native/` | 17 | 485 | Landlock 启动器的架构、发布、支持矩阵 |
| `python/` | 8 | 335 | SDK 说明与开发文档 |
| 根目录 | 8 | 522 | README/CONTRIBUTING 双语、THIRD_PARTY_NOTICES、BENCHMARK |
| `.github/`、`scripts/`、`website/` | 11 | 165 | 工作流说明、门禁说明、站点 AGENTS |

机制特征有三。第一，双语采用“三件套”而非翻译目录：每个英文 md 配一个 `*.zh.md` 与一个 `.i18n.yaml` 配对清单，翻译由专用脚本与 `dsh-translate-docs` skill 管理，`verify-translation-pairing` 门禁校验配对完整性。docs/ 的计数因此是页面数（110 英文、105 中译）与配对元数据（105）之和，packages/ 同理。

第二，`docs/` 的 subsystems 子目录是最大单体：46 个英文子系统参考页、26,420 行；其余按 user（26 文件）、cookbook、cordis-tutorial、cordis-api、postmortem 分区。

第三，站点不复制内容：`website/` 只有 7 个文件（vitepress 配置与 `docs.ts` 投影清单），构建时把 docs 源投影成中英路由树，翻译缺失的路由回退投影可用语言版本。

`docs/` 中还有一类生成物，由 `scripts/gen-*.ts` 从源码与配置生成，配 `verify-*` 门禁保证与代码同步，`THIRD_PARTY_NOTICES.md` 同样由生成器维护：

- 生成目录（六个）：tool-catalog、config-catalog、persistence-catalog、module-graph、graph-atlas、cordis-catalog

`.agents/notes` 按状态分目录（implemented、archived、proposed、rejected），归档笔记冻结不可改，另有 11 个开发 skill 分布在 `.agents/skills`。

## 4. 测试分布与数量

测试资产 1,918 个文件 / 338,071 行测试源码行（占全仓源码行约 53%）。按类型与位置：

| 类别 | 数量 |
| --- | ---: |
| 测试代码文件（.ts/.tsx/.py） | 1,055 |
| 夹具/快照资源（jsonl/json/md/txt/yml/snap 等，在测试目录内） | 718 |
| 命名类型拆解：`*.spec.ts` | 692 |
| `*.e2e.ts` | 129 |
| `*.snapshot.ts` | 19 |
| `*.perf.ts`、`*.stress.ts` | 2 |

按位置分布（测试文件数）：

| 位置 | 文件 | 测试源码行 | 说明 |
| --- | ---: | ---: | --- |
| `packages/` | 991 | 268,725 | 226 个包各自的 tests/ 区 |
| `apps/` | 237 | 22,667 | cli 17 个、web 220 个 |
| `examples/` | 489 | 6,008 | acp-agent 385 个回放夹具、headless-agent 84 个 |
| `scripts/` | 45 | 7,709 | 仓库自检 spec |
| `python/` | 7 | 1,509 | SDK pytest |
| `.github/`、`native/` | 3 | 626 | issue 策略与原生层测试 |

本次扫描确认全部 226 个包都有同目录 tests 区（含 client 组全部 48 包），未发现没有测试的产品包；`scripts/` 的 45 个 spec 是仓库级自检（校验 CI 工作流、包路径、构建产物约束、文档引用等），与 `run-gates.ts` 门禁配合构成“仓库自验证”机制。

跨模块测试有三类：

- `apps/web` 的 69 个 e2e：jsdom 中组装构建产物，以 keyless FixtureApiClient 驱动到聊天内容端到端。
- `examples/acp-agent/tests`：385 个 jsonl/json 夹具的 keyless 回放，对应 `test:snapshot` 档。
- `apps/cli/tests`：built-bin 与配置装配。

真实 API 的 e2e（129 个文件）在无 `DEEPSEEK_API_KEY` 的环境自跳过。单包测试以 spec 为主，最大单体是 `packages/extensions/tool-cordis/src/api-catalog.ts` 的配套测试与 `context/agent-instructions` 的 4,648 行 spec。

测试密度差异明显：`packages/client`（291 个测试文件）与 `packages/core`（60 个 / 27,156 行）最重，core 里 session、tools 的 spec 均超 1,700 行；轻量组（identity、guard、runtime-diagnostics 等）只有 1-2 个边界级测试。测试行占比高的区域未必代码行占比高：`examples/acp-agent` 以夹具文件数量取胜但行数少。门禁声明（AGENTS.md、`docs/testing.md`）要求 packages 源码按文件 100% 覆盖率，该声明未运行验证。

## 5. 跨平台与发布组织

产品平台是本地优先的 agent harness，共有四个对外运行面：CLI（apps/cli 的 `dsh` 命令）、Web GUI（浏览器 React + 本地 HTTP 服务端）、进程外 SDK（JSON-RPC 协议三包与 Python SDK）、自动化协议（ACP 服务端、MCP client 包）。没有移动端；没有云端 SaaS 组装层，api/gateway 只是本机 BFF 装配。

平台差异以“同缝隙多 provider 包”组织，而非目录级条件编译：sandbox 组按后端拆 bwrap/Landlock/Seatbelt 与 Windows ACL 包；shell 组按实现拆 bash 与 pwsh 的 local/sandbox 变体；会话持久化是 jsonl 与 sqlite 双后端。

操作系统专属代码可见三处：`native/landlock-run` 只面向 Linux（x64/arm64 平台包与 prebuilds）；Windows 侧有 `sandbox-windows-acl`（C++ ABI 探针 + 14 个测试）、terminal 组经 node-pty 的 ConPTY 后端、JSONL 落盘经 koffi 的 MoveFileExW 写穿发布；macOS 的 Seatbelt 后端在 sandbox 组文档中声明。

CI 矩阵显示 Linux 走自托管 Ubuntu 24.04 runner，Windows 采用“Wine 跑 Node 的阻塞门禁 + windows-native 完整内核清单”双线策略，由 `scripts/wine-windows-gates.sh` 与 `ci.yml` 落实。

发布组织按资产分四族：npm 的 `dsh` 产品族（0.1.0-rc.5，HEAD 提交即“npm-public”公开发布合并）与 vendor 族分别走 `scripts/release/bump.ts` 与 release.yml；Python SDK 经 GitHub 构建 exe、`.gitlab-ci.yml`（本仓唯一 GitLab 资产）负责 wheel 构建与 PyPI 发布，包名 `deepseek-harness-sdk`；Landlock 启动器独立走 landlock-run-release.yml。开发工具链自身是 pnpm 11 + lefthook git 钩子 + oxlint + jscpd + knip/publint，全部版本在根 devDependencies 钉住。

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
- 插件颗粒度取到包级：46 组 226 包，界面按组件包拆分（39 个 `ui-*`），能力按缝隙三件套拆分，依赖方向由生成模块图与约束门禁强制。
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
- `packages/README.md`：46 组职责表与依赖规则
- `packages/llm/llm-pi-ai/package.json:45` 与 `src/{adapter,catalog,config,discovery}.ts`：pi-ai 依赖与适配层
- `apps/cli/src/bin.ts`：`dsh` 源码启动入口
- `apps/web/src/main.ts`、`packages/client/README.md`：Web 壳层与浏览器半区
- `website/docs.ts`：站点投影清单（双语路由）
- `scripts/run-gates.ts`：门禁编排；`scripts/gen-*.ts`：目录生成器
- `.github/workflows/ci.yml`、`.gitlab-ci.yml`：双 CI 平台与 Python 发布
