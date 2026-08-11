# Jan 仓库分布调查笔记

> 调查对象：`../../jan`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Yarn workspace、Tauri、扩展、文档站与平台脚本
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 是 Web 前端、Tauri/Rust 原生层、可插拔扩展和文档站合仓的 workspace。`web-app/src` 占 119,779 行，Rust 原生层与插件约 3.7 万行；扩展目录把本地推理、RAG、向量库等能力拆成独立包。

## 统计口径与仓库形态

- **快照边界**：只统计当前 commit（`fad3f12a`）的 Git 跟踪文件；不统计 `.git`、未跟踪文件、本地依赖、构建缓存与运行时数据。
- **量级单位**：同时记录文件数与物理行数；行数含空行和注释，只用于仓库内部与同口径项目间的近似量级比较。
- **语言识别**：按源文件扩展名归类（ts/tsx/mts/cts → TypeScript，rs → Rust，swift → Swift）；JSON、YAML、锁文件、图片与二进制不计入编程语言行数。
- **文档识别**：`.md/.mdx/.rst/.adoc/.asciidoc/.txt`，按一级目录与用途解释分布。
- **测试识别**：目录名含 `__tests__`/`tests`/`specs`/`e2e`/`playwright`/`cypress` 或文件名含 `.test.`/`.spec.` 的源码文件；Rust 内嵌测试模块（`tests.rs` 等）不匹配该规则、不计入测试行数——下文测试规模对 Rust 侧偏保守。
- **仓库形态**：Yarn workspaces monorepo（`package.json:5-10` 声明 `core`/`web-app`/`extensions/*`）；web-app 用 Vite 构建（`web-app/package.json:7-8`）、`core/` 用 rolldown 打包（`core/rolldown.config.mjs`）；统一测试为 vitest（`package.json:18-25`）；桌面壳为 Tauri 2（`src-tauri/tauri.conf.json`）。

## 1. 模块分布与量级

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 2,258 |
| 可识别源码 | 1,105 文件 / 191,672 行 |
| 文档 | 157 文件 / 16,735 行 |
| 测试 | 319 文件 / 60,401 源码行 |

主要区域为 `web-app/src`（953 文件/119,779 行）、`src-tauri/src`（52/21,539）、`src-tauri/plugins`（168/13,858）、`extensions/llamacpp-extension`（23/10,477）和文档站 `docs/src`。workspace 将 web-app 与 `extensions/*` 纳入统一依赖图（`package.json:5-10`）。

按职责分：

- `web-app/`：React + Vite 前端主仓（components、routes、hooks、lib 与 locales）；
- `core/`（104 文件/5,034 行）：共享 TS 类型与扩展接口契约，单独打包并可发布 npm（`.github/workflows/publish-npm-core.yml`）；
- `extensions/*`（78 文件/15,440 行）：7 个独立包——llamacpp-extension（本地推理，23/10,477）、mlx-extension、assistant-extension、conversational-extension、rag-extension、vector-db-extension、download-extension；运行时由前端 `web-app/src/lib/extension.ts:62` 的 `ExtensionManager` 动态加载；
- `src-tauri/`（268/37,661）：`src`（核心命令与服务端代理，52/21,539）+ `plugins`（Tauri 插件，168/13,858，各含 guest-js）+ `utils`（13/2,158）；
- `mlx-server/`（11/2,221）：Swift 实现的 macOS MLX 推理服务；
- 其他：`docs/`（Nextra 文档站）、`autoqa/`（26/2,534，Python 自动 QA 框架）、`flatpak/`（Linux 打包清单）。

## 2. 语言分布与运行时分工

TypeScript 147,256 行（76.8%）、Rust 36,437 行（19.0%）、Swift 2,221 行（1.2%）；其余为 Python（1,742，autoqa 5 文件 + docs/tests 1 文件）、JavaScript（1,484）、Shell/CSS 等。

- TypeScript：web-app、core 与全部扩展的前端/扩展逻辑；
- Rust：src-tauri 原生层——服务端代理（`src-tauri/src/core/server/proxy.rs`，3,577 行）、threads/mcp/downloads 命令、Tauri 插件；
- Swift：全部位于 `mlx-server/`（macOS 专属）；
- Python：`autoqa/` 测试框架（另 `docs/tests/conftest.py`）。

语言占比不被生成代码或 vendored 代码显著影响：无大型第三方源码目录（仅 `src-tauri/plugins/tauri-plugin-hardware/src/vendor/` 的 GPU 厂商探测代码，量级小）；llamacpp/mlx 引擎二进制不入库，发布时经 `scripts/download-bin.mjs` 下载。

## 3. 文档分布与数量

文档共 157 文件/16,735 行：`docs/src` 126 文件/11,711 行（Nextra 文档站主体，构建入口 `docs/package.json` 的 `next build`）、`src-tauri/plugins` 6 文件/2,194 行（各插件 README）、根目录 README/CONTRIBUTING 4/806、`.github/ISSUE_TEMPLATE` 4/87。`docs/` 共 554 个跟踪文件，其中 428 个为站点资产（public/static 图片与样式），不计入文档行数。

## 4. 测试分布与数量

测试 319 文件/60,401 源码行：`web-app/src` 256 文件（vitest，随组件与 lib 共置 `__tests__` 目录）、`core/src` 34、`extensions/*` 共 21（llamacpp-extension 9、rag 3、mlx 3、vector-db 2、assistant 2、download 2、conversational 2）、`docs/tests` 3、`autoqa` 2。Rust 侧以 `tests.rs` 内嵌模块为主（如 `src-tauri/src/core/threads/tests.rs`），未计入上述测试文件数。未发现 playwright/cypress/e2e 端到端测试目录。

## 5. 跨平台与发布组织

桌面发布覆盖 Windows、macOS、Linux；构建脚本还提供 Tauri iOS/Android 入口（`package.json:15-47`）。前端共用 `web-app`，桌面/移动差异进入 Tauri feature、原生插件和资源复制步骤；README 当前主要列出桌面发行物（`README.md:66-82`），因此移动端仅能确认源码与构建入口存在，未确认发行成熟度。

- 发布流水线在 `.github/workflows/`：`jan-tauri-build.yaml`（tag `v*.*.*` 触发）、`jan-tauri-build-nightly.yaml`（定时 + 手动）、`template-*-build-*.yml` 为 win/mac/linux/flatpak/external 各平台模板；
- `mlx-server` 仅 macOS（`build:mlx-server`，`package.json:38`），模型源对非 macOS 过滤 mlx（`useModelSources.ts`，见 LLM 渠道管理笔记 §6.5）；
- iOS/Android 走 `--features mobile`（`package.json:29-33`），移动端持久化用 SQLite（见 Chat 笔记 §2.3）。

## 6. 工程配套与结构特征

- **CI**：`.github/workflows/` 34 个文件——`jan-linter-and-test.yml`（push/PR 触发 `yarn test:coverage`）、`jan-tauri-build.yaml`（tag 发布构建）、`jan-docs.yml`（文档站构建部署）、`publish-npm-core.yml`（core 包发布 npm）、`autoqa-*`（手动触发的自动 QA）与各平台构建模板；
- **脚本**：`scripts/download-bin.mjs`（发布时下载 llama-server 等二进制）、`find-missing-i18n-key.js`/`find-missing-translations.js`（i18n 完整性校验）、`rust-coverage.sh`；
- **国际化**：`web-app/src/locales/` 17 个语言目录、256 个文件（每语言一组 JSON，含 `__tests__` 键完整性测试）；
- **自动 QA**：`autoqa/`（Python：main.py + reportportal 上报 + 各平台安装/运行脚本）；
- **打包与资源**：`flatpak/`（`ai.jan.Jan.yml` 等 4 文件）、`src-tauri/resources` 与 `icons`、`src-tauri/tauri.conf.json`；
- **结构信号**：根目录含 34 个 workflow 与 5 个 issue 模板；docs/ 自成一站（独立 package.json，bun.lock 与 yarn.lock 并存）；扩展按引擎/能力一包一目录，边界清晰。

## 7. 设计取舍与已确认边界

- **扩展即独立包**：模型引擎（llamacpp/mlx）、RAG、向量库、下载、助手、会话均拆为 `extensions/*` yarn 包，由前端 `ExtensionManager`（`web-app/src/lib/extension.ts:62`）按名加载，与核心逻辑解耦；代价是扩展间接口以 `@janhq/core` 的 service hub 为契约。
- **引擎二进制不入库**：mlx-server/ 收录 Swift 源码，llamacpp 的 llama-server 二进制由下载脚本在发布/安装时获取（`scripts/download-bin.mjs`），仓库体积不随引擎增长。
- **生成/第三方代码影响**：无大型 vendored 源码，语言占比不受其扰动；docs/ 站点资产（428 个非文档文件）计入跟踪文件数但不计入语言与文档行数口径。
- **口径边界（静态确认）**：Rust 单元测试（tests.rs 内嵌模块）不在测试识别口径内，测试规模对 Rust 侧偏保守；扩展运行时行为（加载、启停）未运行验证。

## 8. 未验证事项

- 未运行构建与测试：CI 全绿与否、`yarn test:coverage` 结果未验证；
- `scripts/download-bin.mjs` 下载的引擎二进制与发布产物清单未核对；
- 移动端（iOS/Android）构建入口与 SQLite 持久化仅静态确认，发行成熟度未确认；
- `docs/` 428 个非文档跟踪资产的具体用途未逐一核对；
- 根目录与各子包依赖版本、docs 目录 bun.lock/yarn.lock 并存的原因未调查。

## 9. 关键源码索引

- `package.json:5-55`：workspace 与桌面/移动构建
- `src-tauri/tauri.conf.json:1-26`：Tauri 应用入口
- `web-app/`、`src-tauri/plugins/`、`extensions/`：主要模块边界
- `.github/workflows/jan-linter-and-test.yml`、`jan-tauri-build.yaml`：CI 与发布
- `scripts/download-bin.mjs`：引擎二进制下载
- `web-app/src/lib/extension.ts:62`：ExtensionManager
- `web-app/src/locales/`：i18n（17 语言目录）
- `core/rolldown.config.mjs`、`docs/package.json`：core 打包与文档站
