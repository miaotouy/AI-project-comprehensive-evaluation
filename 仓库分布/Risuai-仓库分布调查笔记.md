# Risuai 仓库分布调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`39f1ac1472d0ef6907ee933c4cf25182ee2aec9f`（分支：`main`）
>
> 调查方式：只读源码 + Git 跟踪文件机械统计，并复核 package.json、vite/vitest、src-tauri、server 与 .github/workflows 等构建和发布入口；未运行构建与测试
>
> 调查范围：仓库形态、模块分布、语言分工、文档、测试、跨平台组织与工程配套，覆盖调查指南全部必查问题；未跟踪文件（dist、node_modules 等）不在统计内
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-11-04）：Git 跟踪文件 600 个；可识别源码 425 文件 / 119,987 行；文档 11 文件 / 2,144 行；测试 32 文件 / 4,144 源码行。主线提交节奏：浅克隆 first-parent 窗口 2026-07-28 至 2026-11-04 共 103 次提交（浅克隆，历史不完整）。

## 结论摘要

Risuai 是单包前端应用与多平台壳合仓的项目：Svelte 5 + TypeScript 的 Web 应用是主体（`src` 占源码行约 95%），同仓附带 Tauri 2 Rust 桌面壳、Node 自托管服务器、Capacitor 移动配置和 Cloudflare Functions 代理。600 个跟踪文件中源码 425 文件 / 119,987 行，TypeScript 79,428 行（66.2%）与 Svelte 34,480 行（28.7%）构成绝大部分；无生成代码影响占比，但跟踪了约 80 MB 的第三方 tokenizer 模型数据（`public/token`）。

业务逻辑集中在 `src/ts`（204 个源码文件 / 67,683 行），其中 `process` 子目录 77 文件 / 30,789 行是聊天、请求、记忆与 MCP 的核心；UI 组件在 `src/lib`（184 文件 / 34,647 行）；多语言文案在 `src/lang`（11,082 行）。`server/hono` 仍是自带锁文件与 wrangler 配置的嵌套独立包，文档声明它将替换 `server/node` 的 Express 服务器。测试 32 文件 / 4,144 行，全部为 Vitest 单元测试，无端到端测试。

主链路入口是 `src/main.ts`：挂载 App 组件后调用 `loadData()`（`src/ts/bootstrap.ts`），按平台分支把存档解码进 DBState 状态树，Tauri 端读文件系统、Web 端走 LocalForage；聊天处理编排在 `src/ts/process/index.svelte.ts`。平台差异由运行时探测承担（`src/ts/platform.ts`）。

## 统计口径与仓库形态

机械统计只计 Git 跟踪文件（600 个），行数为物理行（含空行与注释），语言按扩展名归类，文档按 `.md/.txt` 识别，测试按 `tests`/`__snapshots__` 目录与 `*.test.*` 文件名模式识别；`git rev-parse HEAD` 与本文代码快照一致。模块级行数用同一口径按目录汇总，用于量级描述。

仓库形态是“单根包 + 平台壳 + 服务端合仓”：根 `package.json` 为 private 单包（`packageManager: pnpm@11.28.10`），没有 `packages:` 声明；根目录 `pnpm-workspace.yaml` 只承载 pnpm 11 的构建许可与依赖发布年龄配置，不构成多包工作区。`server/hono` 自带 `package.json`、`tsconfig.json`、`wrangler.jsonc`、独立的 `pnpm-lock.yaml` 与 `pnpm-workspace.yaml`，形成嵌套独立包；`src-tauri` 是 Cargo 包。`dist/` 与 `node_modules/` 未跟踪。

## 1. 模块分布与量级

一级目录量级（源码行只计可识别语言扩展名）：

| 一级目录 | 跟踪文件 | 源码行 | 职责 |
| --- | ---: | ---: | --- |
| `src` | 420 | 114,312 | 前端全部代码：业务逻辑、UI、文案、应用内素材 |
| `public` | 64 | 3,632 | 静态资源、tokenizer 数据、Cloudflare 代理函数、服务 worker、Lua 库 |
| `src-tauri` | 60 | 399 | 桌面壳：Rust 命令层（`main.rs` 与 `build.rs`）、图标、能力配置 |
| `server` | 18 | 1,516 | 自托管服务器：node 可用实现与 hono 骨架 |
| 根目录 | 23 | 154 | 构建配置、Docker、部署脚本、仓库级文档 |
| `.github` | 8 | — | 工作流与 PR 模板 |
| `resources` | 5 | — | Tauri 打包图标与启动图 |

`src` 内部按职责分四块：

- `src/ts` 204 个源码文件 / 67,683 行，是业务层，内部量级如下表；其余 `translator`、`gui`、`drive`、`network`、`media`、`sync`、`horde`、`kei` 均为千行上下的小目录。

| `src/ts` 子目录 | 文件 | 行数 | 职责 |
| --- | ---: | ---: | --- |
| `process` | 78 | 30,789 | 聊天管线主体：`request`、`mcp`（16 文件 / 4,744 行）、`memory` 居前 |
| 顶层散置文件 | 35 | 12,897 | `bootstrap.ts`、`characterCards.ts`、`stores.svelte.ts`、`onboarding.ts`、`cbs.ts` 等单文件模块 |
| `plugins` | 11 | 5,857 | 插件 API v3、权限缓存与沙箱 |
| `storage` | 13 | 4,467 | 数据库、多后端存储、保存文件 KV 块（`saveKV.ts`） |
| `parser` | 13 | 3,771 | 消息解析与 CBS 语法 |
| `model` | 11 | 3,303 | 模型定义与各提供商接入 |
| `setting` | 10 | 1,889 | 设置项数据与注册 |

- `src/lib` 184 文件 / 34,647 行，全部是 Svelte UI 组件，按界面区域分目录：

| `src/lib` 子目录 | 文件 | 行数 | 职责 |
| --- | ---: | ---: | --- |
| `SideBars` | 20 | 9,609 | 侧栏与脚本/词条管理，含入场引导编辑器 |
| `Others` | 33 | 8,361 | 弹窗、帮助与杂项组件，含 `OnboardingModal` |
| `Setting` | 54 | 6,386 | 设置面板与可复用表单包装组件 |
| `ChatScreens` | 14 | 4,471 | 聊天界面主体 |
| `UI` | 43 | 3,756 | GUI/NewGUI/Realm 三套基础组件 |
| `Playground` | 15 | 1,773 | 调试与功能试验面板 |
| `Mobile`、`LiteUI` | 5 | 约 300 | 移动与轻量界面变体 |

- `src/lang` 8 文件 / 11,082 行：`index.ts` 选择逻辑加上 7 个语言包（en、ko、cn、zh-Hant、vi、de、es）。
- `src` 顶层 `main.ts`、`App.svelte`、`LiteMain.svelte`、`preload.ts`、`styles.css` 与类型声明等十余个文件；`src/etc` 为补丁说明、`o200k_base.json` 词表与 `.cbs` 应用内文档。

`server/node` 的主体是单文件 Express 服务器 `server.cjs`（约 1.5 千行），实现静态托管 `dist`、流式代理、限流与 OpenID 登录；`server/hono` 的源码文件合计约 40 行，是 node/bun/cf 三份入口存根加一个 Hono 应用骨架。`src-tauri` 的可识别源码只有 `main.rs`（约 380 行）与 `build.rs`，其余图标、capabilities 与 `gen/schemas` 都是配置与资源。

## 2. 语言分布与运行时分工

| 语言 | 文件 | 行数 | 占比 | 分布与用途 |
| --- | ---: | ---: | ---: | --- |
| TypeScript | 227 | 79,428 | 66.2% | `src/ts` 业务逻辑与 `src/lang` 文案 |
| Svelte | 183 | 34,480 | 28.7% | `src/lib` UI 组件与 `App.svelte` 等入口 |
| JavaScript | 9 | 3,357 | 2.8% | 服务器、浏览器 worker、代理函数、用户脚本 |
| CSS | 1 | 494 | — | `src/styles.css` 全局主题样式 |
| Rust | 2 | 399 | — | Tauri 命令层 |
| Lua | 1 | 325 | — | `public/lua/json.lua`，vendored 库 |
| Python | 1 | 24 | — | 根目录 `t.py` 翻译演示脚本 |
| Shell | 2 | 43 | — | `server.sh` 部署脚本与证书生成脚本 |

TypeScript 与 Svelte 合计约 94.9%，全部是手写业务代码；第三方资源改变的是字节量，不改变行数。JavaScript 的 9 个文件是运行时必需的杂项：`server.cjs`、`public/assets` 下的翻译 worker、`public/sw.js`、`public/functions` 的 Cloudflare 代理函数、`util/risuUserscript.user.js` 与构建辅助文件。

运行时按平台分工：浏览器运行 Svelte 组件与 TypeScript 逻辑；Tauri 桌面由 Rust 层补齐原生能力（原生请求、可按 fetch id 取消的流式响应、OAuth 登录）；Node 运行 `server.cjs`；hono 骨架的目标运行时是 Node/Bun/Cloudflare Workers/Vercel。仓内的本地推理后端（原 `src-tauri/src-python` 的 FastAPI + llama_cpp 服务）在本快照已移除，本地推理改由用户配置的外部 Provider（如 Ollama）承担。

## 3. 文档分布与数量

仓内文档共 11 文件 / 2,144 行：`README.md`（产品介绍，用户文档指向 GitHub Wiki）、`plugins.md`（插件开发指南）、`AGENTS.md`（开发者约定）在根目录；`src/ts/plugins/migrationGuide.md` 是插件 API v2→v3 迁移指南，位于插件代码目录内部。`.github/pull_request_template.md`，`server/node/readme.md` 与 `server/hono/README.md` 各数行，分别声明未来弃用与开发中状态。

其余文档命中来自统计口径，实际并非说明文档：`public/token/glm4/SOURCE.md`、`glm5/SOURCE.md` 是 tokenizer 数据的来源说明，`public/colors.txt` 是颜色清单，`src-tauri/src/mainx.txt` 是遗留存根。应用内帮助内容以 `.cbs` 自定义格式存放在 `src/etc/docs`，不进入 Markdown 文档统计。用户手册主体在仓库外的 GitHub Wiki。

## 4. 测试分布与数量

测试共 32 文件 / 4,144 测试源码行，测试/源码文件比约 7.5%。全部为 Vitest 单元测试（`vitest.config.ts` 使用 happy-dom 环境与 `vitest.setup.ts`，`package.json` 的 `test` 脚本为 `vitest run`），含 fast-check 属性测试；未发现 e2e、Playwright、Cypress 或集成测试目录。统计口径计入快照文件与测试辅助文件。

分布按测试文件数：

- `src/ts/parser` 8 个：CBS 语法的条件、转义、循环、字符串测试与 `chatML`、`chatVar`，以及资源地址清洗（`assetSrcSanitize`）。
- `src/ts/process` 10 个：`coldstorageData`、`files/inlays`、MCP risuaccess 模块、OpenAI responses 请求、`additionalParams`、`scriptings`、`ttsHooks`、`contextualEmbeddingCache`、`chatLoadPages`、`sourcemap`。
- `src/ts/plugins` 2 个：`apiV3/pluginPermissionCache` 与插件 API 相关断言。
- `src/ts/storage` 2 个：`nodeStorage` 与保存格式相关断言。
- 其余分散在 `network`、`media`、`translator` 与 `src/lib/UI/guiRendering`。

Rust 代码与 `drive`、`sync`、`model`、`lang` 目录未识别到同目录或邻近测试文件。项目开发文档（`AGENTS.md` 的 Testing 小节）仍指向 `src/test/runTest.ts`，该目录不在跟踪文件内，属于文档滞后于实现；实际测试入口以根 `vitest.config.ts` 为准。

## 5. 跨平台与发布组织

平台策略是单一 SPA 代码库加运行时探测：`src/ts/platform.ts` 通过 `__TAURI_INTERNALS__`、`__NODE__` 全局标记、hostname 与 user agent 区分本地桌面、Node 服务器、官网 Web 与移动浏览器，同一份 `src` 不经过条件编译即服务全部平台。平台专属差异放在三类外围目录：

- Web：`vite build` 产出 `dist` 供静态托管；`public` 下的服务 worker `sw.js` 与 `manifest.json` 支持 PWA 缓存；`public/functions` 的三个代理函数按 Cloudflare Functions 约定提供 CORS 代理；`util/risuUserscript.user.js` 是 Tampermonkey 用户脚本。
- 桌面：`src-tauri` 是完整 Tauri 2 工程，`main.rs` 注册的命令层提供原生网络请求、可取消的流式事件响应与 OAuth 登录；流式请求按 fetch id 持有 abort 句柄，页面重载时可批量取消，并以空闲超时取代原先的固定总时长；`tauri.conf.json` 声明 deb/rpm/appimage/nsis/app/dmg 六个打包目标、GitHub Releases 更新器与 `risuailocal` 深链。
- 移动：`capacitor.config.ts` 声明 appId 与 `webDir: dist`，但仓库未跟踪 android/ios 原生工程（构建时生成）；移动适配以 `src/lib/Mobile` 组件、`LiteUI` 变体与 `MobileGUI` 状态切换实现。

自托管服务与桌面并行：`server/node/server.cjs` 托管 `dist` 并提供代理与认证，`Dockerfile` + `docker-compose.yml` 以端口 6001 发布；`server/hono` 是面向多运行时（Node、Bun、Cloudflare、Vercel）的替代实现骨架。发布流水线在 `.github/workflows`：`github-actions-builder.yml` 对 production 分支矩阵构建四个平台的 Tauri 产物，`docker-build.yml` 推送 ghcr.io 镜像，`pr-check.yml` 对 main 的 PR 跑类型检查与测试，另有 `mod.yml` 与 `codeql.yml`。

## 6. 工程配套与结构特征

工程配套分布在根目录脚本与工作流中：`package.json` 提供 dev/build/tauribuild/buildsite/runserver/hono:build/check/test 等脚本；`server.bat` 与 `server.sh` 是面向自托管的一键脚本，带 `VITE_RISU_LITE`、`VITE_AD_CLIENT` 等构建期环境变量开关。`pnpm-lock.yaml` 在根目录与 `server/hono` 各一份，体现两个包的独立依赖树。

结构信号（均为本次快照内可观察的事实）：

- `package.json` 的 `sync`、`electron` 脚本指向仓库中不存在的 `electron/` 目录，是失效入口；`AGENTS.md` 目录图里列出的 `dist/` 与 `src/test/` 同样不在跟踪文件内。
- 第三方与生成物被跟踪：`public/token` 约 80 MB 的 tokenizer 模型（覆盖 claude、cohere、deepseek、gemma、glm4/5、llama、mistral、nai、trin 等厂商词表），另有 `public/lua/json.lua`、`src/ts/rpack`、`src/etc/o200k_base.json` 词表、`public/assets` 的 wasm 翻译 worker，以及 `src-tauri/gen/schemas/capabilities.json` 等 Tauri 生成文件。
- 根目录残留开发痕迹：`t.py`（翻译演示脚本）、`src-tauri/key.txt`（含一个固定十六进制值）、`src-tauri/src/mainx.txt`（lib 风格 main 存根）、`.cargo/config.toml`。
- `.gitattributes` 为 `.gitignore` 设置 merge=ours，与文档化的 fork 维护方式呼应。

## 7. 设计取舍与已确认边界

- 平台共享程度高：桌面、Web、自托管共享同一份业务代码与存档格式（`decodeRisuSave`），平台差异收敛在 `platform.ts` 判定和 Rust 命令层，未形成第二套业务实现。
- 网络层多后端并存是刻意结构：Web 用 Cloudflare Functions 代理并可被用户脚本接管，Tauri 用 `native_request`/`streamed_fetch` 命令，Node 自托管用服务端代理；同一 fetch 抽象的三个后端。
- 本地推理后端退场：本快照删除了 `src-tauri/src-python` 与 `src/ts/process/models/local.ts`，桌面端不再下载或引导 Python 环境，本地模型改由 Ollama 等外部 Provider 承担；仓库内只剩根目录 `t.py` 翻译演示脚本。
- `server/node` 与 `server/hono` 并存：前者可用但 readme 声明将被弃用，后者是未来替代骨架，目前源码文件均为入口存根。
- 移动端只保证到“配置 + UI 变体”层次：无原生工程、无移动构建 CI，Capacitor 配置是静态声明，未运行验证。
- 测试覆盖集中在解析器、请求与存储层（最接近数据契约的代码），UI 层仅 1 个渲染测试，未识别到 e2e；这与“无综合测试套件、依赖类型检查”的开发者文档自述一致，但该文档同时描述了不存在的 `src/test/runTest.ts`。

## 8. 未验证事项

- 未运行 `pnpm build`、`pnpm test`、Tauri 与 Docker 构建，跨平台、打包与 CI 相关结论均为静态确认。
- `public/functions` 的部署形态（是否为 Cloudflare Pages/Workers 实际配置）依据目录约定推断，未在配置文件中找到引用。
- `main.rs` 的 `oauth_login` 命令使用写死的占位授权端点，且未确认前端调用路径，功能可用性未验证。
- `src-tauri/key.txt` 的固定值用途不明，未运行无法确认是测试遗留还是运行期依赖。
- 流式请求的取消、页面重载时的批量中止与空闲超时的实际表现未运行验证。
- 未检查未跟踪文件（dist、node_modules），统计仅覆盖跟踪文件口径。

## 9. 关键源码索引

- 主链路入口：`src/main.ts`、`src/ts/bootstrap.ts`（`loadData`）
- 业务编排：`src/ts/process/index.svelte.ts`、`src/ts/stores.svelte.ts`（DBState）
- 平台探测：`src/ts/platform.ts`
- 桌面命令层：`src-tauri/src/main.rs`（`invoke_handler` 注册、`cancel_streamed_fetch`、`cancel_all_streamed_fetch`）
- 存档与存储：`src/ts/storage/risuSave.ts`（`RisuSaveEncoder`/`Decoder`、`kv:` 块）、`src/ts/storage/saveKV.ts`、`src/ts/process/pluginStorageStore.ts`
- 自托管：`server/node/server.cjs`、`server/hono/src/app/index.ts`（骨架）
- 构建与测试配置：`package.json`、`vite.config.ts`、`vitest.config.ts`、`capacitor.config.ts`、`tauri.conf.json`
- 发布工作流：`.github/workflows/github-actions-builder.yml`、`docker-build.yml`、`pr-check.yml`
- Web 外围：`public/sw.js`、`public/functions/proxy.js`、`util/risuUserscript.user.js`
- 文档：`plugins.md`、`src/ts/plugins/migrationGuide.md`
