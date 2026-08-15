# VCPToolBox 外部执行体与应用协作调查笔记

> 调查对象：`E:\works\git\VCPToolBox`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`1ae9b63c5afcea7677db5d71e5cf561a0f5debd9`（分支：`main`）
>
> 调查方式：静态复核 AICodeWorker、SSH/WebSocket 节点、跨节点文件、浏览器 runtime、异步回注、人类工具 API 与 MCP 客户端插件；复用 Agent 工具、运行时和独特功能笔记；未启动外部服务
>
> 调查范围：VCPToolBox 作为外部执行资源编排与能力供给层；排除普通模型协议桥、仅一次函数调用的插件和 VCPChat 前端产品面
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 不是统一桌面 Agent 控制台，但已经形成多条可比较的外部协作主链：AICodeWorker 调度 opencode/Antigravity CLI；WebSocket 节点与 SnowBridge 承担远端工具和文件；SSHManagerService 执行远端设备；托管浏览器暴露页面观察/控制；异步插件把长任务结果回注原会话；`/v1/human/tool` 允许外部人类客户端走统一工具审批。综合达到 `主链确认`（静态证据）。

## 接入角色与系统边界

| 外部对象 | 角色 | 宿主持有状态 |
|---|---|---|
| opencode / Antigravity(agy) CLI | 外部执行体 | jobId、worker 类型、模式、工作目录、进程、结果文件、共用并发闸门 |
| SSH 远端主机 | 外部执行体 | hosts.json 配置、连接池、预热、会话流 |
| WebSocket node / SnowBridge | 外部执行节点 | client/node id、能力、在途调用、文件来源与取消 |
| managed Chrome | 外部应用/运行环境 | browser runtime、页面、动作、截图和验证结果 |
| MCP 服务与外部数据源 | 可操作外部能力 | 插件配置、请求与结果；缺少统一账号目录 |
| VCPChat/人类客户端 | 外部控制表面 | Bearer 请求、工具调用、审批与结果 |

## 完整主链

```text
AICodeWorker 请求
  -> 创建 jobId，选择 analyze/patch/write 与 worker 类型
  -> spawn opencode 或 antigravity(agy) CLI（共用并发闸门）
  -> 保存进度/结果
  -> 查询 job 或异步回注调用方

远端工具/文件
  -> WebSocket node 注册能力
  -> 服务端分派 tool call
  -> 节点回传事件或文件来源
  -> FileFetcher 按来源透明拉取、缓存
  -> cancel_tool 传播到节点并清理在途状态

托管浏览器
  -> BrowserRuntimeManager 启动/选择 Chrome
  -> ChromeBridge 执行页面动作、快照、图片和验证
  -> 结构化结果回工具调用

SSH 远端主机
  -> SSHManagerService 按 hosts.json 连接池预热
  -> connect/execute/disconnect 会话流回工具调用
```

## 身份、协议与状态映射

AICodeWorker 使用 jobId 管理异步 CLI 任务。分布式节点以 WebSocket client identity 与能力注册，文件带来源信息，避免服务端把远端路径误当本地文件。浏览器 runtime 有独立生命周期与可选人工选择。异步插件通过回调 id 将结果重新注入原会话。

## 执行、回流与控制语义

外部执行结果可同步返回、轮询 job、WebSocket 推送或经 `{{VCP_ASYNC_RESULT}}` 占位符回注。各接入路径的回流与取消语义如下：

- 跨节点：`cancel_tool` 传播；SnowBridge 另有 `vcp_tool_status/result/cancel_ack` 帧
- 浏览器：返回页面快照、截图和动作结果
- SSH：按会话流返回输出
- 人类工具 API：复用 Bearer 鉴权和审批链（鉴权在 `/v1/*` 全局中间件层）

AICodeWorker 的取消、SSH 会话中断与断线竞争语义未运行验证。

产品表面（dashboard/管理面板）显示节点连接、任务面板与工具审批请求；执行位置（本地/节点/SSH 主机/浏览器）按接入点分别展示，无统一连接管理页。外部输入按不可信处理：工具调用统一过 `toolApprovalManager`，文件请求有速率与并发限制，浏览器限制在 localhost 绑定范围，但私网/云元数据地址防护本次未在 `browserRuntimeManager` 中找到，不构成已确认的安全边界。

## 权限、凭据与治理边界

不同接入点的治理并不统一，逐项对照如下：

| 接入点 | 鉴权/治理 |
|---|---|
| 工具审批（全局） | `toolApprovalManager` + `toolApprovalConfig.json` 的 `approveAll`/`approvalList`/`SilentReject` 策略；`/v1/human/tool` 只是触发源，审批请求经 WebSocket 广播到管理面板 |
| 人类工具 API | Bearer 鉴权 |
| 浏览器 runtime | 默认关闭、绑定 localhost，managed token 可刷新；私网/云元数据限制未确认 |
| WebSocket 节点 | 依赖服务端连接身份，SnowBridge 另有 bridge access token |
| SSH | 凭据按主机配置保存，刷新与作用域未验证 |
| MCP/邮箱/外部检索插件 | 各自保存配置 |

不能将这些插件推断为 LobeHub 式统一 Connector 账号系统。

## 相邻类目交接

- 插件发现、执行、审批和分布式工具细节见[Agent 工具笔记](../Agent工具/VCPToolBox-Agent工具调查笔记.md)。
- AICodeWorker、MediaRenderer 和文件产物见[生成式输出与运行时笔记](../生成式输出与运行时/VCPToolBox-生成式输出与运行时调查笔记.md)。
- 浏览器、跨节点文件、异步回注和插件盘点见[独特功能笔记](../独特功能/VCPToolBox-独特功能调查笔记.md)。

## 已确认边界与未验证事项

- 多条链均为插件或后端能力，不代表存在统一前端连接管理体验。
- AICodeWorker 的 opencode/Antigravity 版本兼容、真实取消与工作区写入未运行验证；SSH 会话与 SnowBridge 断线语义未验证。
- managed browser 默认关闭；登录态、Profile 隔离、私网/云元数据防护和真实页面安全行为未验证。
- WebSocket 节点断线、重连、在途文件与取消竞争未运行验证。
- `/plugin-callback` 的来源绑定边界已在独特功能笔记记录，本页不作安全审计结论。

## 关键源码索引

- `Plugin/AICodeWorker/`
- `Plugin/SSHManagerService/SSHManagerService.js`
- `Plugin/SnowBridge/index.js`
- `WebSocketServer.js`
- `FileFetcherServer.js`
- `modules/browserRuntimeManager.js`
- `modules/toolApprovalManager.js`
- `Plugin/ChromeBridge/`
- `Plugin.js`
- `modules/messageProcessor.js`
- `server.js`
- `Plugin/DeepWikiVCP/`
