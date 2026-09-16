# Jan 仓库分布调查笔记

> 调查对象：`https://github.com/janhq/jan`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`38491c73d12398edda45ebec366f940e83509490`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Yarn workspace、Tauri、扩展、文档站与平台脚本
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-09-16）：Git 跟踪文件 2553 个；可识别源码 1360 文件 / 317465 行；文档 192 文件 / 20616 行；测试 395 文件 / 73104 源码行。主线提交节奏：历史跨度 51 天共 48 次，折算 28.24 次/30天，近90天 48 次（浅克隆，历史可能不完整）。

## 结论摘要

Jan 是 Web 前端、Tauri/Rust 原生层、独立 CLI crate、可插拔扩展和文档站合仓的 workspace。`web-app/src` 约 14.8 万行，`src-tauri`（含插件、utils 与 jan-cli）约 13.5 万行，其中 Rust 增量主要来自新增的 Agent 核心与 CLI/TUI；扩展目录把本地推理、RAG、向量库等能力拆成独立包。

## 统计口径与仓库形态

- **快照边界**：只统计当前 commit 的 Git 跟踪文件；不统计 `.git`、未跟踪文件、本地依赖、构建缓存与运行时数据。
- **量级单位**：同时记录文件数与物理行数；行数含空行和注释，只用于仓库内部与同口径项目间的近似量级比较。
- **语言识别**：按源文件扩展名归类（ts/tsx/mts/cts → TypeScript，rs → Rust，swift → Swift）；JSON、YAML、锁文件、图片与二进制不计入编程语言行数。
- **文档识别**：`.md/.mdx/.rst/.adoc/.asciidoc/.txt`，按一级目录与用途解释分布。
- **测试识别**：目录名含 `__tests__`/`tests`/`specs`/`e2e`/`playwright`/`cypress` 或文件名含 `.test.`/`.spec.` 的源码文件；Rust 内嵌测试模块（`tests.rs` 等）不匹配该规则、不计入测试行数——下文测试规模对 Rust 侧偏保守。
- **仓库形态**：Yarn workspaces monorepo。
  - workspace 声明：`package.json:5-10` 纳入 `core`、`web-app` 与 `extensions/*`
  - 构建工具：web-app 用 Vite（`web-app/package.json:7-8`），`core/` 用 rolldown 打包（`core/rolldown.config.mjs`）
  - 统一测试：vitest（`package.json:18-25`）
  - 桌面壳：Tauri 2（`src-tauri/tauri.conf.json`）

## 1. 模块分布与量级

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 2553 |
| 可识别源码 | 1360 文件 / 317465 行 |
| 文档 | 192 文件 / 20616 行 |
| 测试 | 395 文件 / 73104 源码行 |

主要区域（文件数含该区域全部跟踪文件，行数只统计可识别源码扩展名）：

| 区域 | 文件 / 源码行数 |
| --- | ---: |
| `web-app/src` | 1079 / 148,007 |
| `src-tauri/src` | 102 / 95,798 |
| `src-tauri/plugins` | 190 / 34,774 |
| `extensions/llamacpp-extension` | 22 / 8,475 |
| `src-tauri/jan-cli` | 4 / 1,362 |
| `docs/src` | 607 / 7,859 |

workspace 将 web-app 与 `extensions/*` 纳入统一依赖图（`package.json:5-10`）。

按职责分：

- `web-app/`：React + Vite 前端主仓（components、routes、hooks、lib 与 locales）；
- `core/`（108 文件/5,422 行）：共享 TS 类型与扩展接口契约，单独打包并可发布 npm（`.github/workflows/publish-npm-core.yml`）；
- `extensions/*`（77 文件/13,450 行）：7 个独立包，覆盖本地推理、MLX、助手、会话、RAG、向量库与下载能力，运行时由前端 `web-app/src/lib/extension.ts:62` 的 `ExtensionManager` 动态加载。包清单：

  - `llamacpp-extension`（本地推理，22/8,475）
  - `mlx-extension`
  - `assistant-extension`
  - `conversational-extension`
  - `rag-extension`
  - `vector-db-extension`
  - `download-extension`
- `src-tauri/`（351/134,908）：`src`（核心命令、Agent 核心与 CLI/TUI、服务端代理，102/95,798）+ `plugins`（Tauri 插件，190/34,774，各含 guest-js）+ `utils`（13/2,150）+ `jan-cli`（独立 CLI crate，4/1,362）+ `build-utils`（8/723）；
- `mlx-server/`（11/2,221）：Swift 实现的 macOS MLX 推理服务；
- 其他：`docs/`（Nextra 文档站）、`autoqa/`（26/2,534，Python 自动 QA 框架）、`e2e/`（8 文件，WebdriverIO 端到端测试）、`flatpak/`（Linux 打包清单）。

## 2. 语言分布与运行时分工

TypeScript 175,439 行（55.3%）、Rust 131,774 行（41.5%）、Swift 2,221 行（0.7%）；其余为 Shell（1,832）、Python（1,742，autoqa 5 文件 + docs/tests 1 文件）、JavaScript（1,520）、CSS/SCSS（1,286）、C++（727）、PowerShell（508）、HTML（310）等。

- TypeScript：web-app、core 与全部扩展的前端/扩展逻辑；
- Rust：src-tauri 原生层——Agent 核心与 CLI/TUI（`core/cli/tui.rs` 单文件 33,318 行，占 Rust 增量主体）、服务端代理（`src-tauri/src/core/server/proxy.rs`，2,740 行）、threads/mcp/downloads 命令、Tauri 插件；
- Swift：全部位于 `mlx-server/`（macOS 专属）；
- Python：`autoqa/` 测试框架（另 `docs/tests/conftest.py`）。

语言占比仍不被生成代码显著影响：无大型第三方源码目录（仅 `src-tauri/plugins/tauri-plugin-hardware/src/vendor/` 的 GPU 厂商探测代码，量级小）；Rust 行数中含 TUI 渲染代码与 Agent 核心，属手写实现而非生成物。llamacpp/mlx 引擎二进制不入库，构建与发布时经 `src-tauri/build-utils/` 的预编译与 staging 脚本（`engine-prebuilt.sh`、`stage-engine.sh`、`mlx-prebuilt.sh`）获取。

## 3. 文档分布与数量

文档共 192 文件/20,616 行，主要位置：

- `docs/src`：158 文件/16,020 行，Nextra 文档站主体（构建入口为 `docs/package.json` 的 `next build`）
- `src-tauri/plugins`：7 文件/1,482 行，各插件 README
- 根目录 README/CONTRIBUTING：4 文件/859 行
- `.github/ISSUE_TEMPLATE`：4 文件/87 行

`docs/` 共 734 个跟踪文件，其中约 574 个为站点资产（`public`/`static` 图片与样式），不计入文档行数。

## 4. 测试分布与数量

测试 395 文件/73,104 源码行，主要分布：

- `web-app/src`：318 文件（vitest，随组件与 lib 共置 `__tests__` 目录）
- `core/src`：36
- `extensions/*`：共 23（llamacpp-extension 9 个居首，其余各 2-3 个）
- `e2e/`：8（WebdriverIO）
- `docs/tests`：3；`autoqa`：2

Rust 侧以 `tests.rs` 内嵌模块为主（如 `src-tauri/src/core/threads/tests.rs`、`src-tauri/src/core/server/tests.rs`），未计入上述测试文件数。端到端测试位于 `e2e/`（WebdriverIO，入口 `e2e/wdio.conf.ts`，另有 `e2e/specs/smoke.e2e.ts`），使用独立的 TypeScript 工程，不计入 vitest 口径。

## 5. 跨平台与发布组织

桌面发布覆盖 Windows、macOS、Linux；构建脚本还提供 Tauri iOS/Android 入口（`package.json:15-47`）。前端共用 `web-app`，桌面/移动差异进入 Tauri feature、原生插件和资源复制步骤；README 当前主要列出桌面发行物（`README.md:66-82`），因此移动端仅能确认源码与构建入口存在，未确认发行成熟度。

- 发布流水线在 `.github/workflows/`：`jan-tauri-build.yaml`（tag `v*.*.*` 触发）、`jan-tauri-build-nightly.yaml` 与 `jan-tauri-build-agent-nightly.yaml`（定时 + 手动）、`template-tauri-build-*.yml` 为 win/mac/linux/flatpak/external 各平台模板，另有 `template-cli-build-*.yml` 五个平台模板构建独立 CLI 二进制；
- `mlx-server` 仅 macOS（`build:mlx-server`，`package.json:38`），模型源对非 macOS 过滤 mlx（`useModelSources.ts`，见 LLM 渠道管理笔记 §6.5）；
- iOS/Android 走 `--features mobile`（`package.json:29-33`），移动端持久化用 SQLite（见 Chat 笔记 §2.3）。

## 6. 工程配套与结构特征

- **CI**：`.github/workflows/` 38 个文件：
  - `jan-linter-and-test.yml`：push/PR 触发 `yarn test:coverage`
  - `rust-check.yml`、`e2e-check.yml`：Rust 检查与新端到端测试流水线
  - `engine-build.yml`：引擎构建（llamacpp/MLX 预编译与缓存）
  - `jan-tauri-build.yaml`：tag 触发发布构建
  - `jan-docs.yml`：文档站构建部署
  - `publish-npm-core.yml`：core 包发布 npm
  - `autoqa-*`：手动触发的自动 QA
  - 各平台构建模板
- **脚本**：
  - `scripts/download-bin.mjs`：发布时下载 llama-server 等二进制
  - `src-tauri/build-utils/`：引擎预编译与 staging（`engine-prebuilt.sh`、`stage-engine.sh`、`fetch-engine-source.sh`、`mlx-prebuilt.sh`、`sign-engine.sh`）
  - `scripts/install-jan-agent.sh`/`.ps1`、`jan-agent.sh`、`build-tui.sh`：CLI/TUI 安装与构建
  - `find-missing-i18n-key.js`、`find-missing-translations.js`：i18n 完整性校验
  - `rust-coverage.sh`：Rust 覆盖率
- **国际化**：`web-app/src/locales/` 18 个语言目录、239 个文件（每语言一组 JSON，含 `__tests__` 键完整性测试）；
- **自动 QA**：`autoqa/`（Python：main.py + reportportal 上报 + 各平台安装/运行脚本）；
- **打包与资源**：
  - `flatpak/`：Linux 打包清单（`ai.jan.Jan.yml` 等 4 文件）
  - `src-tauri/resources`、`icons`：打包资源与图标
  - `src-tauri/tauri.conf.json`：Tauri 应用配置
- **结构信号**：根目录含 38 个 workflow 与 5 个 issue 模板；docs/、e2e/ 各自成为一个独立 yarn 工程（各自带 package.json 与 yarn.lock，docs 另有 bun.lock）；扩展按引擎/能力一包一目录，`src-tauri/jan-cli` 是脱离 Tauri 的独立 crate。

## 7. 设计取舍与已确认边界

- **扩展即独立包**：模型引擎（llamacpp/mlx）、RAG、向量库、下载、助手、会话均拆为 `extensions/*` yarn 包，由前端 `ExtensionManager`（`web-app/src/lib/extension.ts:62`）按名加载，与核心逻辑解耦；代价是扩展间接口以 `@janhq/core` 的 service hub 为契约。
- **引擎二进制不入库**：mlx-server/ 收录 Swift 源码，llamacpp 引擎由 `src-tauri/build-utils/` 的预编译/staging 脚本在构建期获取并打包进随附 worker，仓库体积不随引擎增长。
- **生成/第三方代码影响**：无大型 vendored 源码，语言占比不受其扰动；docs/ 站点资产（约 574 个非文档文件）计入跟踪文件数但不计入语言与文档行数口径。
- **口径边界（静态确认）**：Rust 单元测试（tests.rs 内嵌模块）不在测试识别口径内，测试规模对 Rust 侧偏保守；扩展运行时行为（加载、启停）未运行验证。

## 8. 未验证事项

- 未运行构建与测试：CI 全绿与否、`yarn test:coverage` 结果未验证；
- `src-tauri/build-utils/` 预编译/staging 出的引擎产物与发布清单未核对；
- 移动端（iOS/Android）构建入口与 SQLite 持久化仅静态确认，发行成熟度未确认；
- `docs/` 约 574 个非文档跟踪资产的具体用途未逐一核对；
- `e2e/`（WebdriverIO）用例是否在 CI 中稳定运行未验证；
- 根目录与各子包依赖版本、docs 目录 bun.lock/yarn.lock 并存的原因未调查。

## 9. 关键源码索引

- `package.json:5-55`：workspace 与桌面/移动构建
- `src-tauri/tauri.conf.json:1-26`：Tauri 应用入口
- `web-app/`、`src-tauri/plugins/`、`extensions/`、`src-tauri/jan-cli/`：主要模块边界
- `.github/workflows/jan-linter-and-test.yml`、`rust-check.yml`、`e2e-check.yml`、`engine-build.yml`、`jan-tauri-build.yaml`：CI 与发布
- `src-tauri/build-utils/stage-engine.sh`、`engine-prebuilt.sh`：引擎构建期打包
- `web-app/src/lib/extension.ts:62`：ExtensionManager
- `web-app/src/locales/`：i18n（18 语言目录）
- `core/rolldown.config.mjs`、`docs/package.json`、`e2e/wdio.conf.ts`：core 打包、文档站与端到端测试
