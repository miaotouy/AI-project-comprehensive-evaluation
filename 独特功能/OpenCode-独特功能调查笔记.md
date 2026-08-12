# OpenCode 独特功能调查笔记

> 调查对象：`E:\works\git\opencode`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`b8bd88901a4870ef3a5752840f4e23e11d54e24e`（分支：`dev`）
>
> 调查方式：只读通读根 README、AGENTS.md、packages 结构与核心模块；由专项核验覆盖 CLI/server/TUI/Desktop/app 各面，并对关键入口（`event/sql.ts`、`sync.ts`、`acp/service.ts`、`packages/codemode`、`export.ts`）抽查复核；未运行应用，未修改被调查仓库
>
> 调查范围：待查清单中 OpenCode 行的复核——多表面会话同步、CodeMode、会话档案、ACP 服务端及潜在新候选的入口、状态、执行与持久化主链；与现有十类笔记去重
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

此前"覆盖闭环、无独立独特能力卡"的结论不成立。需要注意：当前仓库是经过大重构的 V2 结构（`packages/core` 事件溯源会话核心、`packages/opencode` 主 CLI、`packages/codemode`、`packages/session-ui`、`packages/slack` 等 32 个包），旧结论可能基于旧结构。本轮确认以下达到 `主链确认`（静态证据）的新候选：

1. **多表面/多设备会话连续性**（主贡献候选）：headless server + 事件溯源同步（单写者、seq 全序、`owner_id`）+ `/sync` 的 replay/steal（所有权接管），TUI/Web/Desktop/WSL/局域网（mdns `opencode.local`）/云端 workspace 共享同一批会话与进行中的任务。
2. **CodeMode 受限 JS 编排**（主贡献候选）：模型用一小段受限 JS 编排多个 MCP 工具（无 eval 解释器、plain-data 边界、超时/输出上限、busy-loop 中断），是直接工具调用、任务分派之外的第三类执行范式。
3. **会话档案闭环**（主贡献候选）：导出（`--sanitize` 脱敏）/ 导入 / 云端分享实时同步 / PR body 内嵌分享链接自动续作，构成"研究轨迹"聚类中 Pi、Hermes Agent 之外的第三样本。
4. **ACP 服务端**（辅助贡献候选）：被其他 ACP 宿主客户端（Claude Code、Cursor、Gemini CLI 等）驱动，与自身 GitHub Copilot 渠道构成双向互操作。

归并已有类目：build/plan/general Agent、Git 快照会话级回退（`snapshot/`+`session/revert.ts`，即统计 F24 的既有主贡献）、Skill 市场、权限规则集、Copilot/多 Provider 渠道、命令系统。

## 介绍声明与候选盘点

候选归属的权威表面是 packages 结构：`packages/core`（事件溯源会话与事件存储）、`packages/opencode`（CLI 命令、server、sync、share、acp、snapshot、worktree、control-plane）、`packages/codemode`（受限 JS 运行时）、`packages/tui`/`packages/app`/`packages/desktop`/`packages/slack`（各表面）。

| 候选 | 证据状态 | 结论 |
|---|---|---|
| 多表面会话连续性（事件源同步 + 所有权接管） | `主链确认` | event/sql.ts + sync.ts（start/replay/steal/history），见能力一 |
| CodeMode 受限 JS 编排（execute 工具） | `主链确认` | packages/codemode + `tool/code-mode.ts`，见能力二 |
| 会话档案闭环（导出/脱敏/分享/PR 续作） | `主链确认` | export.ts/import.ts/share-next.ts/pr.ts，见能力三 |
| ACP 服务端（被外部 Agent 客户端驱动） | `主链确认` | `acp/service.ts`，见能力四 |
| Git 快照 + 会话级撤销/回退 | `归并已有类目` | snapshot/index.ts + session/revert.ts 即统计 F24 既有主贡献（文件/Git 事实源与回滚闭环） |
| 后台子代理 + 任务续作（background task promote） | `归并已有类目` | tool/task.ts + background-job.ts 归 Agent 工具类目（F30 子 Agent 已有 OpenCode 辅助贡献） |
| Git worktree 隔离工作区（兼云 workspace 适配器） | `入口确认` | worktree/index.ts + control-plane/adapters/worktree.ts，支撑能力一，不单独提案 |
| Session Review 行内评论 | `入口确认` | session-ui review 组件 + `command/template/review.txt`；评论→修改闭环未逐点核对，不单独提案 |
| V2 事件溯源会话核心（Context Epoch/压缩 checkpoint） | `归并已有类目` | 会话消息/请求上下文类目覆盖，实现深度作为机制单独标注 |
| Skill 市场（远程 index.json）、`agent create`、权限规则集 | `归并已有类目` | Agent 角色/工具/扩展生态类目 |
| Copilot 渠道、多 Provider（Zen/xAI OAuth） | `归并已有类目` | LLM 渠道类目 |

## 已确认的独特能力

### 能力一：多表面会话连续性（事件源同步 + 所有权接管）— `主链确认`

**用户目标**：在 TUI、Web、Desktop、WSL 远程、局域网、云端 workspace 之间共享同一批会话与进行中的任务，任一表面可接管继续；断线后按事件日志重放恢复——而不是各端各存一份会话。

**入口与触发者**：headless 服务 `packages/opencode/src/cli/cmd/serve.ts`；各表面作为客户端挂载：`cli/cmd/attach.ts`（TUI 远程挂载，`--fork/--session/--replay`）、`cli/cmd/web.ts`、`packages/desktop/src/main/sidecar.ts`（桌面端 worker 内嵌同一 `Server.listen`）、`packages/app/src/wsl/dialog-add-server.tsx`（Web UI 直连 WSL 内 server）；局域网发现经 `server/mdns.ts`（Bonjour 发布 `opencode.local`）。

**事实对象**：事件溯源表 `event_sequence`（`aggregate_id` 主键 + `owner_id`，`packages/core/src/event/sql.ts:4-7`）与 `event`（`aggregate_id`/`seq`/`type`/`data`，唯一索引 `event_aggregate_seq_idx`）；会话状态由事件投影（projector）重建。

**完整主链**：任意表面写入事件（带 `owner_id` 单写者约束，全序 seq）→ `/sync` HTTP API（`packages/opencode/src/server/routes/instance/httpapi/handlers/sync.ts`）提供 `start`/`replay`（`replayAll(payload, { ownerID, strictOwner: true })`）/`steal`（所有权接管）/`history` → 消费端（`packages/tui/src/context/sync.tsx`）按事件重放并投影 UI → 断线重连从断点续播。本地↔云端：`control-plane/workspace.ts` 的 `sessionWarp`/`startWorkspaceSyncing` + `adapters/worktree.ts` 把 worktree 作为远程 workspace 适配器。Slack 面（`packages/slack`）每线程映射一个会话，参与同一事件协议。

**持续性**：事件日志为唯一事实源，跨进程/跨设备/断线重放恢复；`owner_id` 保证同一时刻单一写者，`steal` 显式转移所有权。

**人机与多 Agent 关系**：用户可在任意表面接管（steal）进行中的任务；同步设计文档见 `packages/opencode/src/sync/README.md`（单写者、seq 全序、projector 重放）。

**独特性判断**："会话消息"类目只能解释单端会话存储；"单写者事件日志 + 跨设备重放 + 所有权接管"是会话数据层的分布式机制，构成"多表面共享同一任务与状态"（多表面连续性标签）的完整样本，通用类目无法解释其分布式部分。

**证据强度**：表结构、sync 路由、各表面接入源码为静态事实；真实多设备接管与云端同步未运行验证。

### 能力二：CodeMode 受限 JS 编排 — `主链确认`

**用户目标**：让模型用一小段受限 JavaScript（分支/循环/并行/数据变换）编排多个 MCP 工具，替代多轮串行工具调用——在"直接工具调用"和"任务分派"之外提供"可编程编排"执行范式。

**入口与触发者**：模型经 `packages/opencode/src/tool/code-mode.ts` 的 `execute` 工具触发；解释执行在 `packages/codemode`（独立包：`codemode.ts`、`tool.ts`、`tool-runtime.ts`、`tool-schema.ts`）。

**完整主链**：工具注册（`execute`）→ 受限解释器解析（无 eval）→ 子工具调用经权限过滤（MCP 工具目录白名单）→ 子调用审计与附件投影回会话 → 结果数据化返回。资源边界：`maxToolCalls`/`timeoutMs`/`maxOutputBytes`、并发上限 8、busy-loop 中断、plain-data 边界（模型代码不直接接触宿主对象）。

**安全与资源边界**：执行域为受限解释器 + 预算化的工具目录与搜索；子工具调用逐条审计并记录在会话中。

**独特性判断**："Agent 工具"可解释其暴露面，但受限 JS 解释器本身（无 eval 解释执行、超时中断、失败数据化）是独立运行时组件，非普通工具循环可覆盖；调查样本中未见同类"模型可编程工具编排"。

**证据强度**：解释器包与工具接入源码为静态事实；真实模型生成编排代码的运行行为未验证。

### 能力三：会话档案闭环（导出/脱敏/分享/PR 续作）— `主链确认`

**用户目标**：把整段会话导出为可移植 JSON（可脱敏）、从文件或 `opncd.ai/share/...` 链接导入重建、分享后实时同步，甚至在 PR body 里带分享链接供 `opencode pr` 自动导入续作——会话成为可流动的"档案对象"。

**入口与触发者**：CLI `packages/opencode/src/cli/cmd/export.ts`（`--sanitize` 全字段脱敏，`export.ts:163` `sanitize`）、`cli/cmd/import.ts`（文件/分享 URL，`parseShareUrl`/`transformShareData`，消息-part 层次重建）、`cli/cmd/pr.ts`（`gh pr checkout` + 提取 PR body 分享链接导入再续作）；Web UI 经 `packages/app/src/utils/session-export.ts` 与 `pages/session/use-session-commands.tsx`（`command.session.export`）。

**事实对象**：`Session.Info` + `SessionV1.WithParts` 消息序列化的可移植 JSON；分享服务侧 `packages/opencode/src/share/share-next.ts`（create/sync/remove/data）。

**完整主链**：导出（选择会话 → 序列化 → 可选脱敏 → 文件或分享）→ 导入（文件/URL → 校验与转换 → 按 part 重建会话）→ 分享（create 建立 → sync 实时更新 → remove）→ PR 续作（`pr.ts` 检出 PR → 解析 body 分享链接 → 导入 → 继续对话）。

**持续性**：本地文件或分享服务均持有一份可重建的档案；导入即重建独立会话，不依赖原数据目录。

**独特性判断**："会话消息"类目不覆盖"可移植会话档案 + 实时分享同步 + PR 内嵌续作"完整闭环；作为"研究轨迹"聚类（Pi 的会话数据生产、Hermes 的轨迹压缩/导出）的第三样本，事实源为"整段会话的可移植导出"，与前两者可比较。

**证据强度**：CLI 各命令与分享服务源码为静态事实；真实分享服务与 PR 续作未运行验证。

### 能力四：ACP 服务端 — `主链确认`

**用户目标**：让 Claude Code、Cursor、Gemini CLI 等 ACP（Agent Client Protocol）宿主把 OpenCode 当 agent 调用——new/load/resume/fork session、prompt、cancel、权限回调、MCP 能力广播。

**入口与触发者**：`packages/opencode/src/cli/cmd/acp.ts` 启动服务；外部 ACP 宿主经协议端点调用 `packages/opencode/src/acp/service.ts` 的 `initialize`/`newSession`/`loadSession`/`resumeSession`/`fork`/`setSessionModel`/`prompt`/`cancel`（`service.ts:56-61` 接口，`94-488` 实现）。

**完整主链**：宿主 initialize 握手（能力声明，`service.ts:115`）→ 新建/加载/续作/分叉会话 → prompt 进入既有 Session/工具/权限系统执行 → 事件回传给宿主；权限面经 `acp/permission.ts` 回调宿主确认。MCP 能力经协议广播（initialize 能力声明）。

**独特性判断**："LLM 渠道"是 OpenCode 消费外部模型；ACP 是反向被集成（OpenCode 作为 agent 服务被外部客户端驱动）。同一仓库同时内置 GitHub Copilot 渠道（`packages/core/src/github-copilot/`），构成"消费 Copilot + 服务 ACP"的双向互操作。

**证据强度**：服务接口与实现源码为静态事实；与真实 ACP 宿主的互通未运行验证。

## 已归并到现有类目的能力

| 能力 | 归并去向 |
|---|---|
| build/plan/general Agent、`agent create` | Agent 角色类目 |
| Git 快照 + 会话级撤销/回退（`snapshot/index.ts` track/restore/revert/diff、`session/revert.ts`、step 边界快照） | 统计 F24"文件/Git/diff 事实源与模型回读、回滚闭环"的既有 OpenCode 主贡献 |
| 后台子代理 + 任务续作（`tool/task.ts`、`background-job.ts` promote/extend） | Agent 工具类目（F30 子 Agent） |
| Skill 市场（`skill/discovery.ts`）、权限规则集与 question 对话框、命令系统（/init、/review、自定义命令） | Agent 工具、Chat UI 类目 |
| GitHub Copilot 渠道、多 Provider | LLM 渠道类目 |
| V2 事件溯源会话核心（Context Epoch、压缩 checkpoint、durable admission inbox） | 会话消息与对话请求/上下文类目；实现深度作为工程机制单独标注 |

## 声明不符、外部依赖与暂缓项

- **Session Review（`入口确认`）**：`packages/session-ui` 的 review 组件、行内评论与 `review.txt` 模板存在，但"评论→驱动修改"的端到端服务端闭环未逐点核对，本轮不提案。
- **cloud/enterprise 面**（`packages/console`、`control-plane` 服务端侧）：本轮只核到客户端握手与同步层（sessionWarp/startWorkspaceSyncing），云端托管细节标外部服务边界，不进入本仓库特色计数。
- **worktree 隔离工作区**：作为能力一的支撑机制记录（远程 workspace 适配器），不单独提案。

## 对特色贡献统计的影响

- **主贡献候选**：能力一"多表面会话连续性"（`主链确认`，静态证据）。统计 F27"TUI、Desktop、Web 共用同一 Agent 会话后端"已有 OpenCode 主贡献，其计入理由应扩充为包含事件源同步与所有权接管（steal）机制。
- **新能力族建议**：能力二 CodeMode（受限 JS 工具编排，独立执行范式）与能力三会话档案闭环（"研究轨迹"聚类第三样本）建议作为新能力族进入重做后的统计（待查清单全局待办第 6 条一并处理）；能力四 ACP 服务端建议计辅助贡献（反向互操作）。
- **不重复计数**：Git 快照回退（F24 既有主贡献）、后台子代理（F30 既有辅助贡献）、Skill/权限/渠道归并项。
- 统计表重排待[待查清单](待查清单.md)全局待办第 6 条（按"产品特性贡献"与"机制贡献"拆分重做）一并处理，本笔记仅登记建议。

## 未验证事项

- 全部能力均未运行验证：多设备 steal/重放、mdns 局域网发现、云端 workspace 同步、CodeMode 真实模型编排、分享服务与 PR 续作、与真实 ACP 宿主互通。
- Session Review 的"评论→修改"服务端闭环未逐点核对；worktree 作为云 workspace 适配器的资源回收语义未展开。
- 事件溯源会话核心（Context Epoch/压缩 checkpoint）与现有"对话请求与上下文"笔记的交叉核对未完成，机制深度待后续标注。

## 关键源码索引

- `packages/core/src/event/sql.ts`（4-23 event_sequence/event 表与 owner_id）、`packages/core/src/session/`（input.ts、store.ts、context-epoch.ts、projector.ts、compaction.ts、execution/、runner/）
- `packages/opencode/src/server/routes/instance/httpapi/handlers/sync.ts`（34 replay、61 steal、87 start/steal/history 组合）、`packages/opencode/src/server/server.ts`、`server/mdns.ts`、`packages/opencode/src/sync/README.md`
- `packages/opencode/src/cli/cmd/serve.ts`、`cli/cmd/attach.ts`、`cli/cmd/web.ts`、`packages/desktop/src/main/sidecar.ts`、`packages/app/src/wsl/dialog-add-server.tsx`、`packages/tui/src/context/sync.tsx`
- `packages/opencode/src/control-plane/workspace.ts`（sessionWarp、startWorkspaceSyncing）、`control-plane/adapters/worktree.ts`、`packages/opencode/src/worktree/index.ts`
- `packages/codemode/`（codemode.ts、tool.ts、tool-runtime.ts、tool-schema.ts）、`packages/opencode/src/tool/code-mode.ts`
- `packages/opencode/src/cli/cmd/export.ts`（163 sanitize、222 ExportCommand）、`cli/cmd/import.ts`（28 parseShareUrl、60 transformShareData）、`cli/cmd/pr.ts`、`share/share-next.ts`、`packages/app/src/utils/session-export.ts`
- `packages/opencode/src/acp/service.ts`（56-61 接口、94-488 实现）、`acp/permission.ts`、`cli/cmd/acp.ts`、`packages/core/src/github-copilot/`
- `packages/opencode/src/snapshot/index.ts`、`session/revert.ts`、`session/summary.ts`、`tool/task.ts`、`core/background-job.ts`
- `packages/session-ui/src/v2/components/session-review-v2.tsx`、`packages/opencode/src/command/template/review.txt`
