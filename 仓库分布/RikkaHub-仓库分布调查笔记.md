# RikkaHub 仓库分布调查笔记

> 调查对象：`https://github.com/rikkahub/rikkahub`
>
> 调查更新日期：2026-09-15
>
> 代码快照：`8e304bb1cc641e4ea772869ab9fb8c5b9b71cffb`（分支：`master`）
>
> 调查方式：读取 Git 索引快照、Gradle 构建脚本与版本目录、`settings.gradle.kts`、`.gitmodules`、`.github/workflows`、各子项目清单与 README/AGENTS 文档，并对照 `统计仓库.ps1` 的机械统计复核文件与行数量级；未运行任何构建或测试
>
> 调查范围：仓库形态、模块与语言分布、文档与测试分布、Android/Web/CLI 平台组织、CI 与工程配套、大资源与生成文件；不覆盖运行期行为、性能与 UI 视觉
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

RikkaHub 是一个面向 Android 的原生 LLM 聊天客户端，采用单个 Gradle 多模块工程组织核心代码，另有三个不进入 Gradle 的旁路子项目：React Router 前端 `web-ui`、Python/Textual 的本地化工具 `locale-tui`、Bun/TypeScript 的 SSE 轨迹录制工具 `trace-cli`。当前快照含 1380 个 Git 跟踪文件、906 个可识别源码文件 / 160600 行源码，其中 Kotlin 占文件数约 77%、行数约 82%。

模块边界的划分方式是「按能力域切模块，按界面与集成留在 app」：能力域模块包括 AI Provider 抽象、搜索、语音、文档解析、代码高亮、视频生成、OAuth、沙箱工作区；`app` 承载 UI、数据层、服务与嵌入式 Web 服务端，自身即占全仓源码行数的约 58.6%。仓库还跟踪了体积可观的预编译原生库、词典资源与基线画像文本，这些资产显著影响仓库体积但不计入源码行。

## 统计口径与仓库形态

统计只覆盖当前 commit 的 Git 跟踪文件，不含本地构建产物。`web/src/main/resources/static/` 是 `web-ui` 的构建输出目录，被该目录下的 `.gitignore` 排除，因此前端产物不计入仓库统计。

仓库形态是**单 Gradle 多模块工程 + 三个独立工具/前端子工程**：

| 构建编排 | 位置 | 成员 |
| --- | --- | --- |
| Gradle（`settings.gradle.kts`） | 仓库根 | `app`、`app:baselineprofile`、`highlight`、`ai`、`search`、`speech`、`common`、`document`、`web`、`material3`、`workspace`、`videogen`、`oauth` |
| Gradle 复合构建 | `build-logic/` | 通过 `includeBuild("build-logic")` 注入约定插件，非业务模块 |
| pnpm（`web-ui/pnpm-workspace.yaml`） | `web-ui/` | React Router 7 前端，由 `web` 模块的 Gradle 任务调用构建 |
| uv（`locale-tui/pyproject.toml`、`uv.lock`） | `locale-tui/` | Python 3.12+ 的 Textual TUI 工具 |
| Bun（`trace-cli/bun.lock`） | `trace-cli/` | TypeScript CLI，用于录制 SSE 轨迹 |

`locale-tui` 与 `trace-cli` 未出现在任何 `include(...)` 中，属于与主工程并列的独立清单；两者的存在可由构建文件和各自的 README 直接确认。仓库根还有一个几乎为空的 `package.json`（唯一依赖是 `@types/ink`）与一份 `bun.lock`，本次未找到该根清单被主构建引用的入口。

## 1. 模块分布与量级

一级目录文件数与源码行数（行数含空行与注释，仅作量级比较）：

| 目录 | 文件 | 源码行 | 角色 |
| --- | ---: | ---: | --- |
| `app` | 605 | 94047 | Android 应用主体：UI、数据层、服务、内嵌 Web 服务集成 |
| `web-ui` | 140 | 16369 | React Router 7 前端，构建产物由 `web` 模块嵌入 |
| `ai` | 88 | 14854 | AI Provider 抽象与流式解码 |
| `highlight` | 143 | 10059 | 代码语法高亮引擎与语言定义 |
| `document` | 76 | 7671 | PDF/DOCX/PPTX/EPUB 解析（含 vendored MuPDF Java 绑定） |
| `speech` | 50 | 5430 | TTS 与 ASR Provider |
| `search` | 33 | 3937 | 搜索 Provider 集合 |
| `workspace` | 21 | 2126 | 基于 proot 的沙箱文件系统与 Shell |
| `locale-tui` | 24 | 1489 | Android 字符串资源管理与翻译工具（Python） |
| `common` | 20 | 1367 | HTTP/SSE/缓存等公共工具 |
| `videogen` | 15 | 1020 | 视频生成 Provider |
| `oauth` | 16 | 991 | OAuth 授权、回调前台服务与回环回调服务器 |
| `trace-cli` | 16 | 759 | SSE 轨迹录制 CLI（TypeScript） |
| `material3` | 6 | 173 | 动态配色的少量 Kotlin 扩展，另有 git 子模块 |
| `web` | 7 | 154 | Ktor 服务端启动与静态资源承载 |
| `build-logic` | 5 | 93 | Gradle 约定插件 |

`app` 内部继续按包分层，其分布进一步说明「主体集中在 UI 模块内」：

| `app` 包 | Kotlin 文件 | 行数 |
| --- | ---: | ---: |
| `ui` | 234 | 58564 |
| `data` | 123 | 13441 |
| `service` | 6 | 2000 |
| `web` | 13 | 1912 |
| `utils` | 22 | 1783 |
| `di` | 4 | 470 |

`ui` 之下 `pages` 99 个文件、`components` 96 个文件，`data` 之下以 `ai`（44）与 `db`（31）为主。`app/src/main/res/values*/strings.xml` 有 6 个语言变体，单个文件约 107–146KB，`app` 的资源目录同时承载字体与图片。

共享层是 `common` 与 `material3`：前者被 `ai` 等模块直接依赖（见 `ai/build.gradle.kts` 中的 `implementation(project(":common"))`），后者是唯一的 git 子模块宿主（`.gitmodules` → `material3/material-color-utilities`，指向 material-foundation 上游）。子模块在 Git 索引中仅以 gitlink 记录，因此不计入 `material3` 的 6 个文件；本次未展开该子模块内容。

## 2. 语言分布与运行时分工

| 语言 | 文件 | 行数 | 主要承载 |
| --- | ---: | ---: | --- |
| Kotlin | 696 | 131203 | 全部 Gradle 模块（Android 应用、库、JVM 单元测试） |
| TypeScript | 122 | 16207 | `web-ui`（`.ts`/`.tsx`）与 `trace-cli` |
| Java | 64 | 6557 | 几乎全部是 `document` 内 vendored 的 MuPDF 绑定 |
| JavaScript | 3 | 3736 | `app` assets 内 vendored 的 `mermaid.min.js` 与 `highlight/tools` 的 2 个 `.mjs` |
| Python | 16 | 1489 | `locale-tui` |
| CSS | 2 | 921 | `web-ui` 的 `app.css` 与 `markdown.css` |
| HTML | 1 | 314 | `app` assets 的 `mark.html` |
| C++ | 2 | 173 | `workspace` 的 `termux_pty.cpp`、`workspace.cpp` |

语言占比受 vendor 代码影响：

- Java 的 64 个文件全部位于 `document/src/main/java/com/artifex/mupdf/fitz/`，是第三方 PDF 库绑定；`document` 自身的业务代码只有 4 个 Kotlin 解析器（`DocxParser`、`EpubParser`、`PdfParser`、`PptxParser`）。
- JavaScript 的 3736 行主要由压缩后的 `mermaid.min.js` 贡献，业务 JS 只有 `highlight/tools` 下 2 个约 3.7KB/2.3KB 的 fixture 生成脚本。
- Kotlin 是唯一贯穿全部 Gradle 模块的语言；`web` 模块虽只含 1 个 Kotlin 文件（`Entry.kt`）与 154 行，但通过 Ktor 承担服务端运行时，其能力依赖版本目录中成组的 `ktor.server.*` 依赖。

运行时分工上，Android 侧统一为 Kotlin/JVM，个别能力下沉到 JNI：`workspace` 通过 `src/main/cpp/CMakeLists.txt` 构建 PTY 相关原生代码，其余模块直接携带预编译 `.so`。`ai` 模块的 README 描述了 MNN 子模块与 `src/main/cpp` 的 CMake 构建流程，但本快照中该目录不存在，`ai/build.gradle.kts` 里的 `externalNativeBuild` 与 `cmake` 配置均被注释，且 `.gitmodules` 未登记 MNN。文档与实现在此处不一致，以当前可执行构建路径为准：`ai` 实际不参与原生构建。

## 3. 文档分布与数量

文档统计共 134 个文件（按 `.md`、`.txt` 等扩展名归类），但其中相当比例并非说明性文档：

| 位置 | 文件 | 性质 |
| --- | ---: | --- |
| `.agents/skills` | 72 | 供 AI 编码代理使用的技能说明（多语言 API 参考副本） |
| `highlight/src/test/resources/hljs` | 43 | 语法高亮 `.txt` 测试夹具，非文档 |
| `app` | 3 | 1 个 `.md` 与 2 个 `.txt` |
| `web-ui` | 3 | `AGENTS.md`、`CLAUDE.md`、`README.md` |
| `docs` | 1 | `references/chat-generation-pipeline.md` |
| 其余 | ~12 | 根 `README` 三语版本、`CONTRIBUTING.md`、`AGENTS.md`、各模块 README、`locale-tui`/`trace-cli` 文档 |

用户文档面主要在仓库根：`README.md`、`README_ZH_CN.md`、`README_ZH_TW.md` 三语并列，`CONTRIBUTING.md` 指向 Android Studio 与贡献流程。架构性说明较少，`docs/` 下仅 1 篇 Markdown（`chat-generation-pipeline.md`，约 11KB），其余 12 个文件是图标、截图与赞助商图片。

开发协作文档有两条独立线索：根 `AGENTS.md` 给出构建命令与模块职责表，并用条目解释 Assistant、Conversation、UIMessage、MessageNode、Message Transformer 等领域概念；`.agents/skills/` 与 `skills-lock.json` 记录了从外部 GitHub 仓库同步的技能包（`claude-api`、`gemini-api-dev`、`gemini-interactions-api`、`material-3-expressive`），文件数占文档统计的一半以上。`web-ui/CLAUDE.md` 单文件约 20.5KB，是该子工程最详细的一处约定说明。

## 4. 测试分布与数量

Git 跟踪的测试文件共 193 个 / 12326 源码行，测试与源码的文件比约 21%，行数比约 7.7%。按一级目录分布：

| 模块 | 测试文件 | 主要形式 |
| --- | ---: | --- |
| `highlight` | 92 | 单元测试 + 43 组 `sample/edge` 高亮夹具（`.txt` + `.tokens`） |
| `ai` | 46 | 单元测试 + `stream-traces` 流式回放夹具 |
| `app` | 26 | 业务单元测试（服务、Transformer、同步、工具） |
| `speech` | 12 | ASR/TTS Provider 与设置解析测试 |
| `workspace` | 4 | rootfs 安装与路径解析 |
| `search` | 4 | Provider 请求构造 |
| `trace-cli` | 3 | Bun 测试 |
| 其余 | ~6 | `web`、`videogen`、`material3`、`common`、`oauth`、`document`、`locale-tui` 各 1–2 个 |

直接扫描目录时，把 `androidTest` 一并计入会得到 `app` 31、`speech` 13 等略高的数字；上表沿用 `统计仓库.ps1` 的口径，差异来自是否把 `ExampleInstrumentedTest.kt` 这类模板化仪器测试计入。

测试资产的分布比测试文件数更能说明覆盖重点。`highlight` 的 `src/test/resources/hljs/<language>/` 为 20 余种语言各存一对样例与期望 token 序列，由 `LanguageFixtureTest`、`HljsFixtures` 驱动，`highlight/tools` 内还保留了独立的 `.mjs` 夹具生成脚本与 `package.json`。`ai` 的 `src/test/resources/stream-traces/generated/` 按 Provider 分为 `claude`、`google-generateContent`、`openai-chat`、`openai-responses` 四组，每组含 `events.jsonl` 与 `expected.json`，由 `StreamTraceReplayTest` 离线回放，不访问网络。

这两组夹具都依赖仓库内的专用工具生成，构成一条可确认的研发链路：`trace-cli/README.md` 说明该 CLI 用真实 Provider 的 SSE 响应生成 `ai` 模块可回放的 `events.jsonl`，`ai` 夹具目录的 `README.md` 说明快照再生成命令为 `UPDATE_STREAM_TRACE_SNAPSHOTS=true ../gradlew testDebugUnitTest --tests me.rerere.ai.provider.stream.StreamTraceReplayTest`。两端文档互相引用，可视为实现事实。`locale-tui` 的 1 个测试（`tests/test_translator.py`）是仓库内唯一的 Python 测试。

本次未在仓库中找到 `e2e`、`playwright`、`cypress` 目录或对应依赖，`web-ui` 侧本次未找到测试文件或测试脚本。

## 5. 跨平台与发布组织

产品主平台是 Android。平台判定依据来自构建配置而非 README 声明：`app/build.gradle.kts` 使用 `android.application` 插件，`compileSdk = 37`、`minSdk = 26`、`targetSdk = 37`，`abiFilters` 为 `arm64-v8a` 与 `x86_64`，并启用 ABI 拆分（`splits.abi`，bundle 任务下关闭，`isUniversalApk = true`）。release 签名从 `local.properties` 读取，debug 变体通过 `applicationIdSuffix = ".debug"` 区分。库模块统一经 `build-logic` 的 `rikkahub.android.library` / `rikkahub.android.library.compose` 约定插件接入，`web` 模块以 24 为 `minSdk` 低于应用。

其他平台以「同一份 Android 代码 + 旁路工程」的方式组织：

| 端 | 组织方式 |
| --- | --- |
| Web 端 | 独立 `web-ui` React 应用，经 `web` 模块 Ktor 服务端承载；app 内 `web` 包提供路由与 mDNS 注册 |
| 基准性能 | `app:baselineprofile` 子模块，含 `BaselineProfileGenerator` 与 `StartupBenchmarks` |
| 本地化工具链 | `locale-tui` 直接读写 Android 字符串资源 XML，独立 Python 运行时 |
| 契约测试工具链 | `trace-cli` 独立 Bun 运行时，产出喂给 `ai` 模块测试 |

Web 端通过协议复用接入：

- `web` 模块承担 Ktor 服务端（`ktor.server.cio`、`auth`/`jwt`、`sse`、`compression`、`cors`、`status pages`）
- `app/src/main/java/me/rerere/rikkahub/web/` 下实现 `WebServerManager`、`WebApiModule`、`NsdServiceRegistrar` 与按域拆分的路由（Conversation、Settings、Files、Folder、Events、AIIcon）
- `web-ui` 通过 `api.ts`/`events.ts` 消费这些 HTTP/SSE 接口

前端到 Android 的嵌入由 `web/build.gradle.kts` 的 `buildWebUi` Exec 任务完成：在 `web-ui` 目录执行 `pnpm run build`，输出到 `web/src/main/resources/static/`，并通过 `preBuild.dependsOn(buildWebUi)` 挂入 Android 构建。该任务只跑 `build` 不跑 `install`，因此在 CI 中需要预先安装前端依赖。

发布通道只有一条自动化工作流。`.github/workflows/daily-build.yml` 在 UTC 09:00 与 18:00 触发，先判断过去 24 小时是否有新提交以决定是否构建；构建步骤要求 JDK 17（temurin）、pnpm 11、Node 22，并递归拉取子模块。签名与集成配置来自 Secrets（`KEY_BASE64` 解码为 `app/app.key`、`SIGNING_CONFIG` 写入 `local.properties`、`GOOGLE_SERVICES_JSON` 写入 `app/google-services.json`），随后执行 `./gradlew assembleRelease`，最后用 `softprops/action-gh-release` 把 APK 发布到固定 tag `nightly` 的 prerelease。工作流内注释指出 `gradle` 的 `buildWebUi` 任务只构建不安装依赖，因此流水线单独增加了 `pnpm install --frozen-lockfile` 步骤。仓库另有 `.github/workflows/close-blank-issues.yml` 与 3 个 issue 模板，属于社区维护配置。

## 6. 工程配套与结构特征

Gradle 侧使用版本目录与工具链配置：`gradle/libs.versions.toml` 集中声明 AGP 9.4.0、Kotlin 2.4.10、Compose BOM 2026.09.00、Ktor 3.5.2、Room 2.8.5、Koin 4.2.2 等版本；wrapper 为 Gradle 9.6.0；`gradle.properties` 开启 `org.gradle.configuration-cache`；`gradle/` 下另有 `gradle-daemon-jvm.properties` 与被跟踪的 `vineflower.jar`（约 1.6MB，用于反编译，本次未定位调用点）。`app` 通过 KSP 生成 Room 代码并把 `room.schemaLocation` 指向 `app/schemas`，因此数据库 schema 的 26 个版本化 JSON 进入仓库，同时 `app/build.gradle.kts` 把 `schemas` 目录挂进 `androidTest` 的 assets。

工程中跟踪了若干体积显著的资源与生成文件，它们不进入源码行统计，但明显影响仓库尺寸：

| 资产 | 位置 | 量级 |
| --- | --- | ---: |
| Jieba 分词词典 | `app/src/main/assets/simple_dict` | 9 文件 / 13.7MB |
| Banner 图 | `app/src/main/assets/banner` | 3 文件 / 5.0MB |
| Mermaid 与 `mark.html` | `app/src/main/assets/html` | 2 文件 / 3.4MB |
| Emoji / 图标 | `app/src/main/assets/emoji`、`icons` | 55 文件 / 0.9MB |
| `libsimple.so` | `app/src/main/jniLibs/{arm64-v8a,x86_64}` | 8.6MB / 8.5MB |
| `libmupdf_java.so` | `document/src/main/jniLibs/{arm64-v8a,x86_64}` | 9.2MB / 9.6MB |
| proot 原生库 | `workspace/src/main/jniLibs` | 4 文件 |
| Google Sans Flex 字体 | `app/src/main/res/font` | 4.06MB |
| 基线画像文本 | `app/src/release/generated/baselineProfiles` | `baseline-prof.txt` 与 `startup-prof.txt` 各约 6.05MB |

`app/src/main/assets` 合计约 23MB。图片、字体与词典资源同时以真名称出现在 `assets` 与 `res` 两处，说明资源类型的分工按打包用途而非按格式。

可观察的结构信号包括：

- **`app` 体型占比高**。`app` 占全仓源码行约 58.6%，其中 `ui` 包又占全仓约 36.5%，且单文件规模上限较高（如 `SettingProviderDetailPage.kt` 约 62.6KB、`SettingMcpPage.kt` 约 46.8KB、`PromptPage.kt` 约 47.9KB）。目录声明与实际依赖方向一致：`ai`、`search`、`speech` 等能力模块不反向依赖 `app`。
- **同类模块呈平行目录而非统一抽象**。`search` 下 23 个文件对应 Bing、Brave、Exa、Tavily、Zhipu、SearXNG、Serper、Jina、Perplexity、Firecrawl、LinkUp、Metaso、Ollama、Doubao、Grok、Bocha、Tinyfish、RikkaHub 等多个服务实现；`speech` 分 ASR 与 TTS 两套 Provider 目录；`ai` 分 `openai`/`claude`/`google`（含 `vertex`）三族与各自的流式解码器。每个 Provider 一个文件的组织方式使模块内文件数与外部服务数成正比。
- **命名边界存在两套写法**。`app` 与能力模块使用 `me.rerere.*` 命名空间，`document` 同时包含 `com.artifex.mupdf.fitz` 原样保留包名，`web` 使用 `me.rerere.rikkahub.web` 而 `trace-cli` 的包名为 `@rikkahub/trace-cli`。
- **生成物与手工代码同库**。除基线画像与 Room schema 外，`web-static` 是生成后再被 `web` 模块消费的目录，`.gitignore` 排除的是产物而非目录本身，因此该目录在 Git 中表现为一个占位文件。

## 7. 设计取舍与已确认边界

- 核心代码用一个 Gradle 工程承载，能力域模块只依赖 `common` 与 Android/Compose 基础库；`app` 聚合全部业务模块，形成单入口应用。这一结构在 `app/build.gradle.kts` 的 `project(":...")` 依赖列表与各库模块 `build.gradle.kts` 中可直接读出。
- 开发工具链没有被抽象进 Gradle：`locale-tui` 与 `trace-cli` 各自维护独立清单与锁文件（`uv.lock`、`bun.lock`），与 Android 构建解耦，代价是需要各自的运行时。`web-ui` 虽然独立维护 `package.json` 与 `pnpm-lock.yaml`，但被 `web` 模块以进程调用方式纳入 Android 构建。
- 测试策略偏向「离线夹具回放」：`ai` 的流式解码与 `highlight` 的分词结果都以仓库内快照为期望值，网络与渲染不在单元测试范围内。
- 本快照中包含一处文档与实现不一致：`ai/README.md` 仍描述 MNN 子模块与 `src/main/cpp` 的 CMake 构建，而对应目录、子模块登记与 Gradle 原生构建配置均不存在或被注释。
- 文档数量（134）包含 72 个代理技能文件与 43 个测试夹具，不能直接当作架构文档量；面向人的架构说明目前只有 `docs/references/chat-generation-pipeline.md` 一篇。

## 8. 未验证事项

- 未运行 `./gradlew assembleDebug`、`test`、`lint` 或任何前端/CLI 构建与测试，模块行数、依赖可解析性与测试通过情况均为静态读取结果。
- 提交历史经本地 Git 复核为 2851 个提交（含 74 个合并提交，非合并 2777），首提交时间 2025-03-11，最近 90 天 319 次；与本次提供的机械统计「主线 2723 提交、最近 90 天 324 次」存在差异，差异来源未查明（可能为统计脚本对合并提交或检索范围的定义不同）。
- `gradle/vineflower.jar` 与根目录 `package.json`、`bun.lock` 的实际使用入口未定位。
- `material3/material-color-utilities` 子模块内容未展开，未确认其源码是否参与实际编译。
- `web-ui` 是否有测试、`trace-cli` 的 `traces.yml` 中 `google-interactions` 轨迹是否已产出对应夹具（`ai` 夹具目录中本次只看到四组），均未逐项核对。
- 未运行任何 Android 构建，`abiFilters`、ABI 拆分、`minSdk` 差异与 `libsimple.so`/`libmupdf_java.so`/proot 原生库的 ABI 覆盖一致性未在设备或产物层面验证。
- 前端静态产物由 CI 的 `pnpm run build` 生成，本地 `web/src/main/resources/static/` 不存在；未验证嵌入后的实际加载路径。

## 9. 关键源码索引

- `settings.gradle.kts`：Gradle 模块清单与 `includeBuild("build-logic")`
- `.gitmodules`：唯一的子模块登记（`material3/material-color-utilities`）
- `gradle/libs.versions.toml`、`gradle/wrapper/gradle-wrapper.properties`、`gradle.properties`：依赖版本与构建开关
- `build-logic/src/main/kotlin/`：`AndroidLibraryConventionPlugin`、`AndroidLibraryComposeConventionPlugin` 约定插件
- `app/build.gradle.kts`：应用 SDK/ABI/签名/拆分配置、`app` 对全部能力模块的依赖、Room schema 输出
- `.github/workflows/daily-build.yml`：唯一的发布流水线（nightly prerelease）
- `web/build.gradle.kts`：`buildWebUi` 任务与 `preBuild` 挂载，前端产物嵌入路径
- `web/src/main/java/me/rerere/rikkahub/web/Entry.kt`：Ktor 服务端入口
- `app/src/main/java/me/rerere/rikkahub/web/`：`WebServerManager`、`WebApiModule`、`NsdServiceRegistrar` 与 `routes/`
- `app/src/main/java/me/rerere/rikkahub/ui/`、`app/src/main/java/me/rerere/rikkahub/data/`：UI 与数据层主体
- `ai/src/test/resources/stream-traces/README.md`、`trace-cli/README.md`：夹具生成与回放链路
- `highlight/tools/generate-hljs-fixtures.mjs`：高亮夹具生成脚本
- `locale-tui/pyproject.toml`、`locale-tui/src/main.py`：本地化工具入口
- `workspace/src/main/cpp/CMakeLists.txt`、`workspace/src/main/jniLibs/`：沙箱原生部分
- `document/src/main/java/com/artifex/mupdf/fitz/`：vendored MuPDF 绑定
