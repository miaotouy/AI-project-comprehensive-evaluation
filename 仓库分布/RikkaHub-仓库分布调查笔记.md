# RikkaHub 仓库分布调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`903e058b9361bff71d0b79f4ef2d8ac23d6597e6`（分支：`master`）
>
> 调查方式：读取 Git 索引快照、Gradle 构建脚本与版本目录、`settings.gradle.kts`、`.github/workflows`、各子项目清单与 README/AGENTS 文档，并对照 `统计仓库.ps1` 的机械统计复核文件与行数量级；未运行任何构建或测试
>
> 调查范围：仓库形态、模块与语言分布、文档与测试分布、Android/Web/工具链组织、CI 与资源资产；不覆盖运行期行为、性能与 UI 视觉
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 是面向 Android 的原生 LLM 聊天客户端，采用单个 Gradle 多模块工程组织核心代码，另有三个不进入 Gradle 的工具/前端子工程：React Router 7 前端 `web-ui`、Bun/TypeScript 的本地化工具 `tools/i18n` 与 SSE 轨迹录制工具 `tools/trace`，外加 `tools/models-dev` 数据更新脚本。当前快照含 1536 个 Git 跟踪文件、1095 个可识别源码文件 / 206,401 行源码，Kotlin 占文件数约 84%、行数约 83%。

模块边界是「按能力域切模块，按界面与集成留在 app」：能力域模块覆盖 AI Provider 抽象与 agent 循环、搜索、语音、文档解析、媒体生成、OAuth、proot 沙箱、终端模拟与公共 Compose 组件；`app` 承载 UI、数据层、服务与嵌入式 Web 服务端，占全仓源码行约 55%。仓库同时跟踪了预编译原生库、技能文档与基线画像文本，这些资产显著影响仓库体积但不计入业务源码。

## 统计口径与仓库形态

统计只覆盖当前 commit 的 Git 跟踪文件，不含本地构建产物。`web/src/main/resources/static/` 是 `web-ui` 的构建输出目录，被该目录下的 `.gitignore` 排除，因此前端产物不计入仓库统计。

仓库形态是**单 Gradle 多模块工程 + 三个独立工具/前端子工程**：

| 构建编排 | 位置 | 成员 |
| --- | --- | --- |
| Gradle（`settings.gradle.kts`） | 仓库根 | `app`、`app:baselineprofile`、`ai`、`search`、`speech`、`common`、`document`、`web`、`material3`、`ui`、`workspace`、`terminal`、`mediagen`、`oauth` |
| Gradle 复合构建 | `build-logic/` | 通过 `includeBuild("build-logic")` 注入约定插件，非业务模块 |
| pnpm（`web-ui/pnpm-workspace.yaml`） | `web-ui/` | React Router 7 前端，由 `web` 模块的 Gradle 任务调用构建 |
| Bun（`tools/i18n/package.json`） | `tools/i18n/` | TypeScript 本地化 CLI（Vercel AI SDK 调用翻译模型） |
| Bun（`tools/trace/package.json`） | `tools/trace/` | TypeScript SSE 轨迹录制 CLI |
| Bun 脚本 | `tools/models-dev/update.ts` | 生成 `app/src/main/assets/models_dev.json` 的模型能力数据 |

三个 `tools/` 子工程都不出现在任何 `include(...)` 中，属于与主工程并列的独立清单。仓库根仍保留 `package.json` 与 `bun.lock`，供 `.agents/` 技能脚本使用。

## 1. 模块分布与量级

一级目录文件数与源码行数（行数含空行与注释，仅作量级比较）：

| 目录 | 文件 | 源码行 | 角色 |
| --- | ---: | ---: | --- |
| `app` | 713 | 112,530 | Android 应用主体：UI、数据层、服务、内嵌 Web 服务集成 |
| `ai` | 111 | 19,910 | AI Provider 抽象、流式解码与通用 agent 循环 |
| `web-ui` | 141 | 16,438 | React Router 7 前端，构建产物由 `web` 模块嵌入 |
| `material3` | 51 | 10,173 | vendored material-color-utilities 源码 + 少量 Kotlin 扩展 |
| `terminal` | 42 | 8,417 | Termux 派生的终端模拟器与本地 PTY |
| `ui` | 56 | 6,896 | 公共 Compose 组件库（图表、裁剪、富文本、表格、Toast、WebView 等） |
| `speech` | 50 | 5,430 | TTS 与 ASR Provider |
| `document` | 47 | 5,097 | PDF/DOCX/PPTX/EPUB 解析（纯 Kotlin PDF 文本提取） |
| `search` | 37 | 4,311 | 搜索 Provider 集合（21 个 Provider 服务文件） |
| `workspace` | 29 | 4,159 | 基于 proot 的沙箱文件系统与 Shell |
| `mediagen` | 35 | 3,798 | 图像/视频生成 Provider |
| `.agents` | 96 | 3,665 | AI 编码代理技能与说明文档（不计入源码口径时另算） |
| `tools` | 34 | 2,032 | i18n、trace、models-dev 三套工具 |
| `common` | 23 | 1,882 | HTTP/SSE/缓存等公共工具 |
| `oauth` | 18 | 1,324 | OAuth 授权、回调前台服务与回环回调服务器 |
| `web` | 7 | 151 | Ktor 服务端启动与静态资源承载 |
| `build-logic` | 5 | 93 | Gradle 约定插件 |

`app` 内部按包分层，其分布进一步说明「主体集中在 UI 模块内」：

| `app` 包 | Kotlin 文件 | 角色 |
| --- | ---: | --- |
| `ui` | 249 | 页面、消息组件、输入区、富文本与设置页 |
| `data` | 163 | 数据层：AI 请求、工具、MCP、数据库、仓库、同步 |
| `service` | 12 | 会话服务、前台服务、悬浮窗、媒体生成服务 |
| `web` | 14 | 内嵌 Web 服务路由与 mDNS 注册 |
| `utils` | 21 | 通用工具 |
| `di` | 4 | Koin 模块 |

共享层是 `common` 与 `material3`：前者被 `ai` 等模块直接依赖，后者包含 vendored 的 material-color-utilities 源码（45 文件 / 10,000 行），原先的 git 子模块登记已移除，`.gitmodules` 不再存在。

## 2. 语言分布与运行时分工

| 语言 | 文件 | 行数 | 主要承载 |
| --- | ---: | ---: | --- |
| Kotlin | 916 | 171,954 | 全部 Gradle 模块（应用、库、JVM 单元测试） |
| TypeScript | 134 | 17,437 | `web-ui`、`tools/i18n`、`tools/trace` |
| Java | 35 | 8,238 | 全部位于 `terminal`，为 Termux 终端模拟器代码 |
| JavaScript | 3 | 4,677 | `app` assets 内 vendored 的 `mermaid.min.js` 与技能脚本 |
| Python | 2 | 2,575 | `.agents` 技能内的迁移/对比脚本 |
| CSS | 2 | 1,033 | `web-ui` 的 `app.css` 与 `markdown.css` |
| HTML | 1 | 314 | `app` assets 的 `mark.html` |
| C++ | 2 | 173 | `workspace` 与 `terminal` 的 PTY 原生代码 |

语言占比受 vendor 代码影响：

- Java 的 35 个文件全部位于 `terminal/src/main/java/com/termux/terminal/`，是 Termux 终端模拟器代码；`document` 已不再包含 Java，PDF 解析改为纯 Kotlin 实现（`document/src/main/java/me/rerere/document/pdf/` 17 个文件 + 4 个解析器）。
- JavaScript 的 4,677 行主要由压缩后的 `mermaid.min.js` 贡献；Python 行数来自 `.agents/skills` 内的工具脚本，不再有独立的 Python 本地化工具。
- Kotlin 贯穿全部 Gradle 模块；`web` 模块只含 1 个 Kotlin 入口文件，但通过 Ktor 承担服务端运行时。

运行时分工上，Android 侧统一为 Kotlin/JVM，个别能力下沉到 JNI：`workspace` 通过 `src/main/cpp/CMakeLists.txt` 构建 proot PTY 原生代码，`terminal` 自带 `termux_pty.cpp`；`app/src/main/jniLibs` 仅保留 `libsimple.so`（分词用的 SQLite simple 扩展，已去掉 jieba 词典），`document` 的 `libmupdf_java.so` 随 MuPDF 一起移除。

## 3. 文档分布与数量

文档统计共 116 个文件，但其中相当比例并非说明性文档：

| 位置 | 文件 | 性质 |
| --- | ---: | --- |
| `.agents/skills` | 92 | 供 AI 编码代理使用的技能说明（含 evals 与脚本） |
| `app` | 4 | 2 个基线画像 `.txt`（合计约 12MB）+ 2 个说明文件 |
| `document` | 3 | 解析器相关 `.md`/`.txt` |
| `web-ui` | 3 | `AGENTS.md`、`CLAUDE.md`、`README.md` |
| `(root)` | 4 | 三语 README、`AGENTS.md` |
| `ai` | 2 | `README.md` 与夹具说明 |
| `docs` | 1 | `references/chat-generation-pipeline.md`（约 236 行） |
| 其余 | ~9 | `mediagen`、`tools`、`workspace`、`terminal`、`material3` 各处 README |

文档行数统计（153,555 行）被 `app/src/main/generated/baselineProfiles` 的两个 `.txt`（各约 6MB、10,001 行级别）主导，不能当作说明文档量。真正面向人的架构说明仍只有 `docs/references/chat-generation-pipeline.md` 一篇，本次内容随生成链重构同步扩写。

开发协作文档有两条线索：根 `AGENTS.md` 给出构建命令与模块职责表，并解释 Assistant、Conversation、UIMessage、MessageNode、Message Transformer 等领域概念；`.agents/skills/` 与 `skills-lock.json` 记录外部同步的技能包（`claude-api`、`find-hugeicons`、`gemini-api-dev`、`i18n-localization`、`jetpack-compose-performance`、`publish-release`），文件数占文档统计的四分之三以上。`web-ui/CLAUDE.md` 仍是该子工程最详细的一处约定说明。

## 4. 测试分布与数量

Git 跟踪的测试文件共 211 个 / 25,902 源码行，测试与源码的文件比约 19%，行数比约 12.6%。按一级目录分布：

| 模块 | 测试文件 | 主要形式 |
| --- | ---: | --- |
| `app` | 71 | 业务单元测试（服务、会话、Transformer、同步、工具） |
| `ai` | 58 | 单元测试 + `stream-traces` 流式回放夹具 |
| `terminal` | 20 | 终端模拟器缓冲、控制序列与 PTY 测试 |
| `document` | 18 | PDF 解析边界用例 |
| `speech` | 12 | ASR/TTS Provider 与设置解析测试 |
| `mediagen` | 8 | 媒体生成 Provider 请求与解析 |
| `workspace` | 5 | rootfs 安装与路径解析 |
| `search` | 4 | Provider 请求构造 |
| `tools` | 7 | i18n 校验与 trace 录制测试 |
| `oauth` | 2 | 回调与授权流程 |
| 其余 | 14 | `common`、`ui`、`web`、`material3` 各 1–2 个 |

与上一快照相比，测试重心从 `highlight` 的语法高亮夹具转向 `terminal`、`document`、`mediagen` 等新模块；`highlight` 模块整体移除后，原先 43 组 hljs 夹具与 92 个测试文件不再存在。`ai` 的 `src/test/resources/stream-traces/generated/` 仍按 Provider 分组保存 `events.jsonl` 与 `expected.json`，由 `StreamTraceReplayTest` 离线回放，不访问网络。

夹具再生成链路仍由 `tools/trace` 承担（上一快照位于 `trace-cli`），`ai` 夹具目录的 README 说明用 `UPDATE_STREAM_TRACE_SNAPSHOTS=true` 重新生成快照。本次未在仓库中找到 `e2e`、`playwright`、`cypress` 目录或对应依赖，`web-ui` 侧仍未找到测试文件或测试脚本。

## 5. 跨平台与发布组织

产品主平台是 Android。平台判定依据来自构建配置而非 README 声明：`app/build.gradle.kts` 使用 `android.application` 插件，`compileSdk` 以 `release(37)` 指定、`minSdk = 26`、`targetSdk = 37`，`abiFilters` 为 `arm64-v8a` 与 `x86_64`，并启用 ABI 拆分；release 签名从 `local.properties` 读取，debug 变体通过 `applicationIdSuffix = ".debug"` 区分。库模块统一经 `build-logic` 的 `rikkahub.android.library` / `rikkahub.android.library.compose` 约定插件接入，`web` 模块以 24 为 `minSdk` 低于应用。

发布维度新增渠道 flavor：`flavorDimensions += "distribution"`，`github` 与 `play` 共用同一 `applicationId`，Play 版通过 `BuildConfig.IS_PLAY_STORE` 关闭自更新、更新卡片与更新提醒设置。基线画像目录从 `app/src/release/generated` 合并到 `app/src/main/generated`，两个渠道共用；`app:baselineprofile` 子模块在生成时只跑 `github` 渠道。

其他平台以「同一份 Android 代码 + 旁路工程」的方式组织：

| 端 | 组织方式 |
| --- | --- |
| Web 端 | 独立 `web-ui` React 应用，经 `web` 模块 Ktor 服务端承载；app 内 `web` 包提供路由与 mDNS 注册 |
| 基准性能 | `app:baselineprofile` 子模块，含 `BaselineProfileGenerator` 与 `StartupBenchmarks` |
| 本地化工具链 | `tools/i18n` 直接读写 Android 字符串资源 XML，独立 Bun 运行时 |
| 契约测试工具链 | `tools/trace` 独立 Bun 运行时，产出喂给 `ai` 模块测试 |
| 远程终端 | `terminal` 模块提供终端模拟与 PTY，配合工作区的远程 SSH 模式 |

Web 端通过协议复用接入：`web` 模块承担 Ktor 服务端（`ktor.server.cio`、auth、SSE、compression、CORS、status pages），app 内 `web` 包实现 `WebServerManager`、`WebApiModule`、`NsdServiceRegistrar` 与按域拆分的路由，`web-ui` 通过 `api.ts`/`events.ts` 消费 HTTP/SSE 接口。

前端到 Android 的嵌入由 `web/build.gradle.kts` 的 `buildWebUi` Exec 任务完成：在 `web-ui` 目录执行 `pnpm run build`，输出到 `web/src/main/resources/static/`，并通过 `preBuild.dependsOn(buildWebUi)` 挂入 Android 构建；该任务只跑 `build` 不跑 `install`，因此 CI 中需要预先安装前端依赖。

发布通道仍是一条自动化工作流：`.github/workflows/daily-build.yml` 定时触发，要求 JDK 17、pnpm、Node，并递归拉取子模块（子模块现已不存在）；签名与集成配置来自 Secrets，随后用带渠道的 Gradle 任务构建并上传 mapping txt，最后把 APK 发布到固定 tag 的 prerelease。仓库另有 `close-blank-issues.yml` 与 3 个 issue 模板。

## 6. 工程配套与结构特征

Gradle 侧使用版本目录与工具链配置：`gradle/libs.versions.toml` 集中声明 AGP 9.4.0、Kotlin 2.4.21、Compose BOM 2026.09.00、Ktor 3.5.2、Room 2.8.5 等版本；wrapper 为 Gradle 9.6.0；`gradle.properties` 开启 configuration cache 与并行构建。`app` 通过 KSP 生成 Room 代码并把 `room.schemaLocation` 指向 `app/schemas`，32 个版本化 JSON 进入仓库。

工程中跟踪了若干体积显著的资源与生成文件，它们不进入源码行统计，但明显影响仓库尺寸：

| 资产 | 位置 | 量级 |
| --- | --- | --- |
| 基线画像文本 | `app/src/main/generated/baselineProfiles` | `baseline-prof.txt` 与 `startup-prof.txt` 各约 6MB |
| 内置技能 | `app/src/main/assets/builtin_skills` | 随包分发的 skill 定义 |
| Mermaid 与 `mark.html` | `app/src/main/assets/html` | 2 文件 / 约 3.4MB |
| 模型能力数据 | `app/src/main/assets/models_dev.json` | 由 `tools/models-dev` 生成 |
| Emoji / 图标 | `app/src/main/assets/emoji`、`icons` | 数十个文件 |
| `libsimple.so` | `app/src/main/jniLibs/{arm64-v8a,x86_64}` | 已去掉 jieba 的 SQLite simple 扩展 |
| proot 原生库 | `workspace/src/main/jniLibs` | 4 文件 |
| Google Sans Flex 字体 | `app/src/main/res/font` | 4.06MB |
| MuPDF 绑定 | 已删除 | 随纯 Kotlin PDF 提取替换移除 |

上一快照中的 Jieba 词典（约 13.7MB）、banner 图（约 5MB）与 `libmupdf_java.so`（约 18MB）都已从仓库移除，`simple_dict` 目录不再存在。APK 体积压缩是这一阶段的持续主题：构建记录显示 arm64 安装包从约 43.9MB 经若干轮裁剪降到约 16.1MB，手段包括移除 jieba、换 BetterText/CameraX/Compose 裁剪、resources.arsc 只保留已翻译语言、Web 端去 Ktor JWT/Jackson、代码高亮由 shiki 换 highlight.js 等。

可观察的结构信号包括：

- **`app` 体型占比高但有所下降**。`app` 占全仓源码行约 55%（上一快照约 58.6%），其中 `ui` 包仍最大；单文件规模上限较高（设置页、提示词页、Provider 详情页均为数千行级）。目录依赖方向保持单向：`ai`、`search`、`speech` 等能力模块不反向依赖 `app`。
- **模块边界在收敛旧形态**：`highlight` 与 `videogen` 两个「单一能力一个模块」被移除（高亮交给 BetterText 库，视频生成并入 `mediagen`），同时新增更通用的 `ui`（公共 Compose 组件）与 `terminal`（终端模拟）模块。`search` 仍是平行 Provider 目录，21 个服务实现各自成文件。
- **旁路工具从多语言 TUI 转向统一 Bun/TS 工具链**：Python 版 `locale-tui` 被重写为 `tools/i18n`，`trace-cli` 改名为 `tools/trace`，`tools/models-dev` 用脚本生成随包模型能力数据。
- **命名边界仍有两套写法**：主工程用 `me.rerere.*`，`terminal` 原样保留 `com.termux.terminal` 包名与 Apache/相关许可，`web` 使用 `me.rerere.rikkahub.web`。

## 7. 设计取舍与已确认边界

- 核心代码用一个 Gradle 工程承载，能力域模块只依赖 `common` 与 Android/Compose 基础库；`app` 聚合全部业务模块，形成单入口应用。这一结构在 `app/build.gradle.kts` 的 `project(":...")` 依赖列表与各库模块 `build.gradle.kts` 中可直接读出。
- 开发工具链没有被抽象进 Gradle：`tools/i18n`、`tools/trace` 各自维护独立清单与锁文件，与 Android 构建解耦，代价是需要各自的 Bun 运行时。`web-ui` 虽然独立维护 `package.json` 与 `pnpm-lock.yaml`，但被 `web` 模块以进程调用方式纳入 Android 构建。
- 测试策略偏向「离线夹具回放」：`ai` 的流式解码以仓库内快照为期望值，`terminal`、`document` 以纯 JVM 单测覆盖解析与缓冲边界，网络与渲染不在单元测试范围内。
- 子模块被移除后，仓库不再依赖 `git submodule` 拉取资源，`material3` 与 `web-ui` 都以源码/清单形式内置，CI 不再需要递归拉取子模块。
- 文档数量（116）由 92 个代理技能文件与 2 个基线画像文本占主要部分；面向人的架构说明目前只有 `docs/references/chat-generation-pipeline.md` 一篇。

## 8. 未验证事项

- 未运行 `./gradlew assembleDebug`、`test`、`lint` 或任何前端/CLI 构建与测试，模块行数、依赖可解析性与测试通过情况均为静态读取结果。
- 提交历史经机械统计为 2969 个主线提交（2025-03-11 至 2026-11-02，601 天，折算 148.2 次/30 天，最近 90 天 408 次）；本次未再次逐项复核合并提交口径。
- `tools/models-dev` 的生成时机、`app/src/main/assets/models_dev.json` 与生产代码的版本对应关系未逐项核对。
- `terminal` 模块的 Termux 派生代码改动范围与上游许可处理未逐行核对；远程 SSH 工作区的连接、密钥与失败语义属于运行期能力，未验证。
- 未运行任何 Android 构建，ABI 覆盖、渠道 flavor 产物差异、基线与启动性能效果未在设备上验证；文中 APK 体积变化来自提交说明，未自行测量。
- 前端静态产物由 CI 的 `pnpm run build` 生成，本地 `web/src/main/resources/static/` 不存在；未验证嵌入后的实际加载路径。

## 9. 关键源码索引

- `settings.gradle.kts`：Gradle 模块清单与 `includeBuild("build-logic")`
- `gradle/libs.versions.toml`、`gradle/wrapper/gradle-wrapper.properties`、`gradle.properties`：依赖版本与构建开关
- `build-logic/src/main/kotlin/`：`AndroidLibraryConventionPlugin`、`AndroidLibraryComposeConventionPlugin` 约定插件
- `app/build.gradle.kts`：应用 SDK/ABI/签名/拆分配置、渠道 flavor、`app` 对全部能力模块的依赖、Room schema 输出
- `.github/workflows/daily-build.yml`：发布流水线（带渠道任务与 mapping 上传）
- `web/build.gradle.kts`：`buildWebUi` 任务与 `preBuild` 挂载，前端产物嵌入路径
- `web/src/main/java/me/rerere/rikkahub/web/Entry.kt`：Ktor 服务端入口
- `app/src/main/java/me/rerere/rikkahub/web/`：`WebServerManager`、`WebApiModule`、`NsdServiceRegistrar` 与 `routes/`
- `app/src/main/java/me/rerere/rikkahub/ui/`、`app/src/main/java/me/rerere/rikkahub/data/`：UI 与数据层主体
- `terminal/src/main/java/com/termux/terminal/`：终端模拟器与 PTY
- `ui/src/main/java/me/rerere/ui/`：公共 Compose 组件（charts、crop、richtext、toast、webview 等）
- `mediagen/src/main/java/me/rerere/mediagen/`：媒体生成 Provider 与管理器
- `ai/src/test/resources/stream-traces/README.md`、`tools/trace/README.md`：夹具生成与回放链路
- `tools/i18n/src/cli.ts`、`tools/models-dev/update.ts`：工具链入口
- `workspace/src/main/cpp/CMakeLists.txt`、`workspace/src/main/jniLibs/`：沙箱原生部分
