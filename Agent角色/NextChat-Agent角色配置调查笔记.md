# NextChat Agent 角色配置调查笔记

> 调查对象：`https://github.com/ChatGPTNextWeb/NextChat`（重点 `app/store/mask.ts`、`app/masks/`、`app/components/mask.tsx`、`app/components/new-chat.tsx`）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`1d3dc331512929a4b1d3e82354e72acce33b5c7a`（分支：`main`）
>
> 调查方式：只读源码梳理；未修改 NextChat 仓库
>
> 调查范围：Agent/角色配置结构、能力边界、运行时行为与内置预设；术语上将 Mask 作为 Agent 角色配置分析
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的角色是“提示词、示例上下文、模型参数和工具选择”的组合，不是一个独立运行时：

1. 一个 `Mask` 对象承载角色的全部配置：名称、头像、语言、示例上下文、模型配置、插件 id，以及 Artifact 与 code fold 两个显示开关，字段定义见 `app/store/mask.ts:9-23`。
2. 用户自建的角色由 Zustand 持久化 store 负责增删改查；内置角色则在页面加载后异步拉取构建产物 `/masks.json`，展示时再把当前全局模型配置叠加到角色自带的局部配置上，见 `app/store/mask.ts:49-105` 与 `app/masks/index.ts:22-37`。
3. 新会话创建时会复制传入 Mask，并把全局 `modelConfig` 与 Mask 局部配置合并；会话之后持有自己的 Mask 副本。用户在当前会话切换模型或其他模型参数时，`syncGlobalConfig` 被关闭。
4. `context` 是有顺序的 `ChatMessage[]`，编辑器支持增删、拖拽排序、文本/图片示例。发送请求时它被直接插入 system prompt 之后；`hideContext` 只影响聊天页面是否显示这些上下文消息，不会从请求上下文中删除。
5. “角色继承”仅限模型配置同步：默认跟随全局模型配置，用户改动后转为会话/Mask 局部配置；没有版本继承、父子角色、权限隔离或角色运行时状态机。

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

`createEmptyMask` 默认使用当前全局模型配置、当前语言、空的示例上下文与插件列表，并把 `syncGlobalConfig` 设为 true（`app/store/mask.ts:34-47`）。

## 2. 创建、持久化和内置角色

### 2.1 用户 Mask store

`useMaskStore` 使用 `createPersistStore`，存储键为 `StoreKey.Mask`、版本 `3.1`（`app/store/mask.ts:49-137`）：

- 新建时以空角色模板为默认值，用调用方传入的字段覆盖，并把 `builtin` 固定为 false。
- 更新先复制目标角色，把改动应用到副本，再回写 store 并打一次更新标记。
- 删除按 id 移除单个用户角色。
- 列表先按创建时间倒序排出用户角色，再追加内置角色。

### 2.2 内置 Mask 构建和加载

内置 Mask 的构建与加载：

- 构建脚本把按 cn、tw、en 维护的三组角色常量合并成一个 JSON，输出到 `public/masks.json`，见 `app/masks/build.ts:9-25`。
- 浏览器端在启动后请求这个文件，为每个条目分配递增的内置 id，分别登记到内置角色列表与内置角色 store，见 `app/masks/index.ts:22-37`。
- 内置角色声明模型配置时允许只写部分字段，未写的部分沿用全局设置，因此一个内置角色通常只改少数生成参数，类型定义见 `app/masks/typing.ts:4-7`。

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

`app/components/new-chat.tsx:77-107` 负责列出 Mask 与命令/URL 选择，`startChat` 调用 `newSession` 后进入聊天页。

`useChatStore.newSession`（`app/store/chat.ts:307-328`）把 Mask 复制到新会话，模型配置按“全局后局部”顺序合并；会话保存顶层 Mask 对象而非仅 id，模型配置单独合并复制；context/plugin 等嵌套数组在创建时没有递归克隆。后续界面编辑直接修改会话中的 Mask。

fork 为消息重分配 id，并分别展开复制 Mask 与模型配置，但嵌套的 context、plugin 和消息内容数组在这一步仍可能共享引用；摘要与上下文清除位置也没有继承。分叉在顶层角色参数上独立，实际执行的是浅层复制。见 [forkSession](../../NextChat/app/store/chat.ts#L243-L267)。

## 4. Context prompt 编辑和发送

### 4.1 编辑器能力

`MaskConfig`（`app/components/mask.tsx:76-256`）允许修改：

- 名称和头像；
- `hideContext`、Artifact、code fold 开关；
- `syncGlobalConfig`；
- `ModelConfigList` 中的模型和生成参数；
- 通过 `ContextPrompts` 管理 context。

`ContextPrompts`（`app/components/mask.tsx:324-440`）把每条示例作为 `ChatMessage` 编辑，支持插入、删除和拖拽排序；编辑图片示例时会把文本与 `image_url` 重组为 `MultimodalContent[]`。

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

`hideContext` 的唯一读取点是 `app/components/chat.tsx:1333-1335`：渲染窗口为 true 时不把 context 放入可视消息列表。源码中 `getMessagesWithMemory` 仍然无条件复制 `session.mask.context`，因此该开关只作用于可视列表，“隐藏”的 context 仍会随请求发送。

## 5. 全局配置同步和角色局部化

Mask 的模型编辑由 `MaskConfig.updateConfig` 完成（`app/components/mask.tsx:85-95`）：复制当前 `modelConfig`、应用编辑，然后设置 `syncGlobalConfig = false`。聊天页的模型选择同样直接修改当前会话的 Mask 副本并关闭同步（`app/components/chat.tsx:682-714`）。

当 `syncGlobalConfig` 为 true 时，聊天组件的 effect 会把全局模型配置复制到当前会话 Mask（`app/components/chat.tsx:1148-1175`）；重新打开同步时，编辑器会要求确认并用全局配置覆盖局部配置（`app/components/mask.tsx:219-245`）。

由此形成一条状态规则：

```text
syncGlobalConfig = true
  -> 全局模型配置是当前会话的来源
用户修改当前会话模型
  -> syncGlobalConfig = false
  -> 当前会话继续使用 Mask 副本中的 modelConfig
```

### 5.1 开场白、消息元数据与重新生成

- **开场白是聊天页临时插入的欢迎语**：文案取自固定常量 `BOT_HELLO`（`app/store/chat.ts:99-102`），i18n 取值形如"有什么可以帮你的吗"。聊天页计算渲染列表时，只有示例上下文为空、且列表首条还不是这句欢迎语，才把它推进本地数组，见 `app/components/chat.tsx:1337-1346`。它只存在于组件内部，不会写入会话消息，用户发出第一条消息后就不再出现。
- **开场白独立于角色定义**：新建会话不写入任何欢迎消息，之后修改某个角色也不会改动已有会话的开场白，创建入口见 `app/store/chat.ts:307-328`。
- **消息只记下模型名**：消息对象的字段很少，只有 id、日期、流式与错误标记、模型、工具、音频地址和 MCP 响应等；用户消息不带 model，机器人消息在创建时拷贝当时的模型名，温度等生成参数没有留下副本，字段定义与拷贝点见 `app/store/chat.ts:57-66`、`436-440`。
- **重新生成靠删旧建新**：重发入口先删掉这一轮的用户消息与助手消息，再用原文与图片重新走一遍输入流程，新消息拿到新 id，模型参数取自重发那一刻会话副本里的模型配置，见 `app/components/chat.tsx:1217-1269`。
- **示例上下文按条目增删**：编辑器给每条示例只提供 role 下拉、文本输入、删除和拖拽，控制的是内容本身，没有单条启停开关，控件实现在 `app/components/mask.tsx:260-322`。NewChat 页的 `useMaskGroup` 只负责卡片墙的视觉分组，与示例上下文的语义无关，见 `app/components/new-chat.tsx:35-75`。

## 6. 导入、导出和分享

Mask 页面导出时只导出 `builtin === false` 的 Mask JSON；导入支持数组或单个对象，只检查 `name` 后调用 `maskStore.create`（`app/components/mask.tsx:476-498`）。没有 schema 版本校验、字段白名单或冲突解决策略。

编辑器也可以生成 `#\/new-chat?mask=<id>` 形式的分享链接（`app/components/mask.tsx:97-100`）。接收方按 id 从用户 store 或内置 store 查找，再用同一套 `newSession(mask)` 创建会话。

## 7. 风险、边界和未验证事项

1. **Mask 是可变副本**：会话保存完整 Mask，不是不可变引用。保存 Mask 定义不会主动遍历已创建会话回写；全局同步仅使会话模型参数跟随应用级模型配置，与保存 Mask 定义是不同路径。
2. **`hideContext` 语义容易误解**：它只隐藏聊天 UI 中的示例消息，不提供隐私隔离或请求脱敏。
3. **插件与角色耦合**：`Mask.plugin` 直接决定可用工具，但没有按角色声明权限、审批或参数范围。
4. **导入信任边界宽**：JSON 导入几乎不校验字段，恶意/过大的 context、模型配置和插件 id 可以进入持久化状态。
5. **内置资源异步加载**：`/masks.json` 获取失败时回退为空内置列表；本次未启动前端验证加载失败、URL 分享和跨版本迁移表现。
6. 源码统计到的内置角色按 `cn/tw/en` 文件分组维护，具体条目数量随构建内容变化，统计值只对应本次构建。

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
