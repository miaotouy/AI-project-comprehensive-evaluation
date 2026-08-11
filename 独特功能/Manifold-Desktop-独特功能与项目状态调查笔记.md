# Manifold Desktop 独特功能与项目状态调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：汇总现有十类单项目调查，复核当前源码与 Git 历史，并通过远端引用和 GitHub API 核对仓库、Release 与 Actions 状态；未在本机重新构建或运行
>
> 调查范围：README 特色声明、基础 Chat 与工具主链闭合程度、独特功能候选、提交与发布活动；不判断作者动机、项目未来计划或代码生成来源
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Manifold Desktop 当前更适合视为一个**能够通过编译验证、但关键产品主链没有接通的实验性概念原型**，而不是已经形成可持续使用闭环的 AI 客户端。README 自身也把项目标为 `Experimental`。十类调查使用的都是远端当前 `main` 快照，并非旧笔记遗漏了后续修复。

本轮没有确认可进入特色贡献统计的独特能力。原因也不是项目缺少功能名称：README 同时声明多 Provider、双模型比较、ConPTY 终端、MCP、会话管理、成本统计和 DLL 插件。问题在于最基础的 Chat 连续性已经断开，多个高级功能又停留在入口、类型或局部执行器层：

- 新对话不持久化，关闭标签后内容丢失；已有会话的重命名还可能用只有标题的 JSON 覆盖原文件。
- assistant 流式回复只进入 DOM，不回写 `messages[]`，下一轮请求缺少上一轮 assistant 上下文。
- 常规 Chat 的流式事件没有会话标识，多个打开标签可能同时消费同一结果。
- MCP 能发现工具并把 schema 发给模型，但模型返回的 tool call 只渲染，不调用已经存在的 `MCPClient::CallTool()`。
- 插件声明了 Provider、Tool 和 Tab 注册接口，但没有 `PluginContext` 实现，加载流程也不调用 `IPlugin::Initialize(context)`。

因此，“概念壳子”可以作为口语概括，但更精确的记录是：**仓库存在真实的原生宿主、Provider、终端、MCP 传输和前端实现，也能在 CI 中编译；产品说明覆盖面明显大于当前已接通的端到端行为。**

## 仓库活动与维护状态

截至 2026-08-11，远端 `main` 仍指向 `3d7448f`，与本地调查快照一致：

| 指标 | 当前观察 |
|---|---|
| 仓库创建 | 2026-03-20 |
| 提交总数 | 11 |
| 有提交活动的时间窗 | 2026-03-20 至 2026-04-09，共约三周 |
| 最后非文档提交 | 2026-04-03，`release: Manifold Desktop v0.2.0` |
| 最后一次提交 | 2026-04-09，只修改 README，加入 B2B 咨询信息 |
| 作者分布 | 两个 author name，共用同一邮箱；10 + 1 个提交 |
| Release | 仅 `v0.2.0`，2026-04-03 发布，无二进制资产 |
| GitHub Actions | 5 次 `Build Verification` 均成功，最后一次对应当前 HEAD |
| 自动化测试 | 仓库没有显式测试树；工作流只做 NuGet restore、Debug x64 编译和产物上传 |
| GitHub 仓库状态 | 未设置 `archived` 或 `disabled`；0 个 fork，2 个 star，0 个公开 open issue |

这些数据支持“**短期集中开发后进入长期低活跃状态**”的结论。截至调查日，最后一次代码变更距今约四个月。不过，仓库没有被作者正式归档，README 仍写有“欢迎反馈和贡献”，所以不能把“无人维护”“已放生”记录为已确认事实。更稳妥的状态标记是：`长期低活跃，未正式归档，后续维护意图未确认`。

## 介绍声明与候选盘点

| README 声明 | 状态 | 当前实现判断 | 特色统计处理 |
|---|---|---|---|
| 多 Provider 与统一聊天 | `归并已有类目` | Provider 注册和流式请求存在，但基础会话连续性未闭合 | 普通 Chat 底座，不计特色 |
| 双模型并排比较 | `入口确认` | 有独立 Compare UI、并发线程、按 slot 回传和成本显示；现有调查未运行验证，也没有形成持久比较对象 | 暂不计入 |
| 集成 ConPTY 终端 | `入口确认` | 终端有独立 tabId、输入、输出、resize 和进程回收链；没有接入模型或 Agent 工作流 | 属人类工具页，不作为 Agent 独特贡献 |
| MCP Client | `声明不符` | 工具发现和 schema 注入存在，执行与结果回流没有接通 | 不计入 |
| DLL 插件系统 | `声明不符` | 加载器和接口存在，初始化上下文与工具注册主链没有接通 | 不计入 |
| 会话保存、搜索、导入导出 | `声明不符` | 文件管理器存在，但正常聊天不调用保存模块；重命名存在整文件覆盖风险 | 不计入 |
| 成本与 token 跟踪 | `入口确认` | Compare 完成事件展示 token 与静态模型价格估算，未形成会话级事实源 | 普通度量，不计特色 |
| 安全凭据存储 | `归并已有类目` | Windows Credential Manager 路径已确认 | 通用渠道基础设施，不计特色 |

双模型比较和终端是仓库中相对完整的局部能力，但目前不宜把它们提升为项目级特色贡献：前者尚未运行确认且不保存比较结果，后者是独立的人类终端，没有与模型输出、工具审批或项目事实源形成闭环。

## 基础主链断点

### 会话与上下文

前端实际使用 `chat-tab.js` 闭包内的 `messages[]`，而实现 `createSession()`、`addMessage()`、`updateModelMessage()` 和 `save()` 的 `session-store.js` 没有导入方。assistant 流式内容只累积到 `streamingText` 和 DOM，`getMessages()` 返回的数组因而不含上一轮 assistant 回复。详细证据见[Chat 概览](../Chat/Manifold-Desktop-Chat调查笔记.md)、[会话与消息管理](../会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md)和[对话请求与上下文](../对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md)。

普通多轮 Chat 的状态闭环尚未成立。即使单次 Provider 请求能够返回文本，关闭、恢复、续聊和多标签隔离仍没有形成一致语义。

### MCP 与插件

`MCPClient::CallTool()` 已有实现，但全仓库没有运行时调用点；模型工具调用在 Provider 层解析后只作为流式块发给前端。`maxToolCallRounds` 和 `ToolResult` 也没有进入执行循环。插件侧则缺少 `PluginContext` 实现，`PluginManager::LoadEnabled()` 不调用插件初始化方法。详细证据见[Agent 工具调查](../Agent工具/Manifold-Desktop-Agent工具调查笔记.md)。

这两项都属于“接口和局部构件存在，产品主链未接通”，不能因为 README 列出 MCP 或 Plugin 就计为特色贡献。

### 输出与恢复

模型输出没有稳定 ID、对象类型、版本、编辑器、沙箱或持久化生命周期。当前能力停留在 Markdown 消息 DOM，且助手输出不回写上下文、不写入会话文件。生成式运行时专项将其评为 G0，详见[生成式输出与运行时调查](../生成式输出与运行时/Manifold-Desktop-生成式输出与运行时调查笔记.md)。

## 构建成功不等于产品主链成立

仓库的 GitHub Actions 在 Windows runner 上恢复 NuGet 包并执行 Debug x64 编译，当前 HEAD 的构建结果为成功。这说明工程至少能够通过该编译步骤，不能描述为“项目完全跑不起来”。

该工作流没有单元测试、集成测试或端到端 UI/Provider 测试。编译器无法发现未被调用的 `session-store.js`、没有消费方的 `CallTool()`、缺失的插件初始化，以及跨标签广播缺少会话标识等连接问题。因此现有证据可以同时成立：**构建通过，但产品关键流程未闭合。**

本机没有可直接调用的 `msbuild` 和 `nuget`，本轮未重新构建或启动 GUI；视觉表现、真实 Provider 单轮返回、Compare 并发和 ConPTY 终端行为仍以静态入口确认或远端编译记录为界。

## 关于“AI 生成”的证据边界

仓库历史具有短时间集中提交、多个 `Add files via upload`、README 功能声明密集而连接代码不足等特征。这些现象可以说明项目更像一次性集中产出的原型，但不能可靠证明源码由 AI 生成，也不能据此判断具体工具、生成比例或作者投入方式。目前可观测的直接AI生成内容是 README 中的图片和应用图标，具有典型的AI生成图像特征。

因此本笔记不使用“AI 生成项目”作为事实结论。可验证的结论只到：实现呈现明显的概念先行和集成未完成状态，且缺少后续迭代把局部构件收口为可持续产品。

## 对特色贡献统计的影响

- Manifold Desktop 保持 **0 个已确认特色功能族、0 特色点**。
- 这个结果来自当前 HEAD 上十类调查和本专项复核，不再属于“笔记覆盖不足”或“README 尚待扫描”。
- 双模型比较保留为 `入口确认` 候选；只有运行验证、结果归属和持久化语义补齐后，才重新判断是否可形成特色能力卡。
- 终端作为独立人类工具存在，但未与 Agent 或项目工作区形成闭环，不在当前特色口径下计分。
- 后续只有远端出现新的代码提交或发布时，才需要重新打开本项目调查；单纯 README 文案变化不触发重新计分。

## 关键证据索引

- `README.md`：`Experimental` 状态、功能声明、v0.2.0 changelog 和构建说明。
- `.github/workflows/build.yml`：只恢复依赖、编译 Debug x64、上传短期构建产物。
- `frontend/components/chat-tab.js`：局部消息数组、流式 DOM 更新和全局事件监听。
- `frontend/services/session-store.js`：存在但未接入的会话保存实现。
- `frontend/components/side-panel.js`：只含标题的 `SAVE_SESSION` 调用。
- `MainWindow.xaml.cpp`：Chat、Compare、Terminal、Session、MCP 与插件的宿主消息分发。
- `Manifold.Core/MCP/MCPClient.cpp`：无运行时调用方的 `CallTool()`。
- `Manifold.Core/Plugins/PluginManager.cpp`、`PluginContext.h`：插件加载状态与缺失的初始化上下文实现。
- Git 历史与远端 `main`：11 个提交、最后代码提交 2026-04-03、当前 HEAD 2026-04-09。
- GitHub API：仓库未归档；1 个无资产 Release；5 次构建工作流均成功。
