# Jan 仓库分布调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Yarn workspace、Tauri、扩展运行时、文档站与平台脚本
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-11-04）：Git 跟踪文件 3005 个；可识别源码 1546 文件 / 459721 行；文档 217 文件 / 27124 行；测试 490 文件 / 102904 源码行。主线提交节奏：本仓库为浅克隆，可见历史跨度 2026-07-28 至 2026-11-04 共 99 天、1197 次非合并提交，折算约 363 次/30 天；其中近 90 天 929 次。浅克隆意味着更早的历史不在本地，节奏只能按可见区间估算。

## 结论摘要

Jan 是 Web 前端、Tauri/Rust 原生层、独立 CLI crate、可运行时安装的扩展、共享能力包与文档站合仓的 workspace。`web-app/src` 约 17.3 万行；`src-tauri`（含插件、utils 与 jan-cli）约 24.4 万行，Rust 侧的体量增长主要来自并入 `src-tauri/src/core/` 的 Agent 核心与 CLI/TUI（`tui.rs` 单文件约 5.4 万行）。与旧快照相比多了两类目录：`packages/`（extension-api、extension-runtime、adk）把扩展契约与 SDK 抽成可发布包，`protocol/` 与 `adk/` 把对外 RPC 协议与 Python 实现纳入仓库。

## 统计口径与仓库形态

- **快照边界**：只统计当前 commit 的 Git 跟踪文件；不统计 `.git`、未跟踪文件、本地依赖、构建缓存与运行时数据。
- **量级单位**：同时记录文件数与物理行数；行数含空行和注释，只用于仓库内部与同口径项目间的近似量级比较。
- **语言识别**：按源文件扩展名归类（ts/tsx/mts/cts → TypeScript，rs → Rust，swift → Swift）；JSON、YAML、锁文件、图片与二进制不计入编程语言行数。
- **文档识别**：`.md/.mdx/.rst/.adoc/.asciidoc/.txt`，按一级目录与用途解释分布。
- **测试识别**：目录名含 `__tests__`/`tests`/`specs`/`e2e`/`playwright`/`cypress` 或文件名含 `.test.`/`.spec.` 的源码文件；Rust 内嵌测试模块（`tests.rs` 等）不匹配该规则、不计入测试行数——下文测试规模对 Rust 侧偏保守。
- **仓库形态**：Yarn workspaces monorepo。
  - workspace 声明：根 `package.json` 纳入 `core`、`web-app`、`extensions/*`、`packages/*` 与 `extensions-samples/*`
  - 构建工具：web-app 用 Vite，`core/` 用 rolldown 打包（`core/rolldown.config.mjs`），扩展包各自带 rolldown 配置
  - 统一测试：vitest；仅 `src-tauri/jan-cli` 是独立 Rust crate，带自己的 `Cargo.lock`
  - 桌面壳：Tauri 2（`src-tauri/tauri.conf.json`）
  - 工具链：仓库根多出 `rust-toolchain.toml`，Rust 版本随仓库固定

## 1. 模块分布与量级

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 3005 |
| 可识别源码 | 1546 文件 / 459721 行 |
| 文档 | 217 文件 / 27124 行 |
| 测试 | 490 文件 / 102904 源码行 |

主要区域（文件数含该区域全部跟踪文件，行数只统计可识别源码扩展名）：

| 区域 | 文件 / 源码行数 |
| --- | ---: |
| `web-app/src` | 1204 / 172,951 |
| `src-tauri/src` | 224 / 177,046 |
| `src-tauri/plugins` | 230 / 58,474 |
| `extensions/` | 71 / 15,047 |
| `src-tauri/jan-cli` | 13 / 7,280 |
| `src-tauri/utils` | 14 / 2,826 |
| `packages/` | 61 / 6,661 |
| `core/src` | 86 / 4,358 |
| `e2e/` | 27 / 3,919 |
| `docs/src` | 632 / 7,333 |

按职责分：

- `web-app/`：React + Vite 前端主仓（components、routes、hooks、lib、locales），内置扩展宿主 `lib/extensions/` 与服务总线 `services/`；
- `core/`：浏览器侧共享 TS 运行时（约 4.4 千行），提供扩展工具箱、设置、模型类型与 `createServiceRegistry`，单独打包并发布 npm；
- `packages/`：三个新包。`extension-api` 是扩展可用的稳定 API（清单校验、贡献点、能力、语义化版本兼容、API 报告），`extension-runtime` 是 worker 侧的扩展运行协议（握手、句柄、端点），`adk` 是由 RPC schema 生成类型的 JavaScript 客户端与运行时安装器；
- `protocol/`：对外协议产物——事件 schema 与 RPC schema 两份 JSON，与服务端实现一起做契约一致性校验；
- `extensions/*`（71 文件 / 15,047 行）：6 个扩展包，覆盖本地推理、MLX、助手、RAG、向量库与下载。旧快照的 `conversational-extension` 已不在，其职责并入 `assistant-extension`。包清单：
  - `llamacpp-extension`（本地推理）
  - `mlx-extension`
  - `assistant-extension`
  - `rag-extension`
  - `vector-db-extension`
  - `download-extension`
- `src-tauri/`（约 24 万行）：`src`（核心命令、并入的 Agent 核心与 CLI/TUI、服务端代理）+ `plugins`（8 个 Tauri 插件：agent-tools、extensions、hardware、llamacpp、mlx、rag、vector-db、websearch，各含 guest-js）+ `utils` + `jan-cli`（独立 crate，`src/main.rs` 加 9 个集成测试文件，测 ACP、agent RPC、host tools、遥测与 TUI 信号）+ `build-utils`；
- `adk/python/`：对外 Agent SDK 的 Python 实现，与 `packages/adk` 的 JavaScript 实现并列；
- `mlx-server/`（11 文件）：Swift 实现的 macOS MLX 推理服务；
- 其他：`docs/`（Nextra 文档站）、`autoqa/`（25 文件，Python 自动 QA 框架）、`e2e/`（27 文件，WebdriverIO 端到端测试）、`examples/` 与 `extensions-samples/`（扩展示例）、`flatpak/`（Linux 打包清单）。

## 2. 语言分布与运行时分工

TypeScript 213,044 行（46.3%，ts 124,914 + tsx 88,130）、Rust 244,451 行（53.2%）、Swift 2,226 行（0.5%）；其余为 Shell、Python（autoqa 与文档测试）、JavaScript、CSS/SCSS、C++、PowerShell、HTML 等。

- TypeScript：web-app、core、packages 与全部扩展包的前端/扩展逻辑；
- Rust：src-tauri 原生层——并入的 Agent 核心与 CLI/TUI（`src-tauri/src/core/cli/tui.rs` 约 5.4 万行，占 Rust 主体）、服务端代理（`src-tauri/src/core/server/proxy.rs` 约 3.1 千行）、threads/mcp/downloads 命令、8 个 Tauri 插件；
- Swift：全部位于 `mlx-server/`（macOS 专属）；
- Python：`autoqa/` 测试框架、`adk/python/` SDK 与文档测试。

语言占比不被生成代码显著影响：`packages/adk` 的 RPC 类型是生成物但体量小；无大型第三方源码目录（仅 `src-tauri/plugins/tauri-plugin-hardware/src/vendor/` 的 GPU 厂商探测代码）。llamacpp/mlx 引擎二进制不入库，构建与发布时经 `src-tauri/build-utils/` 的预编译与 staging 脚本获取；扩展包只有在运行时安装的 npm 包才以产物形式进入数据目录。

## 3. 文档分布与数量

文档共 217 文件 / 27,124 行，主要位置：

- `docs/src`：179 文件，Nextra 文档站主体（构建入口为 `docs/package.json` 的 `next build`）
- `src-tauri/plugins`：7 文件，各插件 README
- `extensions/`：3 文件（贡献指南与包说明）
- 根目录 README/SECURITY/CONTRIBUTING：5 文件
- `.github/ISSUE_TEMPLATE`：4 文件
- `packages/`：2 文件（adk、extension-api 的 README）
- `adk/`、`extensions-samples/`：各 1 文件

`docs/` 共 759 个跟踪文件，其中 578 个为站点资产（`docs/src` 里的图片与样式、`docs/public` 等），不计入文档行数。

## 4. 测试分布与数量

测试 490 文件 / 102,904 源码行，主要分布：

- `web-app/src`：389 文件（vitest，随组件与 lib 共置 `__tests__` 目录）
- `core/src`：31
- `extensions/*`：26（每个扩展包带自己的 vitest 配置与测试）
- `src-tauri/`：23（`jan-cli` 的 9 个集成测试加插件测试文件，如 `jan-cli/tests/agent_rpc.rs`、`rpc_parity.rs`、`stream_json_host_tools.rs`）
- `packages/`：9（extension-api 的清单/版本/可释放对象测试、extension-runtime 的 RPC 与打包测试、adk 的安装与类型测试）
- `e2e/`：9（WebdriverIO）

Rust 侧另有以 `tests.rs` 内嵌模块为主的单元测试（如 `src-tauri/src/core/threads/tests.rs`、`src-tauri/src/core/server/tests.rs`），未计入上述测试文件数。端到端测试位于 `e2e/`（WebdriverIO，入口 `e2e/wdio.conf.ts`，另有 `e2e/specs/smoke.e2e.ts`），使用独立的 TypeScript 工程，不计入 vitest 口径。

## 5. 跨平台与发布组织

桌面发布覆盖 Windows、macOS、Linux；构建脚本还提供 Tauri iOS/Android 入口。前端共用 `web-app`，桌面/移动差异进入 Tauri feature、原生插件和资源复制步骤；README 当前主要列出桌面发行物，因此移动端仅能确认源码与构建入口存在，未确认发行成熟度。

- 发布流水线在 `.github/workflows/`（42 个文件）：`jan-tauri-build.yaml`（tag `v*.*.*` 触发）、`jan-tauri-build-nightly.yaml` 与 `jan-tauri-build-agent-nightly.yaml`（定时 + 手动）、`template-tauri-build-*.yml` 为 win/mac/linux/flatpak/external 各平台模板，`template-cli-build-*.yml` 构建独立 CLI 二进制，另有 SDK 与扩展示例相关流水线；
- `mlx-server` 仅 macOS（`build:mlx-server` 脚本），模型源对非 macOS 过滤 mlx（`useModelSources.ts`，见 LLM 渠道管理笔记 §6.5）；
- iOS/Android 走 `--features mobile`（根 `package.json` 的构建脚本），移动端持久化用 SQLite（见 Chat 笔记 §2.3）。

## 6. 工程配套与结构特征

- **CI**：`.github/workflows/` 42 个文件：
  - `jan-linter-and-test.yml`：push/PR 触发 `yarn test:coverage`
  - `rust-check.yml`、`e2e-check.yml`：Rust 检查与端到端测试流水线
  - `engine-build.yml`：引擎构建（llamacpp/MLX 预编译与缓存）
  - `jan-tauri-build.yaml`：tag 触发发布构建
  - `jan-docs.yml`：文档站构建部署
  - `publish-npm-core.yml`：core 包发布 npm；另见 `packages/*` 各自的发布配置
  - `autoqa-*`：手动触发的自动 QA
  - 各平台构建模板
- **脚本**：
  - `scripts/download-bin.mjs`：发布时下载 llama-server 等二进制
  - `src-tauri/build-utils/`：引擎预编译与 staging（`engine-prebuilt.sh`、`stage-engine.sh`、`fetch-engine-source.sh`、`mlx-prebuilt.sh`、`sign-engine.sh`）
  - `scripts/install-jan-agent.sh`/`.ps1`、`jan-agent.sh`、`build-tui.sh`：CLI/TUI 安装与构建
  - `find-missing-i18n-key.js`、`find-missing-translations.js`：i18n 完整性校验
  - `rust-coverage.sh`：Rust 覆盖率
- **国际化**：`web-app/src/locales/` 18 个语言目录、240 个文件（每语言一组 JSON，含 `__tests__` 键完整性测试）；
- **自动 QA**：`autoqa/`（Python：main.py + reportportal 上报 + 各平台安装/运行脚本）；
- **打包与资源**：
  - `flatpak/`：Linux 打包清单（`ai.jan.Jan.yml` 等）
  - `src-tauri/resources`、`icons`：打包资源与图标
  - `src-tauri/tauri.conf.json`：Tauri 应用配置
- **结构信号**：根目录含 42 个 workflow 与 5 个 issue 模板；docs/、e2e/ 各自成为一个独立工程（各自带 package.json 与锁文件）；扩展按引擎/能力一包一目录，契约与运行时抽到 `packages/`；`src-tauri/jan-cli` 仍是脱离 Tauri 的独立 crate，但核心逻辑在 `src-tauri/src/core/cli/` 共享。

## 7. 设计取舍与已确认边界

- **扩展即独立包，并可运行时安装**：模型引擎（llamacpp/mlx）、RAG、向量库、下载、助手均拆为 `extensions/*` 包，由 `web-app/src/lib/extensions/` 的宿主按清单加载；扩展只能看见 `@janhq/extension-api` 声明的能力与贡献点，运行在 worker 里经 RPC 使用宿主服务。代价是多了一层版本化契约与隔离边界。
- **Rust 单一内核，多表面复用**：Agent 核心、CLI/TUI 与对外 RPC/ACP 入口都在 `src-tauri/src/core/`，桌面、`jan` 二进制与外部 SDK 共用同一实现，产物差异只在编译目标与入口。
- **引擎二进制不入库**：mlx-server/ 收录 Swift 源码，llamacpp 引擎由 `src-tauri/build-utils/` 的预编译/staging 脚本在构建期获取并打包进随附 worker，仓库体积不随引擎增长。
- **生成/第三方代码影响**：无大型 vendored 源码，语言占比不受其扰动；`packages/adk` 的 RPC 类型由 schema 生成，体量小；docs/ 站点资产（578 个非文档文件）计入跟踪文件数但不计入语言与文档行数口径。
- **口径边界（静态确认）**：Rust 单元测试（tests.rs 内嵌模块）不在测试识别口径内，测试规模对 Rust 侧偏保守；浅克隆下提交节奏只覆盖可见区间；扩展运行时行为（安装、加载、崩溃恢复）未运行验证。

## 8. 未验证事项

- 未运行构建与测试：CI 全绿与否、`yarn test:coverage` 结果未验证；
- `src-tauri/build-utils/` 预编译/staging 出的引擎产物与发布清单未核对；
- 移动端（iOS/Android）构建入口与 SQLite 持久化仅静态确认，发行成熟度未确认；
- `docs/` 578 个非文档跟踪资产的具体用途未逐一核对；
- `e2e/`（WebdriverIO）用例是否在 CI 中稳定运行未验证；
- 根目录与各子包依赖版本、docs 目录多锁文件并存的原因未调查；
- 浅克隆导致更早的提交历史与目录演化不可见，本页的时间跨度与节奏只反映可见区间。

## 9. 关键源码索引

- 根 `package.json`：workspace 声明与桌面/移动构建脚本
- `src-tauri/tauri.conf.json`：Tauri 应用入口
- `web-app/`、`src-tauri/src/`、`src-tauri/plugins/`、`extensions/`、`packages/`、`protocol/`、`adk/`、`src-tauri/jan-cli/`：主要模块边界
- `.github/workflows/jan-linter-and-test.yml`、`rust-check.yml`、`e2e-check.yml`、`engine-build.yml`、`jan-tauri-build.yaml`：CI 与发布
- `src-tauri/build-utils/stage-engine.sh`、`engine-prebuilt.sh`：引擎构建期打包
- `web-app/src/lib/extensions/host.ts`：扩展宿主入口
- `web-app/src/locales/`：i18n（18 语言目录）
- `core/rolldown.config.mjs`、`docs/package.json`、`e2e/wdio.conf.ts`：core 打包、文档站与端到端测试
- `rust-toolchain.toml`：固定 Rust 工具链
