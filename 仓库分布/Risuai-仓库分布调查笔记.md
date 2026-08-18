# Risuai 仓库分布调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-08-17
>
> 代码快照：`0551d283faeba6e73899b01dd85ea38307b24699`（分支：`main`）
>
> 调查方式：只读源码 + `统计仓库.ps1` 机械统计，并复核 package.json、vite/vitest、src-tauri、server 与 .github/workflows 等构建和发布入口；未运行构建与测试
>
> 调查范围：仓库形态、模块分布、语言分工、文档、测试、跨平台组织与工程配套，覆盖调查指南全部必查问题；未跟踪文件（dist、node_modules 等）不在统计内
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 是单包前端应用与多平台壳合仓的项目：Svelte 5 + TypeScript 的 Web 应用是主体（`src` 占源码行 94.7%），同仓附带 Tauri 2 Rust 桌面壳、Node 自托管服务器、Capacitor 移动配置和 Cloudflare Functions 代理。584 个跟踪文件中源码 412 文件 / 126,194 行，TypeScript 82,706 行（65.5%）与 Svelte 36,389 行（28.8%）构成绝大部分；无生成代码影响占比，但跟踪了约 80 MB 的第三方 tokenizer 模型数据（`public/token`）。

业务逻辑集中在 `src/ts`（71,247 行），其中 `process` 子目录约 3 万行是聊天、请求、记忆与 MCP 的核心；UI 组件在 `src/lib`（36,646 行）；多语言文案在 `src/lang`（10,685 行）。根目录没有 workspace 声明，唯一的嵌套独立包是开发中的 `server/hono`，文档声明它将替换 `server/node` 的 Express 服务器。测试共 25 文件 / 4,147 行，全部为 Vitest 单元测试，无端到端测试。

主链路入口是 `src/main.ts:16-19`：挂载 App 组件后调用 `loadData()`（`src/ts/bootstrap.ts:55`），按平台分支把存档解码进 DBState 状态树，Tauri 端读文件系统、Web 端走 LocalForage；聊天处理编排在 `src/ts/process/index.svelte.ts`。平台差异由运行时探测承担，三个探测标记见 `src/ts/platform.ts:19-22`。

## 统计口径与仓库形态

机械统计使用本目录 `统计仓库.ps1` 的统一口径：只计 Git 跟踪文件（584 个），行数为物理行（含空行与注释），语言按扩展名归类，文档按 `.md/.txt` 等扩展名识别，测试按 `tests`/`__snapshots__` 目录与 `*.test.*` 文件名模式识别；`git rev-parse HEAD` 与任务给定的快照 SHA 一致。补充的模块级行数（标注“约”）用 PowerShell 分行计数获得，与脚本数值存在少量口径差异，仅用于量级描述。

仓库形态是“单根包 + 平台壳 + 服务端合仓”：根 `package.json` 为 private 单包（`packageManager: pnpm@10.34.1`），无 pnpm workspace、lerna 或 turborepo 等编排声明；`server/hono` 自带 `package.json`、`tsconfig.json`、`wrangler.jsonc` 与独立的 `pnpm-lock.yaml`，形成嵌套独立包；`src-tauri` 是 Cargo 包。`dist/` 与 `node_modules/` 未跟踪，构建产物不入仓。

## 1. 模块分布与量级

一级目录量级（源码行只计可识别语言扩展名）：

| 一级目录 | 跟踪文件 | 源码行 | 职责 |
| --- | ---: | ---: | --- |
| `src` | 402 | 119,540 | 前端全部代码：业务逻辑、UI、文案、应用内素材 |
| `public` | 64 | 4,076 | 静态资源、tokenizer 数据、Cloudflare 代理函数、服务 worker、Lua 库 |
| `src-tauri` | 64 | 753 | 桌面壳：Rust 命令层、内嵌 Python 助手、图标、能力配置 |
| `server` | 17 | 1,594 | 自托管服务器：node 可用实现与 hono 骨架 |
| 根目录 | 23 | 213 | 构建配置、Docker、部署脚本、仓库级文档 |
| `.github` | 7 | 0 | 5 个工作流与 PR 模板 |
| `resources` | 5 | 0 | Tauri 打包图标与启动图 |

`src` 内部按职责分四块：

- `src/ts` 197 文件 / 71,247 行，是真正的业务层，内部量级如下表；其余 `translator`、`drive`、`gui`、`network`、`media`、`sync`、`horde`、`kei` 等均为千行以下的小目录。

| `src/ts` 子目录 | 文件 | 约行数 | 职责 |
| --- | ---: | ---: | --- |
| `process` | 75 | 30,000 | 聊天管线主体：request 约 6.8 千行、mcp 约 4.7 千行、memory 约 3.8 千行居前 |
| 顶层散置文件 | 31 | 12,500 | `bootstrap.ts`、`characterCards.ts`、`stores.svelte.ts`、`cbs.ts` 等单文件模块 |
| `plugins` | 9 | 5,500 | 插件 API v3 与沙箱 |
| `storage` | 11 | 4,000 | 数据库与多后端存储 |
| `parser` | 11 | 3,500 | 消息解析与 CBS 语法 |
| `model` | 11 | 3,200 | 模型定义与各提供商接入 |
| `setting` | 10 | 1,900 | 设置项数据与注册 |

- `src/lib` 180 文件 / 36,646 行，全部是 Svelte UI 组件，按界面区域分目录：

| `src/lib` 子目录 | 文件 | 约行数 | 职责 |
| --- | ---: | ---: | --- |
| `SideBars` | 19 | 9,400 | 侧栏与脚本/词条管理 |
| `Others` | 31 | 7,800 | 弹窗、帮助与杂项组件 |
| `Setting` | 54 | 6,400 | 设置面板与可复用表单包装组件 |
| `ChatScreens` | 14 | 4,300 | 聊天界面主体 |
| `UI` | 42 | 3,700 | GUI/NewGUI/Realm 三套基础组件 |
| `Playground` | 15 | 1,800 | 调试与功能试验面板 |
| `Mobile`、`LiteUI` | 5 | 300 | 移动与轻量界面变体 |

- `src/lang` 8 文件 / 10,685 行：`index.ts` 选择逻辑加上 7 个语言包（en、ko、cn、zh-Hant、vi、de、es），各包体量相当（约 100–125 KB）。
- `src` 顶层 7 文件 / 937 行（`main.ts` 入口、`App.svelte`、`LiteMain.svelte`、`preload.ts`、`styles.css` 及两个类型声明），`src/etc` 10 文件 / 25 行源码（`patchNote.ts` 补丁说明、`o200k_base.json` 词表、`.cbs` 应用内文档与少量图片音频）。

`server/node` 的主体是单文件 Express 服务器 `server.cjs`（约 1.5 千行），实现静态托管 `dist`、流式代理、限流与 OpenID 登录；`server/hono` 的 5 个源码文件合计仅约 40 行，是 node/bun/cf 三份入口存根加一个 Hono 应用骨架。`src-tauri` 的可识别源码只有 `src/main.rs`（615 行）与 `build.rs`，其余 50 张图标和 capabilities、gen/schemas 都是配置与资源。

## 2. 语言分布与运行时分工

| 语言 | 文件 | 行数 | 占比 | 分布与用途 |
| --- | ---: | ---: | ---: | --- |
| TypeScript | 213 | 82,706 | 65.5% | `src/ts` 业务逻辑与 `src/lang` 文案 |
| Svelte | 179 | 36,389 | 28.8% | `src/lib` UI 组件与 `App.svelte` 等入口 |
| JavaScript | 10 | 5,291 | 4.2% | 服务器、浏览器 worker、代理函数、用户脚本 |
| Rust | 2 | 618 | 0.5% | Tauri 命令层 |
| CSS | 1 | 547 | — | `src/styles.css` 全局主题样式 |
| Lua | 1 | 388 | — | `public/lua/json.lua`，vendored 库 |
| Python | 3 | 164 | — | `src-tauri/src-python` 本地 LLM 服务 + 根目录残留脚本 |
| Shell | 2 | 51 | — | `server.sh` 部署脚本与证书生成脚本 |

TypeScript 与 Svelte 合计占 94.3%，且全部是手写业务代码；语言占比未被生成代码影响，但被第三方资源扭曲的是字节量而非行数。JavaScript 的 10 个文件是运行时必需的杂项：`server.cjs`（Node 服务器）、`public/assets` 下的翻译 worker（主 worker 是约 2.6 千行的压缩产物）、`public/sw.js`（服务 worker）、`public/functions` 的 3 个 Cloudflare 代理函数、`util/risuUserscript.user.js`（浏览器用户脚本）与 2 个构建/辅助小文件。

运行时按平台分工：浏览器运行 Svelte 组件与 TypeScript 逻辑；Tauri 桌面由 Rust 层补齐原生能力（原生请求、流式事件、OAuth、Python 安装引导）；Node 运行 `server.cjs`；hono 骨架的目标运行时是 Node/Bun/Cloudflare Workers/Vercel；Python（FastAPI + llama_cpp）只在桌面端被 Rust 启动，端口 10026，提供本地推理与分词（`src-tauri/src-python/main.py`）。

## 3. 文档分布与数量

仓内文档共 13 文件 / 2,810 行，其中绝大部分在根目录：`README.md`（产品介绍，用户文档指向 GitHub Wiki）、`plugins.md`（插件开发指南，约 1.6 千行）、`AGENTS.md`（开发者约定）。`src/ts/plugins/migrationGuide.md`（758 行）是插件 API v2→v3 迁移指南，位于插件代码目录内部。`.github/pull_request_template.md` 37 行；`server/node/readme.md` 与 `server/hono/README.md` 各 5 行，分别声明了未来弃用与开发中状态。

其余文档命中来自统计口径而非真实文档意图：`public/token/glm4/SOURCE.md`、`glm5/SOURCE.md` 是 tokenizer 数据的来源说明，`public/colors.txt` 是颜色清单，`src-tauri` 下被计入的 `requirements.txt`、`key.txt`、`mainx.txt` 是配置或遗留文件。应用内帮助内容以 `.cbs` 自定义格式存放在 `src/etc/docs`（cbs_intro、cbs_docs、docs_text、regex 共 4 个文件，约 33 KB），不进入 Markdown 文档统计。用户手册主体在仓库外的 GitHub Wiki（README 标注 Work in Progress）。

## 4. 测试分布与数量

测试共 25 文件 / 4,147 测试源码行，测试/源码文件比约 6%。全部为 Vitest 单元测试（`vitest.config.ts` 使用 happy-dom 环境与 `vitest.setup.ts`，`package.json:16` 的 `test` 脚本为 `vitest run`），含 fast-check 属性测试；未发现 e2e、Playwright、Cypress 或集成测试目录。统计口径计入 1 个快照文件（`src/ts/process/mcp/risuaccess/tests/__snapshots__/modules.test.ts.snap`）与 1 个测试辅助文件（`parser/tests/cbs/lib.ts`）。

分布按测试文件数：

- `src/ts/parser` 7 个：CBS 语法的条件、转义、循环、字符串测试与 `chatML`、`chatVar` 各一。
- `src/ts/process` 8 个（含快照）：覆盖 `coldstorageData`、`files/inlays`、MCP risuaccess 模块、OpenAI responses 请求、`additionalParams`、`scriptings`、`ttsHooks`。
- 其余分散在 `network`（2）、`media`（2）、`translator`（2）与 `storage`（1），`src/ts` 顶层有 `chatLoadPages`、`sourcemap` 两个。
- `src/lib` 仅 1 个：`UI/GUI/guiRendering.test.ts`（308 行）。

`plugins`、`drive`、`sync`、`model`、`lang` 和全部 Rust 代码未识别到同目录或邻近测试文件。项目自己的开发文档（`AGENTS.md` 的 Testing 小节）称基础测试在 `src/test/runTest.ts`，但快照中不存在 `src/test` 目录，属于文档滞后于实现；实际测试入口以根 `vitest.config.ts` 为准。

## 5. 跨平台与发布组织

平台策略是单一 SPA 代码库加运行时探测：`src/ts/platform.ts` 通过 `__TAURI_INTERNALS__`、`__NODE__` 全局标记、hostname 与 user agent 区分本地桌面、Node 服务器、官网 Web 与移动浏览器，同一份 `src` 不经过条件编译即服务全部平台。平台专属差异放在三类外围目录：

- Web：`vite build` 产出 `dist` 供静态托管；public 下的服务 worker `sw.js` 与 `manifest.json` 支持 PWA 缓存；`public/functions` 三个代理函数按 Cloudflare Functions 约定提供 CORS 代理；`util/risuUserscript.user.js` 是给 Tampermonkey 的跨域请求脚本。
- 桌面：`src-tauri` 是完整 Tauri 2 工程，`main.rs:589-601` 注册的命令层提供原生网络请求、事件流式响应、OAuth 登录与 Python 环境安装；`tauri.conf.json` 声明 deb/rpm/appimage/nsis/app/dmg 六个打包目标、GitHub Releases 更新器与 `risuailocal` 深链。
- 移动：`capacitor.config.ts` 声明 appId 与 `webDir: dist`，但仓库未跟踪 android/ios 原生工程（构建时生成）；移动适配以 `src/lib/Mobile` 组件、`LiteUI` 变体与 `MobileGUI` 状态切换实现。

自托管服务与桌面并行：`server/node/server.cjs` 托管 `dist` 并提供代理与认证，`Dockerfile` + `docker-compose.yml` 以端口 6001 发布；`server/hono` 是面向多运行时（Node、Bun、Cloudflare、Vercel）的替代实现骨架。发布流水线在 `.github/workflows`：`github-actions-builder.yml` 对 production 分支矩阵构建四个平台的 Tauri 产物，`docker-build.yml` 推送 ghcr.io 镜像，`pr-check.yml` 对 main 的 PR 跑类型检查与测试，另有 `mod.yml`（AI 评论审查）与 `codeql.yml`。

## 6. 工程配套与结构特征

工程配套分布在根目录脚本与工作流中：`package.json:10-23` 提供 dev/build/tauribuild/buildsite/runserver/hono:build/check/test 等脚本；`server.bat` 与 `server.sh` 是面向自托管的一键脚本，带 `VITE_RISU_LITE`、`VITE_AD_CLIENT` 等构建期环境变量开关。`pnpm-lock.yaml` 在根目录与 `server/hono` 各一份，体现两个包的独立依赖树。

结构信号（均为本次快照内可观察的事实）：

- `package.json:20-21` 的 `sync`、`electron` 脚本指向仓库中不存在的 `electron/` 目录，是失效入口；AGENTS.md 目录图里列出的 `dist/` 与 `src/test/` 同样不在跟踪文件内。
- 第三方与生成物被跟踪：`public/token` 约 80 MB 的 tokenizer 模型（覆盖 claude、cohere、deepseek、gemma、glm4/5、llama、mistral、nai、trin 等厂商词表），另有 `public/lua/json.lua`、`src/ts/rpack`（js 解码器加二进制映射与三份许可证）、`src/etc/o200k_base.json` 词表、`public/assets` 的 wasm 翻译 worker，以及 `src-tauri/gen/schemas/capabilities.json` 等 Tauri 生成文件。
- 根目录残留开发痕迹：`t.py`（翻译演示脚本）、`src-tauri/key.txt`（含一个固定十六进制值）、`src-tauri/src/mainx.txt`（lib 风格 main 存根）、`.cargo/config.toml`。
- `.gitattributes` 为 `.gitignore` 设置 merge=ours，与文档化的 fork 维护方式呼应。

## 7. 设计取舍与已确认边界

- 平台共享程度高：桌面、Web、自托管共享同一份业务代码与存档格式（`decodeRisuSave`），平台差异收敛在 `platform.ts` 判定和 Rust 命令层，未形成第二套业务实现。
- 网络层多后端并存是刻意结构：Web 用 Cloudflare Functions 代理并可被用户脚本接管，Tauri 用 `native_request`/`streamed_fetch` 命令，Node 自托管用服务端代理；同一 fetch 抽象的三个后端。
- 本地推理走“Rust 下载并引导 Python 环境 + FastAPI/llama_cpp 进程”的复合方案，但 `main.rs:241-246` 只完整实现了 Windows 的嵌入式 Python 下载路径，macOS/Linux 分支存在而未闭环。
- `server/node` 与 `server/hono` 并存：前者可用但 readme 声明将被弃用，后者是未来替代骨架，目前 5 个源码文件均为入口存根。
- 移动端只保证到“配置 + UI 变体”层次：无原生工程、无移动构建 CI，Capacitor 配置是静态声明，未运行验证。
- 测试覆盖集中在解析器与请求层（最接近数据契约的代码），UI 层仅 1 个渲染测试，未识别到 e2e；这与“无综合测试套件、依赖类型检查”的开发者文档自述一致，但注意该文档同时描述了不存在的 `src/test/runTest.ts`。

## 8. 未验证事项

- 未运行 `pnpm build`、`pnpm test`、Tauri 与 Docker 构建，跨平台、打包与 CI 相关结论均为静态确认。
- `public/functions` 的部署形态（是否为 Cloudflare Pages/Workers 实际配置）依据目录约定推断，未在配置文件中找到引用。
- `main.rs` 的 `oauth_login` 命令使用写死的占位授权端点，且未确认前端调用路径，功能可用性未验证。
- `src-tauri/key.txt` 的固定值用途不明，未运行无法确认是测试遗留还是运行期依赖。
- 本地推理服务（Python + llama_cpp）仅能确认入口存在，模型加载与流式行为未运行验证。
- 未检查未跟踪文件（dist、node_modules），统计仅覆盖跟踪文件口径。

## 9. 关键源码索引

- 主链路入口：`src/main.ts`、`src/ts/bootstrap.ts:55`（`loadData`）
- 业务编排：`src/ts/process/index.svelte.ts`、`src/ts/stores.svelte.ts`（DBState）
- 平台探测：`src/ts/platform.ts:19-22`
- 桌面命令层：`src-tauri/src/main.rs:589-601`（invoke_handler 注册）、`src-tauri/src-python/main.py`（本地 LLM）
- 自托管：`server/node/server.cjs`、`server/hono/src/app/index.ts`（骨架）
- 构建与测试配置：`package.json:10-23`、`vite.config.ts`、`vitest.config.ts`、`capacitor.config.ts`、`tauri.conf.json`
- 发布工作流：`.github/workflows/github-actions-builder.yml`、`docker-build.yml`、`pr-check.yml`
- Web 外围：`public/sw.js`、`public/functions/proxy.js`、`util/risuUserscript.user.js`
- 文档：`plugins.md`、`src/ts/plugins/migrationGuide.md`
