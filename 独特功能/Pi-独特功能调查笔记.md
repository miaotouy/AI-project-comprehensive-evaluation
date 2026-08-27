# Pi 独特功能调查笔记

> 调查对象：`https://github.com/earendil-works/pi`（重点 `packages/coding-agent`、`packages/agent`、`packages/telemetry`）
>
> 调查更新日期：2026-08-27
>
> 代码快照：`e86823096c5bad39e1ca282ec24bc5eb9bec745b`（分支：`main`）
>
> 调查方式：局部补查。通读根 README 与 `packages/coding-agent/docs/`（usage、session-format、containerization、extensions）；抽查 `interactive-mode.ts` 的 `/export`、`/share` 实现与 `packages/telemetry` 契约；与现有十类通用笔记交叉核对覆盖范围；未运行交互会话
>
> 调查范围：第三批候选——自扩展 Agent harness、终端组件树、分支会话、容器化、会话数据分享；会话数据生产/导出用于训练或研究的闭环（研究轨迹候选）
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Pi 的五个第三批候选中有四个已被现有通用类目笔记完整覆盖（归并已有类目）：扩展系统与工具注册（Agent 工具）、终端组件树（消息渲染器）、分支会话（会话与消息管理）、容器化部署文档（Agent 工具/生成式输出）。本次补查新确认的未覆盖产品面是**会话数据生产与分享**：根 README 设有专门章节“Share your OSS coding agent sessions”（README.md:90-105），`docs/usage.md:138-141` 明确说明 `/share` 之外可用伴生工具 `badlogic/pi-share-hf` 将会话发布为 Hugging Face 数据集“用于模型、提示词、工具与评估研究”。仓库内主链（JSONL 会话树 → `/export` JSONL/HTML → `/share`）已达主链确认；/share 优先创建 Radius artifact，并在无法使用 Radius 时才回退至私密 gist。发布到 HF 数据集的一步位于仓库外（伴生仓库），属外部依赖。该能力可作为**研究轨迹聚类**候选收录，进入特色统计前需明确仓库边界（本仓库只生产与导出会话数据，不消费）。

## 介绍声明与候选盘点

README（README.md:13-36）自称“Pi agent harness project including our self extensible coding agent”，包清单含 telemetry/ai/agent-core/coding-agent/tui；随后是权限与容器化说明（:38-47）与“Share your OSS coding agent sessions”（:90-105）。五条候选状态：

| 候选 | 状态 | 依据 |
|---|---|---|
| 自扩展 Agent harness | 归并已有类目 | 扩展系统（registerTool、before_agent_start、custom 条目、Pi Packages）在 Agent 工具笔记 §1/§5、Agent 角色笔记 §5 已覆盖；harness 会话存储抽象在会话笔记 §5/§11 有交接记录 |
| 终端组件树 | 归并已有类目 | 消息渲染器笔记整篇覆盖（终端组件树 + 事件驱动全量重建 + 帧节流，`packages/tui/src/tui.ts:765-817`） |
| 分支会话 | 归并已有类目 | 会话笔记 §1/§4 覆盖 branch/createBranchedSession/forkFrom/branchWithSummary |
| 容器化 | 归并已有类目 | Agent 工具笔记 §5、生成式输出笔记 §11 已确认仅是部署文档（`packages/coding-agent/docs/containerization.md`），非内置运行时 |
| 会话数据分享 | 入口确认（仓库内主链）/ 外部依赖（发布端） | 本次专项，见下 |

## 已确认的独特能力

### 能力一：会话数据生产与分享（研究轨迹候选）

1. **用户目标**：把真实 OSS 编码 Agent 会话变成可发布的训练/评估数据。README 明示“Public OSS session data helps improve coding agents with real-world tasks, tool use, failures, and fixes instead of toy benchmarks”（README.md:94）；`docs/usage.md:140` 写明用于“model, prompt, tool, and evaluation research”。这不是普通导出存档，而是把会话文件格式、导出命令与外部发布工具组合成一条数据生产工作流。
2. **入口与触发者**：用户触发。交互命令 `/export`（HTML 或 JSONL 副本）与 `/share` 实现见 `interactive-mode.ts:5773-5954`（命令分发 :2895-2906）；另有 docs 指向的伴生 CLI `pi-share-hf` 批量发布。
3. **事实对象**：JSONL 会话树文件（v3 格式，`~/.pi/agent/sessions/<编码cwd>/`）。`docs/session-format.md` 公开条目类型与消息结构，注释明言理解这些类型是解析会话与编写扩展的前提（session-format.md:41）——第三方解析器依赖此格式契约。
4. **完整主链**：会话落盘（append-only JSONL，见会话笔记 §2）→ `/export` 生成 HTML 自包含单文件（`core/export-html/`，模板 + base64 会话数据）或 JSONL 副本 → `/share` 为 Radius artifact 导出当前分支，并额外记录 system prompt 与激活工具定义；没有 Radius provider 或有效凭据时才调用 `gh gist create --public=false` → 外部工具 `pi-share-hf` 读 JSONL 发布为 HF 数据集。仓库内链已静态确认；发布端在仓库外（`packages/coding-agent/src/modes/interactive/session-share.ts:24-151`）。
5. **持续性**：会话文件本身长期保留（无自动清理证据，会话笔记 §7）；Radius artifact、gist 与 HF 数据集生命周期分别由外部平台管理。
6. **主动性与取消**：无后台调度；全部用户触发；`/share` 失败有 showError 错误路径（interactive-mode.ts:5930-5933），上传期间有可取消的 loader（:5885-5910）。
7. **人机与多 Agent 关系**：无多 Agent 参与；用户可检查导出文件内容后决定是否分享。
8. **外部依赖与执行域**：本机 JSONL/HTML 导出（仓库内）；Radius provider 与登录态可将 `/share` 上传为组织可见 artifact；缺少此条件时，`gh` CLI 与 GitHub gist（需本机安装 gh 与登录态）构成回退路径；`pi-share-hf`（伴生仓库 badlogic/pi-share-hf）与 Hugging Face 位于发布端（README.md:98-104 引用）。`packages/telemetry` 与本能力无关：它是 vendor-neutral 遥测契约包，本次更新新增内存参考实现与 conformance 测试（供 ai/agent 包做类型化 span），但仍是"无 exporter、无全局 span 状态、不依赖后端"的契约包（telemetry/README.md:5-13），无会话数据上报路径。
9. **安全与资源边界**：Radius 路径创建组织可见 artifact，gist 回退路径仍创建 secret gist（`--public=false`）；两者都把外发动作限定在用户显式触发 `/share` 后。会话 JSONL 含完整对话、工具输出，以及 Radius 路径额外写入的 system prompt 与工具 schema，分享前需按实际外部平台可见性判断数据边界。
10. **独特性判断**：现有类目只解释“会话导出”（会话/导出是普通功能）；本能力把导出格式、公开文档与研究导向的发布工作流连成闭环，属于指南中的“研究轨迹”标签。最接近项目：Hermes Agent（研究轨迹候选，待查清单第二批）、OpenCode（会话 export/import 工具，但无研究数据导向的发布链路）——尚未形成三项目自然聚类，保留为稀有能力卡。
11. **证据强度**：README 与 docs 声明（介绍候选）；仓库内 `/export`/`/share` 主链为静态源码确认（主链确认，限定仓库边界）；HF 发布端为伴生仓库引用（外部依赖，未验证）。未运行验证。

## 已归并到现有类目的能力

- **自扩展 Agent harness**：Pi 的“自扩展”体现在扩展系统（工具注册 `registerTool`、`before_agent_start` 改写、custom 会话条目、Pi Packages 经 npm/git 安装分享，`docs/packages.md`），已被 Agent 工具笔记（§1 扩展注册、§5 钩子）与 Agent 角色笔记（§3 每轮改写）覆盖；`packages/agent` 的 harness SDK（会话存储抽象、`createScanningSessionSearch` 未接入 TUI）在会话笔记 §5/§11 有交接记录，不另立能力卡。
- **终端组件树**：pi-tui 差分渲染库（`packages/tui`，92 文件/33.9k 行，仓库分布笔记）是消息渲染器笔记的核心内容，非独特功能。
- **分支会话**：会话笔记 §4 完整覆盖。
- **容器化**：README 与 `docs/containerization.md` 的三种模式（Gondolin 扩展、Plain Docker、OpenShell）是部署文档而非内置运行时，Agent 工具笔记 §5 与生成式输出笔记 §11 已确认；Gondolin 以示例扩展形式存在于本仓库（`examples/extensions/gondolin/`），属扩展生态而非独特能力。

## 声明不符、外部依赖与暂缓项

- **HF 数据集发布**：`badlogic/pi-share-hf` 不在本仓库，其读取格式、去重与推送行为未验证（暂缓，外部依赖）。
- **“研究轨迹”闭环完整度**：本仓库只承担“生产与导出”侧；数据被外部消费为训练语料的事实无法在本仓库验证（README 声明 + 外部工具，非本仓库主链）。

## 对特色贡献统计的影响

- 建议将“会话数据生产与分享”以 `入口确认`（仓库内 `/export`、`/share` 主链静态确认；发布端外部）列入研究轨迹聚类候选，暂不单独计为主贡献；若后续确认伴生工具接入主链或出现三项目聚类，再升级。

## 未验证事项

- `/share` 依赖本机 `gh` CLI 与 GitHub 账号，端到端 gist 流程未运行。
- `pi-share-hf` 的发布行为、HF 数据集内容与格式未验证。
- `/export` HTML 的浏览器端渲染（template.js）未运行验证（与消息渲染器笔记一致）。

## 关键源码索引

- `README.md:90-105`（Share your OSS coding agent sessions 章节）、`README.md:38-47`（容器化）
- `packages/coding-agent/docs/usage.md:138-141`（/share 与研究用途说明）
- `packages/coding-agent/docs/session-format.md:41`（会话格式公开契约）
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts:2895-2906`（/export、/share 命令分发）、`:5773-5787`（导出实现）、`:5862-5954`（gist 创建）
- `packages/telemetry/README.md:5-13`（无 exporter 的契约包）
