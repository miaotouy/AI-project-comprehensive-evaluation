# NextChat Agent 角色配置调查笔记

> 调查对象：`E:\works\git\NextChat`（重点 `app/store/mask.ts`、`app/masks/`、`app/components/mask.tsx`、`app/components/new-chat.tsx`）
>
> 调查更新日期：2026-08-06
>
> 代码快照：`706a18b95b714ab29b2a4842d3b9ff4f887935d5`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 NextChat 仓库
>
> 调查范围：Agent/角色配置结构、能力边界、运行时行为与内置预设；术语上将 Mask 作为 Agent 角色配置分析
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的角色是“提示词、示例上下文、模型参数和工具选择”的组合，而不是一个独立运行时：

1. `Mask` 类型同时保存名称、头像、`context` 示例消息、`modelConfig`、语言、插件 id，以及 Artifact/code fold 等显示开关（`app/store/mask.ts:9-23`）。
2. 用户 Mask 通过 Zustand 持久化 store CRUD；内置 Mask 从构建产物 `/masks.json` 异步加载，并在展示时把全局模型配置覆盖到内置 Mask 的局部配置上（`app/store/mask.ts:49-105`、`app/masks/index.ts:22-37`）。
3. 新会话创建时会复制传入 Mask，并把全局 `modelConfig` 与 Mask 局部配置合并；会话之后持有自己的 Mask 副本。用户在当前会话切换模型或其他模型参数时，`syncGlobalConfig` 被关闭。
4. `context` 是有顺序的 `ChatMessage[]`，编辑器支持增删、拖拽排序、文本/图片示例。发送请求时它被直接插入 system prompt 之后；`hideContext` 只影响聊天页面是否显示这些上下文消息，不会从请求上下文中删除。
5. “角色继承”非常轻量：默认同步全局模型配置，用户改动后转为会话/Mask 局部配置；没有版本继承、父子角色、权限隔离或角色运行时状态机。

## 1. Mask 数据模型

```text
Mask
  id / createdAt / name / avatar / lang / builtin
  context: ChatMessage[]
  modelConfig: ModelConfig
  syncGlobalConfig?: boolean
  hideContext?: boolean
  plugin?: string[]
  enableArtifacts?: boolean
  enableCodeFold?: boolean
```

字段证据在 `app/store/mask.ts:9-23`。其中：

| 字段 | 作用 | 发送请求时是否直接参与 |
|---|---|---|
| `name`、`avatar`、`lang` | 角色展示、会话标题初始值和语言 | `name` 作为新会话 topic；头像仅 UI |
| `context` | 预置 user/assistant/system 示例 | 是，按顺序拼入消息 |
| `modelConfig` | 模型、provider、温度、历史长度、记忆等 | 是，决定请求和历史裁剪 |
| `plugin` | 当前角色可用的 OpenAPI 插件 id | 是，OpenAI adapter 据此注入工具 |
| `syncGlobalConfig` | 是否继续跟随全局模型配置 | 间接影响 `modelConfig` |
| `hideContext` | 是否在聊天窗口显示 context | 仅 UI；`getMessagesWithMemory` 未读取它 |
| `enableArtifacts`、`enableCodeFold` | 当前角色的渲染能力开关 | 影响 Markdown/Artifact UI |

`createEmptyMask` 默认使用当前全局模型配置、当前语言、空 context、空插件列表，并将 `syncGlobalConfig` 设为 true（`app/store/mask.ts:34-47`）。

## 2. 创建、持久化和内置角色

### 2.1 用户 Mask store

`useMaskStore` 使用 `createPersistStore`，存储键为 `StoreKey.Mask`、版本 `3.1`（`app/store/mask.ts:49-137`）：

- `create`：以 `createEmptyMask()` 为默认值，覆盖传入字段，并强制 `builtin: false`。
- `updateMask`：复制目标 Mask 后更新，写回 store 并调用 `markUpdate`。
- `delete`：按 id 删除。
- `getAll`：用户 Mask 按 `createdAt` 倒序，然后追加内置 Mask。

### 2.2 内置 Mask 构建和加载

`app/masks/build.ts:9-25` 把 `CN_MASKS`、`TW_MASKS` 和 `EN_MASKS` 写为 `public/masks.json`。浏览器端 `app/masks/index.ts:22-37` 获取该文件，为每个条目分配递增内置 id，并放入 `BUILTIN_MASKS`/`BUILTIN_MASK_STORE`。`BuiltinMask` 允许 `modelConfig` 使用 `Partial<ModelConfig>`（`app/masks/typing.ts:4-7`），所以内置角色可以只覆盖少数模型参数。

`getAll` 返回内置角色时会把当前全局 `config.modelConfig` 与 Mask 的局部配置合并（`app/store/mask.ts:92-104`）。这意味着同一个内置角色在不同全局模型设置下，最终会话配置可能不同。

## 3. 角色进入新会话的生命周期

```text
NewChat 页面
  -> maskStore.getAll()
  -> 用户选择 Mask / URL ?mask=id
  -> chatStore.newSession(mask)
     -> createEmptySession()
     -> session.mask = { ...mask, modelConfig: { ...global, ...mask.modelConfig } }
     -> session.topic = mask.name
  -> navigate(Path.Chat)
```

`app/components/new-chat.tsx:77-107` 负责列出 Mask 和通过命令/URL 选择；`startChat` 调用 `newSession` 后进入聊天页（`app/components/new-chat.tsx:91-95`）。

`useChatStore.newSession`（`app/store/chat.ts:307-328`）把 Mask 复制到新会话，模型配置按“全局后局部”的顺序合并。会话模型是 `ChatSession.mask`，而不是只保存一个 Mask id；后续编辑会直接修改这份副本。

这也是 fork 行为的关键：`forkSession` 深拷贝消息并复制 Mask 及其 `modelConfig`（`app/store/chat.ts:243-267`），所以分叉会话之后可以拥有独立角色参数。

## 4. Context prompt 编辑和发送

### 4.1 编辑器能力

`MaskConfig`（`app/components/mask.tsx:76-256`）允许修改：

- 名称和头像；
- `hideContext`、Artifact、code fold 开关；
- `syncGlobalConfig`；
- `ModelConfigList` 中的模型和生成参数；
- 通过 `ContextPrompts` 管理 context。

`ContextPrompts`（`app/components/mask.tsx:324-440`）把每条示例作为 `ChatMessage` 编辑，支持插入、删除和拖拽排序；编辑图片示例时会把文本与 `image_url` 重新组织为 `MultimodalContent[]`（`app/components/mask.tsx:338-349`）。

### 4.2 请求拼接顺序

`getMessagesWithMemory`（`app/store/chat.ts:542-639`）把当前 Mask 的 context 放在 system prompt/长期记忆之后、最近历史之前：

```text
system prompt（可选，含 MCP 工具目录）
  -> long-term memory summary（可选）
  -> session.mask.context
  -> historyMessageCount 范围内的最近消息
  -> 本次新的 user message
```

请求会按 `max_tokens` 估算 token，从尾部向前选择可发送消息。`clearContextIndex` 作为下界，能让用户清除后续请求使用的上下文，但它不会删除 `session.messages` 中的历史记录。

`hideContext` 的唯一读取点是 `app/components/chat.tsx:1333-1335`：渲染窗口为 true 时不把 context 放入可视消息列表。源码中 `getMessagesWithMemory` 仍然无条件复制 `session.mask.context`，因此“隐藏”不等于“不发送”。

## 5. 全局配置同步和角色局部化

Mask 的模型编辑由 `MaskConfig.updateConfig` 完成：先复制 `props.mask.modelConfig`，应用编辑，再设置 `mask.syncGlobalConfig = false`（`app/components/mask.tsx:85-95`）。聊天页的模型选择也直接改当前 session Mask，并关闭同步（`app/components/chat.tsx:682-714`）。

当 `syncGlobalConfig` 为 true，聊天组件的 effect 会把全局 `config.modelConfig` 复制到当前 session Mask（`app/components/chat.tsx:1148-1175`）。重新打开同步时，编辑器会要求确认，然后用全局配置覆盖 Mask 局部模型配置（`app/components/mask.tsx:219-245`）。

这形成了一个简单的状态规则：

```text
syncGlobalConfig = true
  -> 全局模型配置是当前会话的来源
用户修改当前会话模型
  -> syncGlobalConfig = false
  -> 当前会话继续使用 Mask 副本中的 modelConfig
```

## 6. 导入、导出和分享

Mask 页面导出时只导出 `builtin === false` 的 Mask JSON；导入支持数组或单个对象，只检查 `name` 后调用 `maskStore.create`（`app/components/mask.tsx:476-498`）。没有 schema 版本校验、字段白名单或冲突解决策略。

编辑器也可以生成 `#\/new-chat?mask=<id>` 形式的分享链接（`app/components/mask.tsx:97-100`）。接收方按 id 从用户 store 或内置 store 查找，再用同一套 `newSession(mask)` 创建会话。

## 7. 风险、边界和未验证事项

1. **Mask 是可变副本**：会话保存完整 Mask，而不是不可变引用。修改全局 Mask 定义不会自动回写已经创建的会话，除非它仍处于全局同步状态。
2. **`hideContext` 语义容易误解**：它只隐藏聊天 UI 中的示例消息，不提供隐私隔离或请求脱敏。
3. **插件与角色耦合**：`Mask.plugin` 直接决定可用工具，但没有按角色声明权限、审批或参数范围。
4. **导入信任边界宽**：JSON 导入几乎不校验字段，恶意/过大的 context、模型配置和插件 id 可以进入持久化状态。
5. **内置资源异步加载**：`/masks.json` 获取失败时回退为空内置列表；本次未启动前端验证加载失败、URL 分享和跨版本迁移表现。
6. 源码统计到的内置角色按 `cn/tw/en` 文件分组维护，具体条目数量随构建内容变化；本文不把数量当作稳定 API。

## 8. 关键源码索引

- Mask 类型和默认值：`app/store/mask.ts:9-47`
- 用户 Mask CRUD、内置合并和迁移：`app/store/mask.ts:49-137`
- 内置 Mask 构建/加载：`app/masks/build.ts:9-25`、`app/masks/index.ts:8-37`、`app/masks/typing.ts:4-7`
- 新聊天选择 Mask：`app/components/new-chat.tsx:77-107`
- 新会话复制 Mask、fork：`app/store/chat.ts:243-328`
- Mask 编辑器和同步开关：`app/components/mask.tsx:76-256`
- Context 增删和排序：`app/components/mask.tsx:324-440`
- Mask 导入导出：`app/components/mask.tsx:442-498`
- 请求上下文拼接：`app/store/chat.ts:542-639`
- 当前会话模型选择和全局同步：`app/components/chat.tsx:682-714`、`1148-1175`
