# Jan Agent 角色配置调查笔记

> 调查对象：`https://github.com/janhq/jan`（重点 `core/src/types/assistant/assistantEntity.ts`、`extensions/assistant-extension/src/index.ts`、`core/src/types/thread/threadEntity.ts`、`web-app/src/lib/instructionTemplate.ts`）
>
> 调查更新日期：2026-08-11
>
> 代码快照：`fad3f12a147d138388a66f0d92a02b2675f65294`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 Jan 仓库
>
> 调查范围：Assistant 数据模型、文件持久化与迁移、默认助手、线程绑定、指令模板、设置 UI
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Jan 的“角色”即 `Assistant` 实体：**每个助手一个目录一个 JSON 文件**（`file://assistants/<id>/assistant.json`），由 assistant-extension 负责增删改查与版本迁移（当前 v3）。默认助手 id 固定为 `jan`，`model: '*'` 表示任意模型，指令模板内置语言跟随、分步思考、“专业工具调用者”与 `{{current_date}}` 占位符。

关键事实：

1. 两侧 `Assistant` 类型不一致：core 侧含 `model`、`instructions?`、`tools?`、`file_ids`，web 侧含 `parameters` 且无上述字段（完整字段对照见 §1.1）。
2. 迁移 v2 写入 Menlo Research 指令与 `DEFAULT_PARAMETERS = {temperature:0.7, top_k:20, top_p:0.8, repeat_penalty:1.12}`；迁移 v3 去掉身份前缀。
3. 线程绑定保存“嵌入快照”，不持有引用：`ThreadAssistantInfo` 把 name/model/instructions/tools 拷贝进 thread；无助手时写入 `{id:'model-only', name:'Model'}`。
4. system prompt 由 `renderInstructions(threadAssistant.instructions)` 生成，`{{current_date}}` 用 UTC 长月份替换；线程有助手且非 `model-only` 时才采用其推理参数。
5. 默认助手带一个 `type:'retrieval'` 且 `enabled:false` 的工具定义（top_k=2、chunk_size=1024、chunk_overlap=64、retrieval_template）——RAG 工具能力挂靠在助手工具声明上。

## 总体生效链路

从角色选择到请求的完整链路（静态确认）：

```text
AssistantSwitcher / AssistantsMenu 选择助手
  -> updateCurrentThreadAssistant（web-app/src/hooks/useThreads.ts:362-379）
      写入线程快照 assistants: [{...assistant, model: 线程当前模型}]
  -> $threadId.tsx:205-208 读取 thread.assistants[0]
      systemMessage = renderInstructions(threadAssistant.instructions)
  -> CustomChatTransport.sendMessages 拼接 system + 上下文
      （web-app/src/lib/custom-chat-transport.ts:1229-1240，见 Chat 笔记 §3.2）
```

- 快照语义：切换助手改写线程内嵌快照，不动全局 assistant 对象；`SamplerPopover.tsx:106` 在线程内编辑参数时同样走 `updateCurrentThreadAssistant`。
- 无助手（`model-only`）时 `instructions` 为空、systemMessage 为 undefined，请求不带助手指令（threads/default.ts:86-91）。
- 生效边界：指令与推理参数走线程快照；助手的 `model:'*'` 与模型能力（tools/vision）的运行时解析关系未逐项核对（见 §6 未验证）。

## 1. 数据模型

`core/src/types/assistant/assistantEntity.ts`：

```text
Assistant {
  avatar, thread_location,
  id, object, created_at,
  name, description?,
  model, instructions?,
  tools?: AssistantTool[],
  file_ids, metadata?
}
AssistantTool { type, enabled, useTimeWeightedRetriever?, settings }
```

`AssistantTool` 只有 `retrieval` 一种类型定义。线程助手快照 `ThreadAssistantInfo`（`core/src/types/thread/threadEntity.ts:29-35`）字段：

```text
ThreadAssistantInfo { id, name, model: ModelInfo, instructions?, tools? }
```

### 1.1 类型不一致

- web 侧 `Assistant`（`web-app/src/types/threads.d.ts:57`）完整字段为 `avatar/id/name/created_at/description/instructions/parameters`；core 侧含 `model/tools/file_ids` 而无 `parameters`，形状不同。
- assistant-extension 的 v2 迁移却写入 `parameters` 字段（L184-187），web 侧又未见 tools 持久化路径——这是源码层面的事实性不一致，横向比较时需要注意 core/web 两侧对“助手能干什么”的表述并不一致。

### 1.2 工具、知识库与记忆（交接 Agent 工具笔记）

助手侧能声明的能力只有 `retrieval` 工具（`AssistantTool`）与 `file_ids`；文档嵌入线程后前端自动 `approveToolForThread`（`$threadId.tsx:1028`）。

MCP/Web 搜索/RAG 工具的实际加载、注入、审批与执行链路属 Agent 工具类目，见 `../Agent工具/Jan-Agent工具调查笔记.md`，本笔记只记录助手声明这一交接点；记忆与子 Agent 机制本次未在助手层找到（见 §6）。

## 2. 持久化与迁移

`extensions/assistant-extension/src/index.ts`（355 行）：

- 存储：每个助手一个 JSON 文件 `file://assistants/<id>/assistant.json`；`getAssistants` 空库时回退内置默认（L275-279），`createAssistant`/`deleteAssistant` 均为单文件读写（L281-303）；
- 迁移版本文件：`file://assistants/.migration_version`（L12），`CURRENT_MIGRATION_VERSION = 3`（L11）；
- v1：更新 assistant instructions（L98+）；
- v2：写入 Menlo Research 指令与 `DEFAULT_PARAMETERS`（L140-209）；
- v3：剥掉身份前缀（L212-241）：对 `V2_IDENTITY_LINE + defaultAssistant.instructions` 开头的助手重置为默认指令（L220-231）。

数据目录：`src-tauri/src/core/app/constants.rs` `JAN_DATA_DIRS_CONVERSATIONS = ["threads", "assistants"]`。

**导入导出与分享**：本次未找到角色导入导出机制——检索范围：`routes/settings/assistant.tsx`、`AddEditAssistant.tsx`、`AssistantsMenu.tsx` 与 `assistant-extension` 全部源码，未见文件导入、JSON 分享或导出入口；跨设备迁移只能依赖复制数据目录（`file://assistants/<id>/assistant.json`）。兼容性仅体现在 v1-v3 版本迁移（见上）。

## 3. 默认助手

`defaultAssistant`（assistant-extension index.ts:305-354）：

```text
id: 'jan', avatar: '👋', model: '*',
description: 'Jan is a helpful desktop assistant …',
instructions: 语言跟随 + 分步思考 + 强制逻辑分析（“professional tool caller”）+ 搜索优先 + {{current_date}}
tools: [{ type:'retrieval', enabled:false, useTimeWeightedRetriever:false,
          settings:{ top_k:2, chunk_size:1024, chunk_overlap:64, retrieval_template } }]
```

- web 侧 `hooks/useAssistant.ts`（209 行）也内嵌一份默认助手：id 与 core 侧相同、`parameters:{}`、较长指令模板（L30-56）、硬编码的 `created_at: 1747029866.542`（L33）。
- localStorage 键 `defaultAssistantId`/`lastUsedAssistant`（`web-app/src/constants/localStorage.ts:23`）记录默认与最近使用——即前端有第二份默认助手表示，与 core 侧内容基本相同但分属两处定义，结构互不共享。

`useAssistant` store 事实（行级核验）：

- store 结构（L6-20）：`assistants/currentAssistant/loading/defaultAssistantId` + 五个 action；
- 初始状态 `getInitialAssistantState`（L104-111）：`assistants:[defaultAssistant]`、`currentAssistant:defaultAssistant`、`defaultAssistantId:''`、`loading:true`；
- `setAssistants`（L192-208）：从 localStorage 解析 lastUsed/default 后设定 current；`setDefaultAssistant`（L172-182）同时写 store 与 localStorage；`deleteAssistant`（L144-171）删除当前/默认时回退内置默认；
- 加载入口：`web-app/src/providers/DataProvider.tsx` L240-253 调 `assistants().getAssistants()` 后 `setAssistants`（空数据置 null、异常保留默认）。

## 4. 线程绑定与 system prompt

- `$threadId.tsx` L205-208：`systemMessage = renderInstructions(threadAssistant.instructions)`；
- `custom-chat-transport.ts` `getActiveInferenceParams`（L773-784）：线程有助手且非 `'model-only'` 时才用其参数，否则为空；
- `web-app/src/services/threads/default.ts` L86-91：无助手时写入 `{id:'model-only', name:'Model', model: modelPayload}`；
- 指令模板 `lib/instructionTemplate.ts`（23 行）：仅替换 `{{current_date}}`（UTC 长月份，`formatDate`）。

模型切换（SamplerPopover）与助手切换（AssistantSwitcher）的联动由 `lastUsedModel`/`lastUsedAssistant` localStorage 维护。

### 4.1 消息元数据与重新生成语义

- **消息不保存模型/参数元数据**：onFinish 持久化的 metadata 只是流式元数据（finishReason/usage）加 `parentId`/`stopped`（`$threadId.tsx:351-411`）；`ThreadMessage.assistant_id?`（`core/src/types/message/messageEntity.ts:18`）在 web-app 无任何赋值点，无 model/parameters 字段。
- **重新生成保留旧回复为 sibling**：`handleRegenerate`（`$threadId.tsx:1315-1346`）先做分支拆分，新回复在 onFinish 以 parentId 挂为新分支；版本切换靠 `activeRootId` + `computeActivePath`（:849-855、:1225-1246），测试断言 "regenerate … keeps the prior version (no delete)"（`__tests__/$threadId.test.tsx:543`）。
- 这与 AIO Hub 的"同历史兄弟分支"类似，但 thread 的 instructions/parameters 来自内嵌快照，重新生成不重读 Assistant 当前配置。
- **无开场白**：Assistant 无 greeting 字段，创建 thread 不注入开场消息（`useThreads.ts:315-361`、`threads/default.ts:78-119`）。
- **提示词无分组**：`instructions` 是单段字符串，仅整段替换 `{{current_date}}`（`lib/instructionTemplate.ts`），无块级拆分或组级开关（`predefinedParams.ts:554` 的 `groupIds` 是采样参数 UI 分组，非提示词块）。

## 5. 设置 UI

- `routes/settings/assistant.tsx`：列表/增删改/设为默认；
- `containers/dialogs/AddEditAssistant.tsx`：emoji 头像/名称/描述/instructions/模型选择（`AddModel` 对话框）/`ParametersSection`（参数表单，基于 `lib/predefinedParams.ts` 的 `ParamDef`，非 JSON schema 自动表单）；
- `AssistantsMenu.tsx`、`AssistantSwitcher.tsx`：仅助手数量 >1 时显示；`'model-only'` 作为“仅模型”项；`SamplerPopover.tsx` L77-84 同样判断。

## 6. 边界与未验证事项

- core 与 web 两侧 Assistant 类型不一致（web 有 parameters、无 model/tools/file_ids；迁移却写 parameters）：事实已确认，运行时影响（web 保存的 parameters 是否回流 core 并参与推理参数合并）需运行时验证。
- `{{current_date}}` 只有这一个模板变量（事实）；没有用户变量/场景变量系统。
- 默认助手的 `model:'*'` 与模型能力（tools/vision）的运行时解析关系未逐项核对。
- web 侧未见 tools 的持久化：助手工具配置在 UI 编辑后是否写入 `assistant.json` 未验证。
- 角色无导入导出机制（检索范围见 §2），跨设备迁移只能复制数据目录——迁移的运行时行为未验证。
- 未运行项目测试或构建；记录来自静态源码。

## 7. 关键源码索引

- Assistant 类型：`core/src/types/assistant/assistantEntity.ts`
- 存储与迁移：`extensions/assistant-extension/src/index.ts:11-95`、`98-241`、`258-303`
- 默认助手：`extensions/assistant-extension/src/index.ts:305-354`
- 线程助手快照：`core/src/types/thread/threadEntity.ts:29-35`
- system prompt：`web-app/src/routes/threads/$threadId.tsx:205-208`
- 推理参数来源：`web-app/src/lib/custom-chat-transport.ts:773-784`
- 指令模板：`web-app/src/lib/instructionTemplate.ts`
- 助手切换与线程绑定：`web-app/src/containers/AssistantSwitcher.tsx:68`、`web-app/src/hooks/useThreads.ts:362-379`
- web 侧助手 store：`web-app/src/hooks/useAssistant.ts`（store 结构 L6-20、默认助手 L30-56、初始状态 L104-111、setAssistants L192-208）、`web-app/src/providers/DataProvider.tsx:240-253`
- 设置 UI：`web-app/src/routes/settings/assistant.tsx`、`web-app/src/containers/dialogs/AddEditAssistant.tsx`
- 助手切换：`web-app/src/containers/AssistantsMenu.tsx`、`AssistantSwitcher.tsx`
