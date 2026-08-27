# DeepChat 仓库分布调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`7f3379524da3ac629918d35682e38833ad5c203e`（分支：`dev`）
>
> 调查方式：Git 跟踪文件机械统计（`git ls-files` + 逐文件行数，`统计仓库.ps1` 生成底稿），并复核 Electron 构建配置、CI workflow、插件运行时、测试树与主要目录
>
> 调查范围：模块、语言、文档、测试、跨平台、工程配套（CI/脚本/国际化/资源/插件）与结构特征；未运行构建与测试；统计底稿以 2026-08-27 HEAD 为准
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-08-27）：Git 跟踪文件 4584 个；可识别源码 3203 文件 / 1021830 行；文档 310 文件 / 61057 行；测试 1019 文件 / 428289 源码行。提交频率：历史跨度 30 天共 459 次，折算 459 次/30天，近90天 459 次（浅克隆，历史可能不完整）。

## 结论摘要

DeepChat 是 Electron/Vue 应用、平台插件与完整测试树合仓的多运行时仓库。`src/main` 大于 renderer，而 `test/main` 与 `test/renderer` 合计约 35 万行；这使测试树成为与产品源码并列的主要仓库组成，而非少量附属文件。

工程配套（CI、打包/签名脚本、20 种语言的 i18n 树、插件与运行时资源）也全部合仓，一级目录按职责分成源码、测试、插件、文档、资源和脚本六类，具体结构与量级见第 1、6 节。

相较上一批快照，当前净增的跟踪文件和源码主要来自三个新子系统，三者均有同目录测试树：

- 本地控制平面 CLI 与审批（`src/main/cli/`、`src/main/approval/`）
- 结构化主进程日志（`src/main/logging/`）
- Tape 执行日志与契约层

`src/main` 与 `test/main` 的相对位置不变。

## 统计口径与仓库形态

本笔记采用《仓库分布调查指南》的统一口径，快照为当前 HEAD commit `7f337952` 的 Git 跟踪文件：

- **快照边界**：只统计 `git ls-files` 跟踪的 4,584 个文件；不统计 `.git`、未跟踪文件、`node_modules`、构建输出（`out/`、`build/`）与运行时数据。
- **量级单位**：同时记录文件数与物理行数（含空行与注释，用逐行读取计数）。
- **语言识别**：按源文件扩展名归类。"可识别源码"集合含 `.ts/.tsx/.mjs/.js/.vue/.swift/.py/.sh/.html/.css` 等（与 `统计仓库.ps1` 口径一致）；JSON、YAML、锁文件、`.svg`、`.png` 等图片/数据文件不计入编程语言行数。
- **文档识别**：`.md/.mdx/.rst/.adoc/.asciidoc/.txt`。
- **测试识别**：目录名含 `test(s)/spec(s)/__tests__/e2e/playwright/cypress`，或文件名匹配 `.test.*/.spec.*` 等。
- **模块量级**：先按一级目录统计，再结合 `package.json` scripts、构建入口（`electron-vite`/`electron-builder`）与 `src/renderer` 下的独立入口解释真实模块边界。
- **跨平台判定**：`package.json` 构建矩阵与 `electron-builder.yml` 为源码依据；未运行构建，结论属静态确认。

仓库形态：单包（单 `package.json`）+ 多运行时合仓。主应用为 Electron（`src/main` 主进程、`src/preload`、`src/renderer` 渲染进程），`src/renderer` 下另有三个独立入口，各有自己的页面文件：

- `settings/`：设置界面（`src/renderer/settings/App.vue`）
- `floating/`：悬浮窗（`src/renderer/floating/index.html`）
- `browser-overlay/`：浏览器浮层（`src/renderer/browser-overlay/index.html`）

平台插件（`plugins/cua`、`plugins/feishu`）各自包含 mcp、settings、skills 与原生依赖，是自包含单元。

构建编排使用 pnpm（`package.json` 的 `packageManager` 字段声明 `pnpm@10.34.5`，锁文件 `pnpm-lock.yaml` 10,985 行），配合 electron-vite 与 electron-builder 两个构建工具。本地控制平面构建新增 `cli:build` 脚本（`scripts/build-cli.mjs`），随 `build` 链执行。

## 1. 模块分布与量级

| 区域 | 跟踪文件 | 源码文件 | 源码行数 |
| --- | ---: | ---: | ---: |
| `src/main` | 805 | 805 | 282,560 |
| `test/main` | 605 | 605 | 265,279 |
| `src/renderer` | 1,350 | 514 | 136,575 |
| `test/renderer` | 254 | 254 | 85,708 |
| `plugins/cua` | 183 | 150 | 35,446 |

口径说明："跟踪文件"为 Git 跟踪总数；"源码文件/行数"为可识别源码口径（含 `.sh/.html/.css`）。各区域两列的一致性如下：

- `src/main`、`test/main`、`test/renderer`：全部为源码文件，两列相同
- `src/renderer`：1,350 个跟踪文件中 514 个为源码（`.ts` 264、`.vue` 243、`.css` 2、`.html` 5），其余为资产（`.svg` 418、`.json` 401、图片等）
- `plugins/cua`：183 个跟踪文件中 150 个为源码（含 `vendor/cua-driver` 原生驱动源），其余为 `.plist/.json/.gz/.xsd` 等构建与元数据文件

对含资产的目录，文件数与行数来自两个口径（跟踪总数 vs 源码行数），使用时应以"源码文件/行数"两列对比模块量级。

全仓汇总（同口径）：Git 跟踪文件 4,584；可识别源码 3,203 文件 / 1,021,830 行；文档 310 文件 / 61,057 行；测试 1,019 文件 / 428,289 源码行。

主进程和插件承担 Agent、本地运行时及原生能力，renderer 相对更薄；区域量级对比见本节表格。

`src/main` 内的新增目录集中在新子系统，每个子系统在 `test/main` 下有同目录测试树：

- `src/main/cli/`：本地控制平面，含 server/surface/runService/launcherService 等约 25 个文件
- `src/main/approval/`：审批 broker，CLI 与 renderer 共用
- `src/main/logging/`：结构化 JSONL 主进程日志，替代 `electron-log`

对应测试树按同名子目录排列，并新增 `test/main/tape/` 覆盖执行记录契约。

## 2. 语言分布与运行时分工

TypeScript 722,613 行（79.9%）、Vue 99,815 行（11.0%）、JavaScript 33,831 行（3.7%）、Swift 25,408 行（2.8%）；其余为 Python 67 文件/17,075 行（1.9%，主要为 `plugins/cua` 插件脚本与工具）以及 Shell/HTML/CSS 30 文件/6,035 行（0.7%）。Swift 主要来自 `plugins/cua/vendor/cua-driver` 的 macOS 辅助程序源。TypeScript 覆盖主进程、preload 与 renderer 全部业务逻辑；Vue 集中在 renderer 组件；JavaScript 为 `scripts/` 下的打包/构建脚本与插件入口（如 `plugins/feishu/mcp/serve.mjs`）。增量主要来自 TypeScript（+75,186 行），与 CLI/日志/Tape 的新实现一致。

## 3. 文档分布与数量

文档共 282 文件 / 52,977 行，主要分布：

| 位置 | 文件数 | 说明 |
| --- | ---: | --- |
| `docs/architecture` | 116 | 架构说明与基线类 spec/tasks，本次新增 `sidebar-workspace-registration/`、`local-control-plane/` 等 SDD 计划文档 |
| `docs/features` | 64 | 功能文档 |
| `docs/issues` | 20 | 问题 spec，本次新增 `pending-input-explicit-retry`、`pending-input-restart-recovery` 等 |
| `resources/skills` | 39 | Skill 内容本身为 markdown |
| `docs/guides` | — | 本次新增 `cli.md` 使用与验证指南 |

根级另保留架构、流程、发布流程与规范驱动开发等说明文件；仓库配 `scripts/generate-architecture-baseline.mjs` 与 renderer 版本两个生成脚本维护架构基线，说明架构文档与实现保持对照维护。

## 4. 测试分布与数量

测试 953 文件 / 366,497 源码行，主分区：

| 分区 | 文件 / 行数 |
| --- | ---: |
| `test/main` | 605 / 265,279 |
| `test/renderer` | 254 / 85,708 |
| `test/e2e` | 40（Playwright，配置在 `test/e2e/playwright.config.ts`，本次新增启动 smoke 与浏览器路由 smoke 各一个 spec） |
| 插件测试 | 约 37 |

另有 `test/manual`（手工/评估入口）以及 fixtures、helpers、mocks 等辅助目录，并配专门的 memory 测试配置（`vitest.config.memory.ts` 等，见 `package.json` 的 `test:memory*` scripts）。

`test/main` 覆盖 session/provider/agent 层，与 `src/main` 规模接近（605 vs 805 文件），是主进程行为契约的主要回归面；本次增量（约 +63 文件/+38.7 万行中的主要部分）集中在 `test/main/cli/`（约 35 个文件）、`test/main/tape/`（execution journal/contract 契约测试）与 `test/main/logging/`。

## 5. 跨平台与发布组织

Electron 构建明确覆盖 Windows、macOS、Linux 及 x64/arm64 多种架构；插件 bundle、DuckDB VSS 和辅助运行时也按平台分别生成（`package.json` 的 `build:win/mac/linux` 与 `installRuntime:*` 矩阵）。`build` 脚本在类型检查与 electron-vite 构建后追加 `cli:build`（`scripts/build-cli.mjs`），本地控制平面 CLI 可执行文件随主应用构建产出。

平台差异不只位于打包层，还进入插件与运行时：`plugins/cua` 自带 Swift 辅助程序源、沙箱策略（`policies`）与 `build/entitlements.plist`。

macOS 签名与公证另有三个独立脚本（`scripts/notarize.js`、`scripts/notarize-dmg.js`、`scripts/apple-notarization.js`）。

`package.json:58-73` 为构建矩阵入口，本次未运行原生插件。运行时版本：Electron 41.10.4（此前为 40.10.5）、Node 引擎 >=24.18.0、应用版本 1.1.0。

## 6. 工程配套与结构特征

- **CI**：`.github/workflows/` 共 9 个 workflow，覆盖构建、PR 检查、发布、包校验与回归、Windows arm64 E2E，另有三个平台打包模板（linux/macos/windows）；issue 模板位于 `.github/ISSUE_TEMPLATE/`（bug/feature 模板）。
- **脚本**：`scripts/` 46 个文件，按职责分组：
  - 打包/签名/公证：`afterPack.js`、`notarize*.js`、`build-cua-plugin-runtime.mjs`、`package-plugin.mjs`
  - 本地控制平面构建：`build-cli.mjs`
  - CI 装配：`scripts/ci/`（release-preflight、package-contract、verify-release-assets 等）
  - 外部数据拉取：`fetch-provider-db.mjs`、`fetch-acp-registry.mjs`
  - i18n 生成与校验：`generate-i18n-types.js`、`validate-i18n.mjs`、`lib/i18n-validation.mjs`
  - 架构基线、运行时 smoke 测试（`smoke-duckdb-vss.js`、`smoke-light-ocr.js` 等）与提交钩子（`.githooks/commit-msg`，经 `hooks:install` 启用 commitlint）
- **国际化**：`src/renderer/src/i18n/` 下 20 种语言目录，每种约 20 个 JSON 文件：

  ```text
  zh-CN zh-HK zh-TW en-US ja-JP ko-KR da-DK de-DE es-ES fa-IR fr-FR he-IL id-ID it-IT ms-MY pl-PL pt-BR ru-RU tr-TR vi-VN
  ```

  `package.json` 提供 `i18n:validate`、`i18n:types` 与 `i18n`/`i18n:en` 校验命令（基于 i18n-check 工具）。
- **资源**：`resources/` 集中打包期资源，包括：
  - `cdn/`：本地 CDN 依赖副本，供 Artifact React/HTML 运行时使用
  - `acp-registry/`、`model-db/`、`skills/`：协议注册、聚合模型库与技能资产
  - `runtime-versions.json`、`light-ocr-size-budgets.json`、`package-size-{baseline,policy}.json`：版本与体积预算配置
  - 平台图标
- **插件**：两个自包含插件单元，通过 `plugin:bundle` 系列脚本打包进各平台构建：
  - `plugins/cua`：浏览器/计算机使用 Agent 的本地插件，自含 mcp、沙箱策略、settings、skills、types、`vendor/cua-driver` 原生源与 `build/entitlements.plist`
  - `plugins/feishu`：飞书集成插件，自含 mcp 服务入口（`mcp/serve.mjs`）、settings 页面与 skills
- **结构信号**：一级目录分工清晰，无根目录堆积；`src/shared` 同时被 main/preload/renderer 引用，是跨进程类型与契约的共享层；`docs/architecture` 与测试树都接近产品源码规模，属于主动维护的配套资产；未发现明显的历史实现并存或同类模块重复（同类目录功能分区见各专题笔记）。

## 7. 设计取舍与已确认边界

- **测试树与源码树平行**：`test/main`（605 文件）与 `src/main`（805 文件）规模接近、目录一一对应，测试被当作第一等公民维护；代价是仓库总量显著膨胀（测试占全部可识别源码行的 40.5%）。
- **src 与 plugins 分离**：`src/` 是主进程/渲染进程运行时代码，`plugins/` 是带独立运行时契约（mcp、settings 页面、skills、原生 vendor）的插件单元，二者通过 `plugin:bundle` 与构建矩阵在发布期合并，运行期靠插件协议集成。
- **多入口 renderer**：`src/renderer` 除主聊天 UI 外还含三个独立入口（`settings/`、`floating/`、`browser-overlay/`，见仓库形态节），共享同一 `src/renderer/src` 代码树（stores/composables），是"多窗口共享一个 renderer 源"的组织方式。
- **资产与源码同仓**：`src/renderer` 中 835 个非源码文件（svg/json/图片）与源码同目录存放；`resources/` 承载更大的打包资源。本次未统计历史提交的演进，无法判断这些资产是否构成维护负担。
- **生成与第三方代码**：
  - `plugins/cua/vendor`：vendored 原生驱动源
  - `resources/cdn`、`resources/model-db`：本地化第三方数据副本
  - `scripts/fetch-provider-db.mjs`、`scripts/fetch-acp-registry.mjs`：定期刷新上述数据

  以上按指南口径单列标注，未静默剔除。

## 8. 未验证事项

- 未安装依赖、未运行 `pnpm install`、构建（`electron-vite build`/`electron-builder`）与任何测试（vitest/Playwright），全部结论为静态统计与静态确认。
- CI workflow（`build.yml`、`release.yml` 等）只读配置未执行；平台打包产物、公证/签名链与 `plugins/cua` 原生辅助程序的行为未运行验证。
- FTS5 搜索（`deepchat_search_documents_fts`）、DuckDB VSS、Light OCR 等运行时能力依赖安装后的原生构建，可用性未验证。
- 行数统计为物理行数（含空行与注释），未做逻辑行/代码行折算；`vendor` 与 `resources` 第三方数据的影响已按全仓口径标注，未单独计算"排除后口径"。

## 9. 关键源码索引

- `package.json`：应用清单、构建矩阵（`build:win/mac/linux`、`installRuntime:*`、`cli:build`）、lint/test/i18n scripts
- `electron-builder.yml`：打包配置
- `.github/workflows/`：CI/发布编排
- `scripts/`：打包、签名、公证、数据拉取、i18n 校验、smoke 测试、`build-cli.mjs`
- `src/main/`（含 `cli/`、`approval/`、`logging/` 子系统）、`src/preload/`、`src/renderer/`（含 `settings/`、`floating/`、`browser-overlay/` 独立入口）、`src/shared/`：应用运行层
- `plugins/cua`、`plugins/feishu`：平台插件与原生运行时
- `test/main`、`test/renderer`、`test/e2e`：测试树
- `docs/architecture`、`docs/features`：架构/功能文档
- `resources/cdn`、`resources/model-db`、`resources/skills`：打包资源与第三方数据
