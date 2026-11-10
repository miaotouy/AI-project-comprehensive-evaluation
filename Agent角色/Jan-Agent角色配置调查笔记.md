# Jan Agent 角色配置调查笔记

> 调查对象：`https://github.com/janhq/jan`（重点 `core/src/types/assistant/assistantEntity.ts`、`extensions/assistant-extension/src/index.ts`、`core/src/types/thread/threadEntity.ts`、`web-app/src/lib/instructionTemplate.ts`）
>
> 调查更新日期：2026-11-04
>
> 代码快照：`12c59c8b8b0d6831b3f5601799b4e5d3422cf5d9`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 Jan 仓库
>
> 调查范围：Assistant 数据模型、文件持久化与迁移、默认助手、线程绑定、指令模板、设置 UI
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

普通 Chat 的“角色”是 `Assistant` 文件实体，每个助手一个 JSON，由 assistant-extension 管理。独立 CLI Agent 使用项目 `.jan/agent/agent.toml` 和用户 `~/.jan/config.toml` 配置模型、工具/预算与 Provider；Cowork 的子 Agent 由单独的保存定义目录解析，未知名称退化为专注型通用 Agent。三者的角色配置和会话快照不能互相等同（`src-tauri/src/core/agent/project.rs:1-47,183-237`、`web-app/src/lib/coworkTools.ts:121-160`）。

关键事实：

1. 两侧的 Assistant 类型字段不同：core 侧声明 `{model, instructions?, tools?, file_ids}`，web 侧声明 `parameters`，两侧字段集合对不上（完整字段对照见 §1.1）。
2. 迁移 v2 为助手写入 Menlo Research 指令，同时写入默认采样参数常量 `DEFAULT_PARAMETERS`，取值为 `temperature=0.7, top_k=20, top_p=0.8, repeat_penalty=1.12`；迁移 v3 再把指令开头的身份前缀去掉。
3. 线程绑定保存的是嵌入快照，不持有引用：ThreadAssistantInfo 把助手的名称、模型、指令和工具拷进线程对象；线程没有助手时写入一个 id 为 model-only、名称为 Model 的占位助手。
4. system prompt 由 renderInstructions 按线程助手的 instructions 生成，其中的 {{current_date}} 会替换成 UTC 长月份日期；只有线程带助手且该助手不是 model-only 时，请求才采用它的推理参数。
5. 默认助手自带一条 retrieval 类型的工具声明并默认关闭，检索参数为 `top_k=2, chunk_size=1024, chunk_overlap=64`，另带一份检索模板；RAG 工具能力挂靠在这条声明上。

## 总体生效链路

从角色选择到请求的完整链路（静态确认）：

```text
AssistantSwitcher / AssistantsMenu 选择助手
  -> updateCurrentThreadAssistant（`web-app/src/hooks/useThreads.ts:397`）
      写入线程快照 assistants: [{...assistant, model: 线程当前模型}]
  -> `$threadId.tsx:449-451` 读取 thread.assistants[0]
      systemMessage = renderInstructions(threadAssistant.instructions)
  -> CustomChatTransport.sendMessages 拼接 system + 上下文
      （`custom-chat-transport.ts` 的 buildSystemPrompt，见 Chat 笔记 §3.2）
```

- 快照语义：用户切换助手时，选择动作只改写线程内嵌的那份快照，全局 assistant 对象保持不变；在线程内调整采样参数也走同一条 updateCurrentThreadAssistant 写入路径（`web-app/src/components/AssistantsMenu.tsx:56,79`、`web-app/src/containers/AssistantSwitcher.tsx` 的切换回调）。
- 线程没有绑定助手（model-only）时，指令为空、systemMessage 为 undefined，请求不带助手指令（`web-app/src/services/threads/default.ts:86-91`）。
- 生效边界：指令与推理参数都取自线程快照；助手的 model:'*' 声明与模型能力（tools/vision）在运行时的解析关系未逐项核对（见 §6 未验证）。

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

- web 侧的 Assistant 声明了七个字段：头像、id、名称、创建时间、描述、instructions 与 parameters（`web-app/src/types/threads.d.ts:57`）；core 侧声明了 model、tools 与 file_ids，parameters 在 core 侧没有对应声明，两侧形状不同。
- assistant-extension 的 v2 迁移反而会写入 parameters 字段（`extensions/assistant-extension/src/index.ts:184-187`），web 侧又看不到 tools 的持久化路径。这是源码层面的事实性不一致，core 与 web 对“助手能干什么”的表述对不上。

### 1.2 工具、知识库与记忆（交接 Agent 工具笔记）

普通 Chat 的 Assistant 类型中工具声明只有 `retrieval` 与 `file_ids`；文档嵌入后线程前端自动批准 RAG 工具（`core/src/types/assistant/assistantEntity.ts`、`web-app/src/routes/threads/$threadId.tsx`）。这不限制 Cowork/CLI 的原生 Agent 工具和技能。

MCP、Web 搜索与 RAG 的加载和审批流程见 Agent 工具笔记。CLI Agent 的配置从项目 TOML 解析，Provider 覆盖的优先级高于全局配置和桌面配置。

Cowork 的 task 可以在同一轮里派发并行子 Agent，派发 schema 与 Rust 侧 subagent.rs 同源，形状为 `{subagents:[{name, task, phase?, allowed_tools?}]}`。name 命中已保存的子 Agent 定义时沿用那套角色与工具，否则退化为通用专注型；带 phase 的任务按阶段成组串行，省略则全部并行扇出，各子任务最终把答案写到共享 blackboard 上。子 Agent 的写域在 Rust 侧另有隔离，每个子 Agent 独占一个 git worktree，细节见 Agent 工具笔记。

普通 Chat Assistant 的 tools 字段只承载 retrieval 与 file_ids 两类声明，Cowork 与 CLI Agent 的原生工具、技能由各自链路单独解析（`src-tauri/src/core/agent/project.rs:34-47,92-105`、`web-app/src/lib/coworkTools.ts:121-160`）。

## 2. 持久化与迁移

`extensions/assistant-extension/src/index.ts`（370 行）：

- 存储：每个助手对应一个 JSON 文件，路径为 `file://assistants/<id>/assistant.json`；`getAssistants` 在库为空时回退到内置默认助手，`createAssistant` 与 `deleteAssistant` 都是单文件读写（`extensions/assistant-extension/src/index.ts:281-303`）；
- 迁移版本记在 `file://assistants/.migration_version` 中，实现里用常量 CURRENT_MIGRATION_VERSION = 3 表示当前版本（同文件头部）；
- v1 迁移补写助手指令，入口是 `migrateAssistantInstructions`（`:120` 起）；
- v2 迁移写入 Menlo Research 指令与那份默认采样参数，入口是 `migrateToMenloInstructions`（`:162` 起）；
- v3 迁移剥掉指令开头的身份前缀，入口是 `migrateStripIdentityPreamble`（`:235` 起）：指令以 V2_IDENTITY_LINE 加默认指令开头的助手会被重置为默认指令。

数据目录：`src-tauri/src/core/app/constants.rs` `JAN_DATA_DIRS_CONVERSATIONS = ["threads", "assistants"]`。

**导入导出与分享**：本次未找到角色导入导出机制——检索范围：`routes/settings/assistant.tsx`、`AddEditAssistant.tsx`、`AssistantsMenu.tsx` 与 `assistant-extension` 全部源码，未见文件导入、JSON 分享或导出入口；跨设备迁移只能依赖复制数据目录（`file://assistants/<id>/assistant.json`）。兼容性仅体现在 v1-v3 版本迁移（见上）。

## 3. 默认助手

`defaultAssistant`（`extensions/assistant-extension/src/index.ts` 尾部，检索工具配置在 `:350` 起）：

```text
id: 'jan', avatar: '👋', model: '*',
description: 'Jan is a helpful desktop assistant …',
instructions: 语言跟随 + 分步思考 + 强制逻辑分析（“professional tool caller”）+ 搜索优先 + {{current_date}}
tools: [{ type:'retrieval', enabled:false, useTimeWeightedRetriever:false,
          settings:{ top_k:2, chunk_size:1024, chunk_overlap:64, retrieval_template } }]
```

- web 侧的 `hooks/useAssistant.ts` 也内嵌了一份默认助手：id 与 core 侧相同，parameters 是空对象，另带一份较长的指令模板，created_at 是写死的常量。
- localStorage 用 defaultAssistantId 和 lastUsedAssistant 两个键记录默认助手与最近使用（`web-app/src/constants/localStorage.ts:23`）。前端因此有第二份默认助手表示，内容与 core 侧基本相同，但两处各自定义，结构互不共享。

`useAssistant` store 事实（行级核验）：

- store 的接口声明在文件头部（`web-app/src/hooks/useAssistant.ts:6-20`），形状为 `{assistants, currentAssistant, loading, defaultAssistantId}`，另外声明了五个 action；
- 初始状态由 `getInitialAssistantState` 给出：assistants 与 currentAssistant 都指向内置默认助手，defaultAssistantId 是空字符串，loading 为 true（`:104` 附近）；
- 写入 action 有三个：`setAssistants` 从 localStorage 解析最近使用与默认助手后设定 current，`setDefaultAssistant` 同时写 store 与 localStorage，`deleteAssistant` 在删除当前或默认助手时回退到内置默认（`web-app/src/hooks/useAssistant.ts:144-192`）；
- 加载入口在 `DataProvider`：该处调用 assistants().getAssistants() 取回列表后交给 `setAssistants` 写入，返回空数据时置 null，出现异常时保留默认（`web-app/src/providers/DataProvider.tsx:249-260`）。

## 4. 线程绑定与 system prompt

- 线程页把线程助手携带的 instructions 交给 `renderInstructions`，得到请求用的 systemMessage（`web-app/src/routes/threads/$threadId.tsx:449-451`）；
- 推理参数由 `getActiveInferenceParams` 决定：线程有助手且该助手不是 model-only 时才采用助手自带的参数，否则返回空（`web-app/src/lib/custom-chat-transport.ts:974-976`）；
- 新建线程时若没有助手，默认逻辑会写入一个占位助手：id 为 model-only、名称 Model，模型字段填入 modelPayload（`web-app/src/services/threads/default.ts:86-91`）；
- 指令模板文件只有 23 行，替换动作也只有一处：把 `{{current_date}}` 换成 UTC 时区的长月份日期，格式化由 formatDate 完成（`web-app/src/lib/instructionTemplate.ts`）。
- 项目页创建首条对话时，Composer 先按项目记录的 `assistantId` 选助手，再交给既有的 `createThread` 路径把这个助手写成新线程的快照；影响范围限于该项目中新建的线程，全局当前助手保持不变（`web-app/src/routes/project/$projectId.tsx:127-135`、`web-app/src/containers/ChatInput.tsx:235-242,477-496`）。

模型切换（SamplerPopover）与助手切换（AssistantSwitcher）的联动由 `lastUsedModel`/`lastUsedAssistant` localStorage 维护。

### 4.1 消息元数据与重新生成语义

- **消息不保存模型与参数元数据**：onFinish 落库的 metadata 只含流式信息（finishReason、usage）以及 parentId、stopped 两个辅助字段（`web-app/src/routes/threads/$threadId.tsx:351-411`）。消息实体上没有 model 或 parameters 字段，assistant_id 在 web-app 里也没有任何赋值点（`core/src/types/message/messageEntity.ts:18`）。
- **重新生成会把旧回复保留为 sibling**：`handleRegenerate` 先把当前分支拆开，新回复在 onFinish 时以 parentId 挂成一条新分支；版本切换由 activeRootId 配合 `computeActivePath` 计算当前路径，测试对应断言为 "regenerate … keeps the prior version (no delete)"（`web-app/src/routes/threads/$threadId.tsx:849-855,1225-1246,1315-1346`、`web-app/src/routes/threads/__tests__/$threadId.test.tsx:543`）。
- 这与 AIO Hub 的"同历史兄弟分支"类似，但 thread 的 instructions/parameters 来自内嵌快照，重新生成不重读 Assistant 当前配置。
- **没有开场白**：Assistant 类型里没有 greeting 字段，创建 thread 时也不会注入开场消息（`web-app/src/hooks/useThreads.ts:315-361`、`web-app/src/services/threads/default.ts:78-119`）。
- **提示词没有分组**：instructions 是一个单段字符串，渲染时只整段替换 `{{current_date}}`，没有块级拆分，也没有组级开关；采样参数表单里的 groupIds 是参数 UI 分组，与提示词块无关（`web-app/src/lib/instructionTemplate.ts`、`web-app/src/lib/predefinedParams.ts:554`）。

## 5. 设置 UI

- 设置页的角色管理在 `assistant.tsx`：展示助手列表，支持新增、删除、修改和设为默认（`web-app/src/routes/settings/assistant.tsx`）；
- 编辑对话框 `AddEditAssistant.tsx` 收集 emoji 头像、名称、描述、instructions 和模型选择（模型通过 `AddModel` 对话框挑选），采样参数放在 `ParametersSection` 参数表单里；表单字段来自 predefinedParams.ts 的 ParamDef 定义，按定义逐项渲染，没有走 JSON schema 自动生成（`web-app/src/containers/dialogs/AddEditAssistant.tsx`、`web-app/src/lib/predefinedParams.ts`）；
- 助手菜单与切换器只在助手数量大于一个时出现，并把 model-only 作为“仅模型”这一项列出；`SamplerPopover` 用同一判断控制显示（`web-app/src/components/AssistantsMenu.tsx`、`web-app/src/containers/AssistantSwitcher.tsx`、`web-app/src/containers/SamplerPopover.tsx:77-84`）。

## 6. 边界与未验证事项

- CLI 项目 Agent、Cowork 已保存子 Agent 与普通 Chat Assistant 是三个配置边界；项目 TOML 的 CLI 专属字段在桌面前端并不自动获得同样权限（`src-tauri/src/core/agent/project.rs:126-146,294-309`）。

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
- system prompt：`web-app/src/routes/threads/$threadId.tsx:449-451`
- 推理参数来源：`web-app/src/lib/custom-chat-transport.ts:974-976`（线程助手 id 不是 `model-only` 时取 `parameters`）
- 指令模板：`web-app/src/lib/instructionTemplate.ts`
- 助手切换与线程绑定：`web-app/src/containers/AssistantSwitcher.tsx`、`web-app/src/components/AssistantsMenu.tsx:56,79`、`web-app/src/hooks/useThreads.ts:397`
- 项目新对话的助手选择：`web-app/src/routes/project/$projectId.tsx:127-135`、`web-app/src/containers/ChatInput.tsx:235-242,477-496`
- web 侧助手 store：`web-app/src/hooks/useAssistant.ts`（`useAssistant` L113、`setAssistants` L192）、`web-app/src/providers/DataProvider.tsx:249-260`
- 设置 UI：`web-app/src/routes/settings/assistant.tsx`、`web-app/src/containers/dialogs/AddEditAssistant.tsx`
- 助手切换：`web-app/src/components/AssistantsMenu.tsx`、`AssistantSwitcher.tsx`
