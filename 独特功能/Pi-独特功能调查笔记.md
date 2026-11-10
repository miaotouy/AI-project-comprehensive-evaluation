# Pi 独特功能调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/coding-agent`、`packages/agent`、`packages/telemetry`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`ff33ef42c4bd762cecd6958e3aabbc8e684ceb05`（分支：`main`）
>
> 调查方式：局部补查。通读根 README 与 `packages/coding-agent/docs/`（usage、session-format、containerization、extensions）；抽查 `interactive-mode.ts` 的 `/export`、`/share` 实现与 `packages/telemetry` 契约；与现有十类通用笔记交叉核对覆盖范围；未运行交互会话
>
> 调查范围：第三批候选——自扩展 Agent harness、终端组件树、分支会话、容器化、会话数据分享；会话数据生产/导出用于训练或研究的闭环（研究数据发布候选）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 有两条达到主链确认的差异化能力。会话数据生产与分享把 JSONL 会话、HTML/JSONL 导出、Radius/Gist 分享和仓库外的 Hugging Face 发布工具连成研究数据交付链。durable 多进程会话把持久 harness（`packages/durable`）、按会话 fork 的 Chord worker、基于 Chord 插件的 p2 应用（Web host + TUI host）组合成可断线恢复的聊天表面；这条链现在有独立包与独立应用承载，但 p2 仍自称实验性原型。

## 介绍声明与候选盘点

README 开篇把 Pi 定位为“minimal, extensible agent harness”，并明说跳过 sub-agents 与 plan mode 这类特性；其余介绍性内容集中在同一文件的 Packages 小节、权限与容器化段落和“Share your OSS coding agent sessions”章节（`README.md:13-17`、`:72`、`:88-96`、`:182-196`）。五条候选状态：

| 候选 | 状态 | 依据 |
|---|---|---|
| 自扩展 Agent harness | 归并已有类目 | 扩展系统（registerTool、before_agent_start、custom 条目、Pi Packages）在 Agent 工具笔记 §1/§5、Agent 角色笔记 §5 已覆盖；harness 会话存储抽象在会话笔记 §5/§11 有交接记录 |
| 终端组件树 | 归并已有类目 | 消息渲染器笔记整篇覆盖（终端组件树 + 事件驱动全量重建 + 帧节流，`packages/tui/src/tui.ts:1033-1080`） |
| 分支会话 | 归并已有类目 | 会话笔记 §1/§4 覆盖 branch/createBranchedSession/forkFrom/branchWithSummary |
| 容器化 | 归并已有类目 | Agent 工具笔记 §5、生成式输出笔记 §11 已确认仅是部署文档（`packages/coding-agent/docs/containerization.md`），非内置运行时 |
| 会话数据分享 | 主链确认（仓库内）/ 外部依赖（发布端） | JSONL/HTML、Radius/Gist 与 HF 发布交接，见下 |
| Durable 多进程会话 | 主链确认（独立包 + 实验应用） | durable harness + Chord worker + p2（Web/TUI host）+ 插件热重载，未运行验证 |

## 已确认的独特能力

### 能力二：实验性 durable 多进程会话

这条能力面向会话跨进程托管、断线重连和插件热重载。事实对象由 durable harness 提供：Conversation 是不可变 entry 组成的对话记录，Task 是每一步都存 checkpoint 的持久状态机，turn 与 run 描述一次模型响应及其工具调用；Chord 提供对象引用、文档、worker 与 facet 插件机制（`packages/durable/README.md`、`packages/chord/README.md`）。每个会话由一个 fork 出来的 session worker 持有，第一次引用时启动、空闲后停止、崩溃后重启，并把失败保留到重试；同一会话的重定位与克隆按会话串行执行（`apps/p2/src/hosts/session-workers.ts`）。

产品入口是 `apps/p2`：它同时提供 Web host（`node --import ./src/source.ts src/hosts/server.ts`，默认 8788 端口）和自己的 TUI host，插件目录里有会话、搜索、共享、子代理、终端、codemode、mcp、Radius 等页面与工具，由 Chord 负责激活与热重载（`apps/p2/README.md`、`apps/p2/docs/p2-notes.md`）。p2 自称实验性原型，数据格式与 API 会变。

持续性来自 durable 的提交语义：对话、模型回合、工具调用与调用方自有状态先写入存储再对外展示，进程中途死掉重开存储可继续，死在某次模型请求上的会记为失败尝试并重试。存储后端可在 Memory、JSONL、SQLite 与 IndexedDB 之间替换；conversation 的 UUIDv7 作为 provider 侧 sessionId 用于 prompt cache 与会话亲和，另一个进程可以用只读方式打开同一会话（`packages/durable/README.md` 的 Persist and Resume、`packages/durable/src/storage/`）。该链在仓库内可静态复查：durable 包、p2 应用与 Chord v2 文档都在本仓；未运行 p2 的 Web/TUI、worker 崩溃重启或远端重连，因此只记为源码主链确认。

### 能力一：会话数据生产与分享（研究数据发布候选）

1. **用户目标**：把真实 OSS 编码 Agent 会话变成可发布的训练/评估数据。README 说明公开 OSS 会话数据能让编码 Agent 用真实任务、工具使用、失败与修复来改进，替代玩具基准（`README.md:186`）；docs/usage.md 里“model, prompt, tool, and evaluation research”的表述，本次在 `packages/coding-agent/docs` 全文检索未找到。会话文件格式、导出命令与外部发布工具由此组合成一条数据生产工作流。
2. **入口与触发者**：由用户主动触发。交互层提供 `/export` 与 `/share` 两个命令，前者导出 HTML 或 JSONL 副本，后者经 shareSession 上传当前分支；文档另指向伴生 CLI pi-share-hf 做批量发布（`interactive-mode.ts:6746`）。
3. **事实对象**：会话以 JSONL 会话树文件保存，v3 格式，位于 `~/.pi/agent/sessions/<编码cwd>/`。docs/session-format.md 公开条目类型与消息结构，并注明理解这些类型是解析会话与编写扩展的前提，第三方解析器据此形成格式契约（`packages/coding-agent/docs/session-format.md:41`）。
4. **完整主链**：会话先以 append-only JSONL 落盘（见会话笔记 §2），之后按用途分流：
    - `/export` 生成自包含 HTML 单文件或 JSONL 副本，HTML 的模板与 base64 会话数据取自 `core/export-html/`；
    - `/share` 把当前分支导出为 Radius artifact，并额外记录 system prompt 与激活的工具定义；没有 Radius provider 或有效凭据时，才回退到 `gh gist create --public=false`；
    - 外部工具 pi-share-hf 读取 JSONL，发布为 Hugging Face 数据集。

    仓库内的导出与分享主链已静态确认，发布端位于仓库外（`packages/coding-agent/src/modes/interactive/session-share.ts`）。
5. **持续性**：会话文件本身长期保留，本次未找到自动清理证据（会话笔记 §7）；Radius artifact、gist 与 HF 数据集的生命周期分别由各自外部平台管理。
6. **主动性与取消**：没有后台调度，全部动作由用户触发。`/share` 失败时走 showError 错误路径（`interactive-mode.ts:5930-5933`），上传期间提供可取消的 loader。
7. **人机与多 Agent 关系**：本能力没有多 Agent 参与，用户检查导出文件内容后自行决定是否分享。
8. **外部依赖与执行域**：执行域按依赖分四层：
    - 本机：JSONL 与 HTML 导出都在仓库内完成；
    - Radius：具备 provider 与登录态时，`/share` 可把会话上传为组织可见 artifact；
    - GitHub：缺少 Radius 条件时回退到 gh CLI 与 gist，需要本机安装 gh 并已登录；
    - 发布端：伴生仓库 badlogic/pi-share-hf 与 Hugging Face 位于仓库之外（`README.md:190`）。

    `packages/telemetry` 与本能力无关，它是 vendor-neutral 遥测契约包，提供内存参考实现与 conformance 测试，供 ai/agent 包生成类型化 span；该包按无 exporter、无全局 span 状态、不依赖后端的契约形态提供，没有会话数据上报路径（`packages/telemetry/README.md:5-13`）。
9. **安全与资源边界**：两条上传路径都要求用户先显式触发 `/share`，Radius 路径创建组织可见 artifact，gist 回退路径创建的是 secret gist（`--public=false`）。会话 JSONL 含完整对话与工具输出，Radius 路径还会额外写入 system prompt 与工具 schema，分享前需按目标平台的实际可见性判断数据边界。
10. **独特性判断**：现有类目覆盖的是会话导出这一普通功能。本能力把导出格式、公开文档与研究导向的发布工作流连成闭环，属对话导出与分享中的研究/发布分型。Hermes Agent 的批量轨迹生成、OpenCode 的可移植会话档案在对象和消费者上都与本能力不同，暂未形成统一自然聚类，保留为稀有能力卡。
11. **证据强度**：按证据层级记录：
    - README 与 docs 的声明：介绍候选；
    - 仓库内 `/export` 与 `/share` 主链：静态源码确认（主链确认，限定仓库边界）；
    - HF 发布端：伴生仓库引用（外部依赖，未验证）。

    以上均未做运行验证。

## 已归并到现有类目的能力

- **自扩展 Agent harness**：Pi 的扩展系统承担自扩展能力，扩展可以注册工具、在 `before_agent_start` 阶段改写上下文、写入 custom 会话条目，并通过 Pi Packages 经 npm 或 git 安装分享（`packages/coding-agent/docs/packages.md`）。这些机制已被 Agent 工具笔记（§1 扩展注册、§5 钩子）与 Agent 角色笔记（§3 每轮改写）覆盖，harness 的会话存储抽象也已迁到 durable 包（会话身份与存储后端见会话笔记 §12），因此不另立能力卡。
- **终端组件树**：pi-tui 差分渲染库（`packages/tui`，92 文件/33.9k 行，仓库分布笔记）是消息渲染器笔记的核心内容，非独特功能。
- **分支会话**：会话笔记 §4 完整覆盖。
- **容器化**：README 与 `docs/containerization.md` 的三种模式（Gondolin 扩展、Plain Docker、OpenShell）是部署文档而非内置运行时，Agent 工具笔记 §5 与生成式输出笔记 §11 已确认；Gondolin 以示例扩展形式存在于本仓库（`examples/extensions/gondolin/`），属扩展生态而非独特能力。

## 声明不符、外部依赖与暂缓项

- **HF 数据集发布**：`badlogic/pi-share-hf` 不在本仓库，其读取格式、去重与推送行为未验证（暂缓，外部依赖）。
- **研究数据发布闭环完整度**：本仓库只承担“生产与导出”侧；数据被外部消费为训练语料的事实无法在本仓库验证（README 声明 + 外部工具，非本仓库主链）。

## 对特色贡献统计的影响

- “会话数据生产与分享”以 `主链确认`（仓库内 `/export`、`/share` 主链；HF 发布端外部）列入对话导出与分享的研究/发布分型；“durable 多进程会话”以实验入口的主链确认列入多表面连续性候选。两者均不据此升级为新的通用顶层类目。

## 未验证事项

- `/share` 依赖本机 `gh` CLI 与 GitHub 账号，端到端 gist 流程未运行。
- `pi-share-hf` 的发布行为、HF 数据集内容与格式未验证。
- `/export` HTML 的浏览器端渲染（template.js）未运行验证（与消息渲染器笔记一致）。

## 关键源码索引

- `README.md:182-196`（Share your OSS coding agent sessions 章节）、`README.md:88-96`（权限与容器化）
- `packages/coding-agent/docs/usage.md:138-141`（/share 与研究用途说明）
- `packages/coding-agent/docs/session-format.md:41`（会话格式公开契约）
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts:2895-2906`（/export、/share 命令分发）、`:5773-5787`（导出实现）、`:5862-5954`（gist 创建）
- `packages/telemetry/README.md:5-13`（无 exporter 的契约包）
