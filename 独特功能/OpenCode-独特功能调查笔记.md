# OpenCode 独特功能调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：只读通读根 README、包结构与核心模块；对候选功能逐一核对入口、状态、执行与持久化主链；未运行应用
>
> 调查范围：多端会话连续性与服务守护、GUI 插件体系、Code Mode、目标模式、会话档案、Artifact 托管、ACP、持久终端、语音与定时任务等候选能力的入口与主链；与既有十类笔记重复的能力只做归并说明
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

当前仓库的独特性集中在"可被外部驱动的工作台"这一形态：服务端是唯一事实源，事件以 durable 日志持久化并经 SSE 广播，客户端（Web、桌面、TUI，或第三方）通过配对与服务守护连接同一个服务端；桌面与 Web 的非外壳功能全部由 GUI 插件提供，第三方插件与内建插件使用同一套 SDK。此外有三条自成体系的执行范式：受控解释器里的 Code Mode、带判定与续跑的 Goal 模式、以及独立托管的 Artifact。

按证据状态盘点：

| 候选 | 证据状态 | 结论 |
|---|---|---|
| 多端会话连续性与服务守护（事件日志 + SSE + 配对 + service 命令） | 主链确认 | 见能力一 |
| GUI 插件体系（所有非外壳界面即插件） | 主链确认 | 见能力二 |
| Code Mode 受限编排（`execute` 工具） | 主链确认 | 见能力三 |
| Goal 模式（目标 + 判定 + 自动续跑） | 主链确认 | 见能力四 |
| 会话档案（导出/导入/分享） | 主链确认 | 见能力五 |
| Artifact 托管（静态与服务端能力 Provider） | 主链确认 | 见能力六 |
| ACP 服务端（被外部 Agent 客户端驱动） | 主链确认 | 见能力七 |
| 持久终端守护（PTY 进程跨连接存活与重放） | 入口确认 | 归入生成式输出与运行时类目 |
| 语音会话（实验性模型与会话端点） | 入口确认 | 客户端为实验性入口，未展开 |
| 定时任务（schedule 工具与端点） | 入口确认 | 与后台任务同属执行调度，未展开 |
| Git worktree 隔离工作区 | 入口确认 | 工具与目录管理存在，支撑多工作区形态 |
| Skill 机制、权限规则集、命令系统、多 Provider 渠道 | 归并已有类目 | 见 Agent 角色/工具/LLM 渠道笔记 |

## 能力一：多端会话连续性与服务守护 — 主链确认

**用户目标**：多个客户端（桌面、浏览器、TUI、远程机器）连同一个服务端，共享会话与正在进行的任务；客户端断线重连后按事件续播，而不是各自保存一份状态。

**入口与触发**：`opencode serve` 启动 HTTP 服务；`opencode service start/status/stop` 管理常驻服务；客户端经配对端点建立信任并连接（`/api/pair`、配对连接端点），App 的服务端注册表可同时保存多个服务端并在其间切换。

**事实对象**：事件表以聚合 id 与 seq 记录 durable 事件，事件序列行带 owner id（`packages/core/src/event/sql.ts`），写入时由 Bus 校验聚合、序号与所有权（`packages/core/src/bus.ts` 的提交路径）。

**主链**：客户端发起请求 → 服务端把变化写成 durable 事件并投影落库 → SSE `/api/event` 广播（`packages/server/src/event-feed.ts` 的订阅与背压控制）→ 客户端投影 store。断线后重连继续订阅；同一聚合的写入者由 owner 约束，重放时校验一致性。

**持续性**：事件日志与 SQLite 持久化是唯一事实源；服务端进程可重启并由服务命令管理；客户端不持有权威状态。

**已验证边界**：本次未找到旧版的 `/sync` 重放与所有权接管（steal）端点，取而代之的是事件流订阅、配对与服务守护；跨机器共享依赖客户端能访问服务端地址。

## 能力二：GUI 插件体系 — 主链确认

**用户目标**：桌面与 Web 的功能（终端、审查、文件、浏览器、SSH、WSL、更新器等）与第三方扩展走同一套插件接口，可独立开发、测试与加载。

**入口**：`packages/plugin/src/gui` 提供窗口进程 SDK，`main` 子路径提供主进程 SDK，`host` 与 `builtin` 为宿主专用；内建插件在 `packages/gui-plugins/`（终端、浏览器、审查、来源、文件、SSH、WSL、更新器等）。

**对象与主链**：插件以 `Plugin.define` 声明能力、存储与多语言资源；窗口侧入口导出 `Plugin.Setup`，向注册表 `ctx.add(Registry, item)` 注册界面项；主进程侧通过 IPC 暴露方法、状态与事件（schema 走桥接校验）。宿主在启动时组装内建插件与第三方插件，插件间通过 contract token 互通。

**持续性**：插件状态分窗口内存、宿主存储与主进程状态三层；更新与安装走插件管理命令。

**已验证边界**：本能力覆盖"界面即插件"的结构，插件市场的安装分发细节未展开。

## 能力三：Code Mode 受限编排 — 主链确认

**用户目标**：模型用一小段受限程序一次编排多个工具调用，减少多轮往返。

**入口与主链**：工具名 `execute`（`packages/core/src/codemode/tool.ts`），程序在 `packages/codemode` 的解释器中运行；解释器只实现受控语法，程序只能调用宿主暴露的工具与扩展全局对象，无法触网、读写文件或访问进程；宿主限制执行时间、工具调用次数、输出大小与数据量；未完成工作在程序结束时被中断。

**已验证边界**：这是受控解释器而非沙箱化 JavaScript；错误以带位置的诊断返回。

## 能力四：Goal 模式 — 主链确认

**用户目标**：给会话设一个长期目标，模型在多次回合中朝目标推进，直到判定完成或用户暂停。

**入口与主链**：斜杠命令 `/goal <objective> | pause | resume | clear`；目标状态存在插件存储中（active/paused/complete），RPC 提供读取与设置。插件在目标激活时注入 kickoff、提醒与续跑提示，回合结束时调用判定提示判断是否完成；即使模型停顿，只要目标活跃且有继续空间，就会自动开启下一轮；服务端进程更换后，先前进程布防的目标以暂停状态恢复而不是自行继续。

**已验证边界**：判定由模型完成，存在误判可能；目标属于会话私有存储，子会话与 fork 不继承。

## 能力五：会话档案 — 主链确认

**用户目标**：把会话导出为可分享的档案、在其他实例导入、并让分享链接持续同步。

**入口与主链**：实验性端点 `session.export` 与 `session.import`（服务端处理器），客户端有导出命令与会话命令入口；导出包含消息与元数据，可带脱敏选项；导入按导入协议重建会话。

**已验证边界**：导出不含 Artifact 与工具输出落盘文件；脱敏规则只覆盖已知敏感字段；本次未找到实时分享同步的服务端模块（会话表仅保留遗留的分享地址列）。

## 能力六：Artifact 托管 — 主链确认

**用户目标**：模型产出一个可访问的小型产物（页面、图表、交互文档），用户可打开并复用。

**入口与主链**：`artifact` 工具创建/读取/更新/删除 Artifact（`art_` 前缀），Artifact 是一组相对路径到文本的文件映射加入口文件；Artifact Provider 声明能力（静态、服务端代码、SQLite、Durable Objects），本地 Provider 默认可用；实验性端点列出 Provider、管理 Artifact 并提供按路径访问的视图。

**已验证边界**：能力面由 Provider 决定，本地默认 Provider 只做文件托管；本次未找到容器化运行环境。

## 能力七：ACP 服务端 — 主链确认

**用户目标**：让其他 Agent 宿主客户端（编辑器或终端里的 ACP 客户端）驱动 OpenCode 会话。

**入口与主链**：`opencode acp` 命令启动 ACP 服务端（`packages/cli/src/commands/handlers/acp.ts`）；服务端把 ACP 的会话、消息、工具调用与权限请求映射到内部会话与执行链，权限请求经 ACP 协议回到宿主客户端。

**已验证边界**：只核对了入口与映射层，外部宿主客户端的实际互通未运行验证。

## 已归并与未展开的候选

- **持久终端守护**：PTY 进程由独立守护进程持有，连接断开后仍存活并可在重连时按偏移重放输出；归入生成式输出与运行时的执行环境部分。
- **语音**：实验性语音模型与会话端点存在，App 有语音上下文；本次未展开实时语音链。
- **定时任务**：schedule 工具与端点支持创建、暂停、恢复任务；与后台任务同属执行调度。
- **worktree**：工具与目录管理支持创建/列出/删除 worktree，用于隔离工作区。
- **已归并**：Agent 角色、工具审批、LLM 渠道、消息渲染、会话档案外的会话管理细项分别属于既有类目。

## 未验证事项

1. 多端连接在真实网络（远程机器、WSL、局域网）下的配对、重连与事件续播未实测。
2. GUI 插件在第三方插件加载、版本兼容与主进程桥接异常时的行为未验证。
3. Code Mode 与 Goal 模式的真实运行效果、判定准确度与限额行为未实测。
4. Artifact 不同 Provider 的能力差异与预览隔离未验证。
5. ACP 与外部宿主客户端的互通未实测。
6. 导出/导入在旧版本档案与脱敏边界上的表现未验证。

## 关键源码索引

- `packages/core/src/bus.ts`、`event/sql.ts`：durable 事件与所有权
- `packages/server/src/event-feed.ts`：SSE 事件流
- `packages/protocol/src/groups/{event,server}.ts`：事件订阅与配对端点
- `packages/cli/src/commands/handlers/{serve,service,pair,acp}.ts`：服务与配对入口
- `packages/plugin/src/gui/`、`packages/gui-plugins/`：GUI 插件 SDK 与内建插件
- `packages/codemode/`、`packages/core/src/codemode/tool.ts`：Code Mode
- `packages/core/src/plugin/goal.ts`、`packages/schema/src/goal.ts`：Goal 模式
- `packages/server/src/handlers/session.ts`、`packages/cli/src/commands/handlers/session/{export,import}.ts`：会话档案
- `packages/core/src/artifact.ts`、`packages/protocol/src/groups/artifact.ts`：Artifact
- `packages/core/src/persistent-pty/`、`packages/protocol/src/groups/persistent-pty.ts`：持久终端
