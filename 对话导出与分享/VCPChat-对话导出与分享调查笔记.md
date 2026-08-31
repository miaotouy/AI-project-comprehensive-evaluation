# VCPChat 对话导出与分享调查笔记

> 调查对象：`https://github.com/lioensky/VCPChat`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`89e02b778d626078be91dfbad01e5c9554c47f76`（分支：`main`）
>
> 调查方式：静态阅读当前 HEAD 的 Topic 菜单、快捷键、群聊导出、主进程写盘、消息阅读模式、文本查看器截图和图片查看器交付路径；同时核对既有会话与消息管理、Chat UI、消息渲染器笔记；未运行 Electron
>
> 调查范围：Topic Markdown 导出（可见版与完整原始内容版）和单条消息阅读模式的 PNG 截图分享；不覆盖会话备份/恢复、附件原文件下载、Canvas/文坊等独立对象的导出，以及远端链接分享
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPChat 已具备两种本地对话交付能力：`E1 数据交换` 的 Topic Markdown 文件导出，以及 `E3 图片分享` 的单条消息阅读模式截图。两条链的内容口径不同，不能互相替代。

- **普通 Topic 导出**从当前聊天 DOM 的可见消息抽取发送者与 `.md-content` 的 `innerText`，过滤 system 与思考中消息，并移除已渲染的思维链气泡；因此它是阅读文本投影，不是原始会话或可往返数据。
- **完整 Topic 导出**重新读取该 Topic 的 `history.json`，过滤 system 与 `isThinking` 消息后，按文件数组顺序写出 role、Agent、模型、时间戳和原始 `content`。它仍是 Markdown 文本报告，不保留消息 ID、附件对象、分支关系或可导入 schema。
- **截图分享确实抽取对话内容**：消息右键“阅读模式”按当前 Agent/群组、Topic 与 message ID 从 `history.json` 查询该消息的原始 content，传给 text viewer；截图只渲染该查看器内容容器，而非截取聊天窗口或任意桌面。PNG 随后在图片查看器中可复制到剪贴板或下载。
- 本次未找到 JSON/HTML/PDF 导出、整会话树/批量导出、导入往返、远端链接、访问控制、撤销、过期、脱敏或分享版本历史。检索范围包括 Topic 导出入口、主进程 `export-topic-as-markdown`、阅读模式及其截图交接。

## 系统边界与完整主链

```text
普通 Topic 文件：已加载的当前 Topic DOM
  -> 跳过 system/thinking 气泡，克隆 .md-content 并删思维链气泡
  -> innerText 组成“发送者 + 正文”的 Markdown
  -> 保存对话框 -> UTF-8 .md 文件 -> 在文件管理器显示

完整 Topic 文件：Topic 菜单
  -> getHistory 读取 history.json
  -> 跳过 system/isThinking，按数组顺序读取原始 content
  -> 带 role/Agent/model/timestamp 的 Markdown 文本报告
  -> 同一保存对话框 -> UTF-8 .md 文件

单消息图片：消息右键“阅读模式”
  -> get-original-message-content(itemId, itemType, topicId, messageId)
  -> history.json 中按 message ID 查原始 content
  -> text viewer 重渲染该消息 -> modern-screenshot 生成 PNG data URL
  -> image viewer -> 复制 PNG 或浏览器下载 PNG
```

会话的事实源、Topic 路径及历史写入归属见[会话与消息管理笔记](../会话与消息管理/VCPChat-会话与消息管理调查笔记.md)。聊天现场的富内容转换由消息渲染器负责；本笔记只记录它在导出端被采用、降级或重新执行后的交付语义。

## 1. 入口、用户目标与导出源

| 入口 | 粒度与目标 | 导出源 |
|---|---|---|
| Topic 右键“导出此话题” | 当前已打开 Topic 的阅读/传播文本 | 当前 `#chatMessages` 的 `.message-item` DOM |
| `Ctrl/Cmd+E` | 同上，快捷导出当前打开 Topic | 当前消息 DOM |
| Topic 右键“导出此话题(完整)” | 本地存档式文本报告 | 指定 Topic 的 `history.json` |
| 消息右键或中键菜单“阅读模式”后“截图分享” | 单条消息的长图传播 | 指定 message ID 的原始 `content` |

普通导出拒绝未加载的 Topic，提示先打开后再导出；所以它不是可后台批量抽取的完整会话接口。完整导出则直接按菜单传入的 Topic 读取历史，无需当前可见。两个入口的菜单注册与实现见 `modules/topicListManager.js:1158-1174,1229-1406`；快捷键实现与普通导出口径重复，见 `modules/event-listeners.js:96-176`。

## 2. 范围选择、内容口径与字段过滤

**普通导出是可见正文的文本化投影。** 它枚举当前消息容器的 DOM 顺序，排除带 `system` 或 `thinking` class 的气泡。每个剩余气泡只取发送者显示文本和正文容器的 `innerText`；思维链气泡会先从克隆节点删除，另有针对明文思维链标记的正则兜底。Markdown、代码高亮、表格、Mermaid、工具卡、HTML、附件和交互节点均由 `innerText` 降级成普通文本；视觉结构与原始 Markdown 不保真。见 `modules/topicListManager.js:1239-1285`。

由于来源是已加载 DOM，渐进历史渲染、当前渲染状态或缺失的发送者/正文节点都会影响可提取范围；代码会跳过空内容。静态代码未证明普通导出在长 Topic 中一定等待所有历史消息插入 DOM，故不能将其描述为完整会话导出。

**完整导出改用持久化原文。** 它读取整个历史数组，排除 `role === 'system'` 和 `isThinking === true` 的消息，保留其余消息的 role、推断出的 Agent 名称和模型、可用时间戳及 content。字符串、`{text}` 和多模态数组分别取文本或拼接 text part；其他 content 尝试 JSON 字符串化。因此完整模式比普通模式更接近历史原文，但仍显式排除了 system 与思考中消息，且不会输出 message ID、头像、附件元数据、群聊归属字段或 Topic 元数据。见 `modules/topicListManager.js:1310-1396`。

两种模式都没有脱敏步骤。文件路径、提示词、工具输出或个人信息只要位于未过滤的正文或原始 content 中，都会进入交付物；附件本身不会被复制或打包。

## 3. 格式、资源与往返能力

Topic 交付物仅为 UTF-8 `.md` 文件。主进程清理文件名中的 Windows 非法字符，显示保存对话框后直接 `writeFile`，成功即在系统文件管理器定位文件；没有临时文件、原子 rename 或重试处理。见 `main.js:1914-1946`。

文件是面向阅读的 Markdown：普通模式为标题、粗体发送者、正文和分隔线；完整模式是含英文标签的顺序消息报告。没有格式版本、schema 标记或导入入口，本次未找到从该文件恢复 Topic、消息身份或分支的能力。外部图片、文件、音频和 URL 也未封装，故 Markdown 的离线可读范围限于已写入的文本。

## 4. 单消息图片分享与富内容保真

阅读模式是单消息的独立重渲染面。右键菜单不会截取现有气泡，而是用当前会话定位参数调用 `getOriginalMessageContent`；主进程从对应 `UserData/<owner>/topics/<topic>/history.json` 找到同 ID 消息并返回 `message.content`。查看器接收字符串或 `{text}` 的文本，重新进行 Markdown 与富内容处理。入口和数据查询分别见 `modules/renderer/messageContextMenu.js:293-339`、`modules/ipc/chatHandlers.js:829-859`。

查看器的“截图分享”调用 `domToBlob`，失败时降级为 `domToCanvas`，捕获对象固定为 text viewer 的内容容器 `mainContentDiv`。它按最长边将像素规模限制在 14,000，优先以 DPR 或 2 倍缩放生成 PNG data URL；长内容不是主聊天视口截图，而是该单条消息重排后的完整滚动内容截图。见 `modules/text-viewer.js:2045-2166`。

生成的 PNG 通过主进程短期内存 token 交给图片查看器，避免 URL 长度截断；token 正常消费后删除，兜底保留期为十分钟。图片查看器可把 PNG 复制到剪贴板，或将原图与标注画布合成为 PNG 后触发下载。该交付物不在本地形成应用管理的版本记录。见 `modules/ipc/windowHandlers.js:18-31,186-258`、`modules/image-viewer.js:623-700`。

富内容保真只可确认“查看器另行解析后再截图”，不能等同于聊天气泡像素级复刻。查看器拥有自己的 Markdown/后处理代码；原消息 content 为多模态数组时，阅读模式只接受字符串或 `{text}`，会传入空文本。脚本、外部资源、复杂工具卡和长图的实际渲染结果尚未运行验证。

## 5. 分享稿编辑、版本与远端传播

普通与完整 Topic 导出均不提供导出前预览、内容开关、排版或版本工作台。阅读模式允许编辑该窗口中的原始文本后重新渲染，截图会捕获修改后的查看器内容；但编辑结果只保存在 text viewer 内存，不回写 `history.json`，关闭窗口后不会构成可恢复的分享稿版本。该查看器也可将原始文本交给笔记功能，但笔记对象不属于本类目的对话交付物。见 `modules/text-viewer.js:1361-1430`。

本次未找到远端快照、URL、社交平台/Gist 发布、访问授权、链接撤销、过期策略或分享同步。因此 `E4 链接分享` 和 `E5 发布与研究` 不适用；没有 HTML/PDF 阅读交付。

## 6. 隐私、安全、失败恢复与测试

- 导出没有系统提示词以外的通用敏感字段过滤，且普通模式从渲染文本、完整模式从原始 content 取材；用户需自行判断内容是否适于传播。
- 阅读模式的截图能力仅在取得指定消息原文后出现，故不是任意窗口或桌面截图功能；但生成的图像会含该消息的全部可渲染文本，图片查看器的复制/下载没有额外确认或脱敏。
- 普通导出会在 DOM、消息节点或有效文本缺失时停止并 Toast；完整导出对读取历史异常进行捕获；主进程写文件失败返回错误。保存取消被建模为失败结果，但完整导出专门不对“用户取消”再报错。
- 截图在 blob 为空、Canvas 为空、viewer API 缺失或渲染异常时 alert；存在 blob 到 Canvas 的降级路径和长边限制。没有发现针对超长 Topic DOM、超长 PNG、剪贴板兼容或 Markdown 导出的自动化测试。

## 7. 设计取舍与已确认边界

- 同名 Topic 导出有“可见阅读稿”和“原始内容报告”两条路线：前者继承聊天渲染后的文本结果，后者避免 DOM 截断并补充角色/模型/时间，但两者都不是可往返的会话交换格式。
- 截图分享以单条消息原文为明确抽取边界，再通过独立查看器生成长图。它满足图片分享能力的导出源要求，却不支持多消息选择、问答组、整 Topic 长图或分支选择。
- 图片临时 payload 只为窗口间传递存在，10 分钟 TTL 不是分享保留期；图片是否留存取决于用户复制或下载后的外部环境。
- 本类目不把桌面挂件缩略图、Loom 页面截图或普通图片附件复制算作对话分享：它们的捕获对象不是由聊天消息抽取形成的交付稿。

## 8. 未验证事项

- Electron 实际运行下，普通导出对渐进加载的长 Topic 是否会漏掉尚未插入 DOM 的历史消息。
- Markdown 文件的编码、保存取消、磁盘写入失败和跨平台文件名处理的实际表现。
- 阅读模式与聊天主渲染器在 Markdown、工具结果、Mermaid、数学、HTML、外部图片和脚本上的保真差异。
- 超长消息接近 14,000 像素限制时的缩放清晰度、内存占用、PNG 生成成功率以及复制/下载兼容性。
- 编辑后的阅读模式截图、图片标注与剪贴板结果是否符合预期；本次未运行 UI。

## 9. 关键源码索引

- `modules/topicListManager.js:1158-1174,1229-1406`：两种 Topic 导出菜单、可见 DOM 抽取、原始历史导出
- `modules/event-listeners.js:96-176`：`Ctrl/Cmd+E` 普通导出入口
- `Groupmodules/grouprenderer.js:1120-1168`：群聊可见 Topic 导出提交
- `main.js:1914-1946`：`export-topic-as-markdown` 保存对话框与 UTF-8 写盘
- `modules/renderer/messageContextMenu.js:293-339`：单消息阅读模式入口
- `modules/ipc/chatHandlers.js:829-859`：从 `history.json` 按消息 ID 返回原始 content
- `modules/ipc/fileDialogHandlers.js:381-410`：text viewer 窗口与 base64 内容交接
- `modules/text-viewer.js:1361-1430,2045-2166`：阅读模式编辑、内容容器截图和 PNG 交付
- `modules/ipc/windowHandlers.js:18-31,186-258`：大图 token 缓存与图片查看器窗口
- `modules/image-viewer.js:623-700`：PNG 复制与下载
