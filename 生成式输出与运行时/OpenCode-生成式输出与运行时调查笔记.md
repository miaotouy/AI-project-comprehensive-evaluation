# OpenCode 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：源码静态调查，按关键词（artifact、snapshot、patch、diff、pty、codemode、sandbox、iframe）交叉定位并通读核心链路；未运行构建、测试或交互
>
> 调查范围：模型生成输出的对象模型与持久化、流式更新、文件 diff 与快照版本、投影表面、执行位置与权限、撤销闭环、模型回流、Artifact 托管与受限代码执行；工具注册、消息渲染与会话调度分别进入其他类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 2.x 的生成式输出仍以真实文件系统为事实源：模型通过结构化工具调用（`read`/`write`/`edit`/`patch`/`shell`）操作工作区，文件变化由快照服务记录为版本，并由步骤结束事件携带"快照 + 变更文件"落库。新增的变化有两层：

- **Artifact 层**：模型可创建/读取/更新/删除 Artifact（`art_` 前缀），Artifact 是一组相对路径到文本的文件映射加一个入口文件，由 Artifact Provider 托管并按 URL 访问；Provider 声明自身能力（静态、服务端代码、SQLite、Durable Objects），本地 Provider 默认可用。
- **Code Mode 运行时**：`packages/codemode` 提供一个只实现受控语法的解释器，模型写的小程序只能通过宿主暴露的工具与外界交互，不能直接触网、读写文件或调用进程 API。

除此之外，代码执行仍在本机进程内（shell 子进程、LSP 子进程、PTY 终端、后台 job），未找到容器级隔离沙箱；撤销仍是整条消息粒度的文件回滚，配合分阶段确认。

## 系统边界与完整主链

本类目覆盖"模型输出 → 活对象"的链路：工具参数 → 文件写入或 Artifact 创建 → 快照与差异记录 → 消息内容落库 → SSE 投影 → diff 审查 → 回退。Chat 类目接手调度、中止与上下文装配；消息渲染器接手外观；Agent 工具类目接手注册与审批。

```text
用户输入 -> 执行器单步（session/runner/step.ts）
  -> 工具调用（core/src/tool.ts 执行，权限判定）
       ├─ 文件类工具写工作区
       ├─ Artifact 工具写 Artifact（core/src/artifact.ts + 本地 Provider）
       └─ Code Mode 程序在受限解释器内调用工具
  -> 快照（core/src/snapshot.ts capture/diff/restore）
  -> 步骤结束事件 session.step.ended 携带 snapshot 与 files
  -> 消息内容与事件落库（session_part / session_message）
  -> SSE -> 客户端时间线与 diff 视图
  -> 回退：stage -> commit/clear（core/src/session/revert.ts）
```

## 1. 对象模型与事实源

- **消息内容**：助手内容项为文本、推理、工具三种；工具项带流式输入、运行中、完成、失败状态与结果内容（`packages/schema/src/session-message.ts`）。与生成式输出直接相关的信息都在工具项里：命令、路径、diff、诊断、退出码等。
- **步骤边界**：步骤结束事件携带本次步骤的快照 id 与变更文件集合，步骤失败事件同样携带快照信息（`packages/schema/src/session-event.ts` 的 `session.step.ended/failed`）。
- **三层事实源**：工作区文件是产物本体；SQLite（`session_message`/`session_part`/`blob`）是对话与附件事实源；快照仓库（`packages/core/src/snapshot.ts`，位于数据目录的影子 Git 仓库）是文件版本事实源。消息里保存的是哈希与 diff 文本，内容以快照仓库为准。
- **Artifact**：Artifact 记录 id、Provider、标题、入口文件、访问 URL 与文件映射（`packages/schema/src/artifact.ts`）；文件内容按相对路径保存，读取与更新以整组文件为单位。

## 2. 增量生成、更新与最终化

- **文本与推理**：按 delta 事件流式推送（`session.text.delta`、`session.reasoning.delta`），步骤结束时以完整内容收口。
- **工具参数**：先有流式输入事件（`session.tool.input.delta`），最终参数在调用事件时一次性给出；流式中间态只用于展示，不作为可执行输入。
- **文件修改粒度**：`write` 全文覆盖、`edit` 按定位替换、`patch` 按补丁块应用；补丁解析与统计在 `packages/core/src/vcs/patch.ts`（patch 大小与上下文有上限）。
- **快照**：`Snapshot.capture` 生成文件树版本，`diff` 生成文件差异，`restore` 按文件恢复到指定版本（`core/src/snapshot.ts` 的服务接口）。步骤结束时对比起始快照与结束快照，得到变更文件清单。
- **最终化**：步骤结束事件收口快照、文件清单、usage 与完成原因；失败步骤记录错误与已完成部分；助手消息的 `retry`、`error`、`finish` 字段描述终止情况。

## 3. 投影表面与多视图

- **消息内**：工具卡片按工具名渲染，编辑/写入/补丁类工具内嵌 diff；diff 来源是工具结果里的文件差异信息。
- **回合级**：步骤结束事件的文件清单与快照差异用于"本轮变更"视图；App 的会话页有独立审查面板展示工作区 diff、分支 diff 与最近一轮 diff。
- **TUI**：diff 查看器支持工作区/分支/最近回合三种来源与 unified/split 视图；工具卡片在终端内降级渲染。
- **CLI**：非交互模式按事件流输出步骤与工具结果。
- **多视图一致性**：所有表面消费同一持久化消息与事件流；未持久化的中间态（如流式参数）只在运行时可见。

## 4. 表现类型与运行环境

- **展示类型**：markdown 文本、代码高亮、图片/附件、行级 diff、终端输出、Artifact 预览（按 URL 打开）。
- **Artifact 托管**：Provider 以能力声明区分形态——静态文件、服务端代码、SQLite 存储、Durable Objects；本地 Provider 是默认实现，接口支持 create/update/delete 并在更新后发 Artifact 事件。访问经实验性端点 `artifacts.view/*` 提供文件。
- **Code Mode**：解释器只支持实现过的语法子集，程序可调用宿主提供的工具与扩展全局对象；宿主可限制执行时间、工具调用次数、输出大小与数据。不支持语法返回带位置的诊断，未完成的工作在程序结束时被中断。
- **未找到**：通用 iframe/WebView 沙箱容器、Notebook 运行时、本地语言解释器集群；`patchmark` 是流式 markdown 修补库，不参与文件补丁执行。

## 5. 用户交互与错误反馈

- **运行状态**：shell、检索与子 Agent 工具通过进度事件回传实时状态；步骤结束时给出退出码、截断标记与诊断。
- **交互式对象**：`question` 工具以表单向用户提问，`todowrite` 维护会话待办，`artifact` 工具返回可打开的产物链接。
- **审批**：写文件、执行命令等高风险动作在调用前经权限规则集判定，需要时阻塞等待人工回复；拒绝会作为工具错误回流模型。
- **错误**：工具错误卡片展示失败原因；assistant 消息记录终止错误与重试信息。

## 6. 编辑、diff、版本与协作

- **用户编辑**：OpenCode 不内置文本编辑器；用户在外部编辑器修改，由文件监听与工作区 diff 呈现。
- **版本粒度**：快照是步骤级文件树版本，不是文件提交历史。
- **回退分阶段**：`POST /api/session/:id/revert/stage` 记录目标消息与文件快照，`revert/commit` 执行实际清理，`DELETE revert` 撤销暂存并恢复文件；回退按消息边界生效（`core/src/session/revert.ts`、`packages/protocol/src/groups/session.ts`）。
- **接受/拒绝粒度**：整条消息级回退；未找到 hunk 级接受/拒绝、冲突解决或 CRDT。分支通过会话 fork 表达。

## 7. 能力桥、执行位置与权限

| 能力 | 执行位置 | 权限与边界 |
|---|---|---|
| 文件读写 | 服务端进程直接访问工作区 | 路径越界与敏感文件由权限规则集判定 |
| 命令执行 | 本机子进程 | 调用前判定；命令内容做结构解析用于风险判定 |
| 终端 | PTY（含持久化守护进程实现） | 会话级票据鉴权 |
| LSP | 本地语言服务器子进程 | 诊断随工具结果回流 |
| 网络 | webfetch/websearch 工具 | 权限规则集控制 |
| Artifact | Artifact Provider（本地默认） | 实验性端点访问 |
| Code Mode | 受控解释器 | 只能调用宿主提供的工具 |

## 8. 持久化、恢复与导出

- **会话数据**：SQLite 保存消息、内容、附件与待办。
- **文件版本**：快照仓库跨进程持久，回退与差异展示依赖其中的对象存活。
- **附件**：按内容哈希存 blob 表，消息引用哈希。
- **Artifact**：由 Provider 保存文件与元数据，更新发事件；本地 Provider 的数据随数据目录持久化。
- **导出**：会话导出包含消息与元数据；Artifact 是独立对象，不在会话导出范围内。

## 9. 模型回流与对象感知

- **历史回流**：每轮从会话历史重建模型消息，工具结果按状态转成结果或错误、推理转成思考内容；快照与步骤边界不进上下文。
- **对象感知**：模型通过 `read`/`glob`/`grep` 感知工作区，通过 `artifact` 工具感知与更新已创建的产物；没有"会话产物清单"式查询协议，工作区文件仍是主要对象面。
- **身份绑定**：工具调用 id 保证调用与结果配对；快照哈希提供跨步骤的文件版本连续性；Artifact 有稳定 id 与 URL。

## 10. 生命周期、资源治理与性能

- **资源释放**：shell 超时或中断时终止子进程；PTY 会话与 LSP 客户端随会话/位置生命周期关闭；后台 job 由 job 子系统管理。
- **限额**：工具输出截断（2000 行 / 50 KiB，超限落盘）、补丁大小上限、步骤数上限、Code Mode 执行限额、上下文压缩。
- **快照清理**：快照仓库按保留策略清理，过期版本无法再回退。

## 11. 已确认边界与未验证事项

**已确认边界：**

- Artifact 是新增的对象层，但能力由 Provider 声明，本地默认 Provider 只提供文件托管；服务端代码与 Durable Objects 等能力属于其他 Provider。
- Code Mode 是受限解释器而非沙箱化 JavaScript，能力面由宿主显式提供。
- 未找到容器级隔离执行、iframe 沙箱与 Notebook 运行时。
- 回退粒度为整条消息；未找到 hunk 级接受/拒绝或三方合并。

**未验证事项（需运行确认）：**

1. 快照跨进程重启后的回退与差异展示。
2. Artifact 预览在浏览器中的实际隔离行为与不同 Provider 的能力差异。
3. Code Mode 在真实工具组合下的限额与中断行为。
4. PTY 持久化守护进程在断线重连后的表现。

## 12. 关键源码索引

- `packages/schema/src/session-message.ts`、`session-event.ts`：内容与步骤事件契约
- `packages/core/src/snapshot.ts`：快照捕获、差异与恢复
- `packages/core/src/vcs/patch.ts`：补丁解析与统计
- `packages/core/src/session/revert.ts`：分阶段回退
- `packages/core/src/artifact.ts`、`packages/schema/src/artifact.ts`：Artifact 服务与契约
- `packages/core/src/tool/plugin/artifact.ts`：Artifact 工具
- `packages/codemode/README.md`、`packages/core/src/codemode/`：受限执行
- `packages/core/src/pty/`、`persistent-pty/`：终端能力
- `packages/protocol/src/groups/artifact.ts`：Artifact 端点
- `packages/session-ui/src/timeline/`：diff 与产物展示组件
