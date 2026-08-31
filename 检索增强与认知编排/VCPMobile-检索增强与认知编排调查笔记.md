# VCPMobile 检索增强与认知编排调查笔记

> 调查对象：`https://github.com/MRiecy/VCPMobile`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`cecdbe432feda57821938bba7625a272113d21c1`（分支：`main`）
>
> 调查方式：只读静态源码核对，覆盖 VCPInfo WebSocket 监听、内存缓存、元数据提取和观察器界面；未连接 VCPInfo 服务
>
> 调查范围：移动端对远端检索/记忆/思维活动的可观察性；不把远端事件的语义当成移动端本地索引、查询或记忆写回实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 没有本地文档摄取、Embedding、向量索引、候选重排或记忆写回链。它实现的是一个 VCPInfo 观察面：连接远端 WebSocket，筛选并缓存远端推送的检索、元思考链、记忆回溯和梦境等事件，供用户展开查看原始 JSON。按本项目自身实现，它属于“外部生态证据的只读可观测层”，而不是可与本地 RAG 管线直接比较的检索实现。

远端事件中的 `META_THINKING_CHAIN`、`AI_MEMO_RETRIEVAL`、`AGENT_DREAM_*` 等字段能说明上游声称发生了多阶段思考、记忆召回或主动维护；VCPMobile 只负责命名、摘要、缓存和展示，未计算这些结果，也不把它们注入本地聊天请求。

## 谱系定位与系统边界

```text
VCPLog URL/Key 设置变更
  -> /vcpinfo WebSocket（URL 含 VCP_Key）
  -> 接收远端 JSON 事件
  -> 提取可展示 metadata，Zstd 压缩原载荷
  -> 内存 FIFO（最多 500 条）和 Tauri 事件
  -> RagObserver 元数据列表 -> 按 ID 请求详情 -> 展示
```

设置运行时重协调会用 `vcp_log_url/vcp_log_key` 初始化 VCPInfo 连接；没有这些值时监听器关闭。`src-tauri/src/vcp_modules/infra/settings_manager.rs:314-351,354-390`，`src-tauri/src/vcp_modules/infra/vcp_info_service.rs:102-135`。

## 1. 事实对象与结果契约

移动端的事实对象不是文档片段或向量，而是远端 JSON 通知及其本地 metadata。metadata 带 ID、类型、标题、摘要、时间和“是否有详情”；完整载荷按 ID 存为 Zstd 压缩字节。`src/core/stores/ragObserver.ts:6-16,26-65`，`src-tauri/src/vcp_modules/infra/vcp_info_service.rs:51-99,386-430`。

元数据提取器识别私聊预览、元思考链、记忆回溯、DailyNote 和 Agent 梦境系列事件。例如元思考链读取阶段数、K 序列、激活分组和查询文本；记忆回溯读取日记/文件数量、模式和 TagMemo chunk 数。这些字段是远端消息的展示契约，不是 VCPMobile 对检索算法的实现证据。`src-tauri/src/vcp_modules/infra/vcp_info_service.rs:433-555`。

## 2. 连接、缓存与可观测性

监听器把 URL 改写为 `/vcpinfo` 并附加 Key，连接失败或断开会从一秒开始指数退避、最高六十秒。前台状态下才向 Vue 发事件。原始消息经 Zstd 压缩后放进内存队列，容量超过 500 时按 FIFO 同时删除 metadata 和载荷；清空操作也只清除内存。`src-tauri/src/vcp_modules/infra/vcp_info_service.rs:34-49,137-383,386-430`。

观察器 store 初始读取连接状态和已有 metadata，再监听 Tauri 事件；需要详情时才按 ID 解压并 JSON 解析。界面是全局 overlay 的异步视图。`src/core/stores/ragObserver.ts:75-134`，`src/components/FeatureOverlays.vue:26-32,90-100`。

## 3. 已确认边界与未验证事项

- 本地未找到文档上传、切块、Embedding、向量库、关键词/BM25、rerank、查询改写、阶段控制或检索结果注入聊天上下文。
- 本地未找到把观察到的记忆/梦境操作批准、修改或写回远端的命令；清空只影响移动端内存缓存。
- 未连接远端 VCPInfo，尚不能确认事件生产条件、字段完整性、上游作用域/权限、查询预算或远端记忆写回的真实语义。

## 关键源码索引

- `src-tauri/src/vcp_modules/infra/vcp_info_service.rs`：VCPInfo 连接、事件筛选、Zstd 内存缓存和 metadata 提取。
- `src/core/stores/ragObserver.ts`：前端读取、按需详情和事件订阅。
- `src/components/FeatureOverlays.vue`：RAG 观察器的应用入口。
