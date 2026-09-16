# DeepChat 仓库分布调查笔记

> 调查对象：`https://github.com/ThinkInAIXYZ/deepchat`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`31a6b05ab77986b3f8086d9e16c565c3251639e0`（分支：`dev`）
>
> 调查方式：Git 跟踪文件机械统计（`git ls-files` + 逐文件行数，`统计仓库.ps1` 生成底稿），并复核 Electron 构建配置、CI workflow、插件运行时、测试树与主要目录
>
> 调查范围：模块、语言、文档、测试、跨平台、工程配套（CI/脚本/国际化/资源/插件）与结构特征；未运行构建与测试；统计底稿以 2026-09-16 HEAD 为准
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-09-16）：Git 跟踪文件 4,627 个；可识别源码 3,256 文件 / 1,044,518 行；文档 234 文件 / 43,660 行；测试 1,045 文件，其中可识别测试源码 1,040 文件 / 440,721 行。

## 结论摘要

DeepChat 是 Electron/Vue 应用、平台插件与完整测试树合仓的多运行时仓库。`src/main` 大于 renderer，而 `test/main` 与 `test/renderer` 合计约 35 万行；这使测试树成为与产品源码并列的主要仓库组成。

工程配套（CI、打包/签名脚本、23 种语言的 i18n 树、插件与运行时资源）也全部合仓，一级目录按职责分成源码、测试、插件、文档、资源和脚本六类，具体结构与量级见第 1、6 节。

三个子系统均有同目录测试树：

- 本地控制平面 CLI 与审批（`src/main/cli/`、`src/main/approval/`）
- 结构化主进程日志（`src/main/logging/`）
- Tape 执行日志与契约层

## 统计口径与仓库形态

本笔记采用《仓库分布调查指南》的统一口径，快照为当前 HEAD commit 的 Git 跟踪文件：

- **快照边界**：只统计当前 commit 跟踪的 4,627 个文件；不统计 `.git`、未跟踪文件、`node_modules`、构建输出（`out/`、`build/`）与运行时数据。
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

构建编排使用 pnpm（`package.json` 的 `packageManager` 字段声明 `pnpm@10.34.5`，锁文件 `pnpm-lock.yaml` 10,985 行），配合 electron-vite 与 electron-builder 两个构建工具。本地控制平面构建由 `cli:build` 脚本（`scripts/build-cli.mjs`）承担，随 `build` 链执行。

## 1. 模块分布与量级

| 区域 | 跟踪文件 | 源码文件 | 源码行数 |
| --- | ---: | ---: | ---: |
| `src/main` | 874 | 874 | 287,888 |
| `test/main` | 670 | 670 | 274,085 |
| `src/renderer` | 1,462 | 539 | 140,652 |
| `test/renderer` | 275 | 275 | 88,627 |
| `plugins/cua` | 183 | 150 | 35,446 |

口径说明："跟踪文件"为 Git 跟踪总数；"源码文件/行数"为可识别源码口径（含 `.sh/.html/.css`）。各区域两列的一致性如下：

- `src/main`、`test/main`、`test/renderer`：全部为可识别源码文件，两列相同
- `src/renderer`：1,462 个跟踪文件中 539 个为可识别源码，其余为 SVG、JSON、图片等资产
- `plugins/cua`：183 个跟踪文件中 150 个为源码（含 `vendor/cua-driver` 原生驱动源），其余为 `.plist/.json/.gz/.xsd` 等构建与元数据文件

对含资产的目录，文件数与行数来自两个口径（跟踪总数 vs 源码行数），使用时应以"源码文件/行数"两列对比模块量级。

全仓汇总（同口径）：Git 跟踪文件 4,627；可识别源码 3,256 文件 / 1,044,518 行；文档 234 文件 / 43,660 行；测试 1,045 文件，其中可识别测试源码 1,040 文件 / 440,721 行。

主进程和插件承担 Agent、本地运行时及原生能力，renderer 相对更薄。

`src/main` 内的子系统各自在 `test/main` 下有同目录测试树：

- `src/main/cli/`：本地控制平面，含 server/surface/runService/launcherService 等约 25 个文件
- `src/main/approval/`：审批 broker，CLI 与 renderer 共用
- `src/main/logging/`：结构化 JSONL 主进程日志，替代 `electron-log`

对应测试树按同名子目录排列，`test/main/tape/` 覆盖执行记录契约。

## 2. 语言分布与运行时分工

按沿用的语言行数口径，TypeScript 为 741,919 行（约 80.0%）、Vue 为 103,157 行（约 11.1%）、JavaScript/MJS 为 33,852 行（约 3.7%）、Swift 为 25,408 行（约 2.7%）；Python 为 17,075 行（约 1.8%），Shell/HTML/CSS 等合计约 6,054 行（约 0.7%）。Swift 主要来自 `plugins/cua/vendor/cua-driver` 的 macOS 辅助程序源；TypeScript 覆盖主进程、preload 与 renderer 业务逻辑，Vue 集中在 renderer 组件。

## 3. 文档分布与数量

文档共 234 文件 / 43,660 行，主要分布：

| 位置 | 文件数 | 说明 |
| --- | ---: | --- |
| `docs/architecture` | 87 | 架构说明、基线与 spec/tasks |
| `docs/features` | 66 | 功能设计与用户插件等专题文档 |
| `docs/issues` | 6 | 当前保留的问题 spec |
| `resources/skills` | 166 | 打包 Skill 内容本身为 Markdown |
| `docs/guides` | — | `cli.md` 使用与验证指南 |

根级另保留架构、流程、发布流程与规范驱动开发等说明文件；仓库配 `scripts/generate-architecture-baseline.mjs` 与 renderer 版本两个生成脚本维护架构基线。

## 4. 测试分布与数量

测试 1,045 文件，其中可识别测试源码 1,040 文件 / 440,721 行，主分区：

| 分区 | 文件 / 行数 |
| --- | ---: |
| `test/main` | 670 / 274,085 |
| `test/renderer` | 275 / 88,627 |
| `test/e2e` | 46 个跟踪文件（Playwright 与辅助文件） |
| 插件测试 | 约 37 |

另有 `test/manual`（手工/评估入口）以及 fixtures、helpers、mocks 等辅助目录，并配专门的 memory 测试配置（`vitest.config.memory.ts` 等，见 `package.json` 的 `test:memory*` scripts）。

`test/main` 覆盖 session/provider/agent 层，与 `src/main` 规模接近（670 vs 874 文件），是主进程行为契约的主要回归面；Tape、memory、插件、远程渠道和会话投影均有对应测试目录或文件。

## 5. 跨平台与发布组织

Electron 构建明确覆盖 Windows、macOS、Linux 及 x64/arm64 多种架构；插件 bundle、DuckDB VSS 和辅助运行时也按平台分别生成（`package.json` 的 `build:win/mac/linux` 与 `installRuntime:*` 矩阵）。`build` 脚本在类型检查与 electron-vite 构建后追加 `cli:build`（`scripts/build-cli.mjs`），本地控制平面 CLI 可执行文件随主应用构建产出。

平台差异不只位于打包层，还进入插件与运行时：`plugins/cua` 自带 Swift 辅助程序源、沙箱策略（`policies`）与 `build/entitlements.plist`。

macOS 签名与公证另有三个独立脚本（`scripts/notarize.js`、`scripts/notarize-dmg.js`、`scripts/apple-notarization.js`）。

`package.json` 为构建矩阵入口，本次未运行原生插件。运行时版本：Electron 43.6.0、Node 引擎 >=24.18.0 且 <25、应用版本 1.1.2-beta.5。

## 6. 工程配套与结构特征

- **CI**：`.github/workflows/` 共 9 个 workflow，覆盖构建、PR 检查、发布、包校验与回归、Windows arm64 E2E，另有三个平台打包模板（linux/macos/windows）；issue 模板位于 `.github/ISSUE_TEMPLATE/`（bug/feature 模板）。
- **脚本**：`scripts/` 46 个文件，按职责分组：
  - 打包/签名/公证：`afterPack.js`、`notarize*.js`、`build-cua-plugin-runtime.mjs`、`package-plugin.mjs`
  - 本地控制平面构建：`build-cli.mjs`
  - CI 装配：`scripts/ci/`（release-preflight、package-contract、verify-release-assets 等）
  - 外部数据拉取：`fetch-provider-db.mjs`、`fetch-acp-registry.mjs`
  - i18n 生成与校验：`generate-i18n-types.js`、`validate-i18n.mjs`、`lib/i18n-validation.mjs`
  - 架构基线、运行时 smoke 测试（`smoke-duckdb-vss.js`、`smoke-light-ocr.js` 等）与提交钩子（`.githooks/commit-msg`，经 `hooks:install` 启用 commitlint）
- **国际化**：`src/renderer/src/i18n/` 下 23 种语言目录，新增藏文、蒙古文与维吾尔文目录：

  ```text
  bo-CN da-DK de-DE en-US es-ES fa-IR fr-FR he-IL id-ID it-IT ja-JP ko-KR mn-Mong-CN ms-MY pl-PL pt-BR ru-RU tr-TR ug-CN vi-VN zh-CN zh-HK zh-TW
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
- **结构信号**：一级目录按职责分区，无根目录文件堆积；`src/shared` 同时被 main/preload/renderer 引用，是跨进程类型与契约的共享层；`docs/architecture` 与测试树都接近产品源码规模，属于主动维护的配套资产；未发现明显的历史实现并存或同类模块重复（同类目录功能分区见各专题笔记）。

## 7. 设计取舍与已确认边界

- **测试树与源码树平行**：`test/main`（670 文件）与 `src/main`（874 文件）规模接近、目录大体对应，测试与实现按同等级维护；测试源码约占全部可识别源码行的 42.2%。
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
