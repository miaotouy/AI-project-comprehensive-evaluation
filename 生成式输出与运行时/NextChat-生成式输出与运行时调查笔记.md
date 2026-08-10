# NextChat 生成式输出与运行时调查笔记

> 调查对象：`../../NextChat`
>
> 调查更新日期：2026-08-10
>
> 代码快照：`706a18b95b714ab29b2a4842d3b9ff4f887935d5`（分支：`main`）
>
> 调查方式：静态代码阅读；对 `app/` 全部 `*.ts/*.tsx`、`src-tauri/src/*.rs` 与 `docs/` 做关键词扫描（artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、execution、runtime、preview、markdown、plugin、mask、MCP、CRDT、code interpreter），并精读消息存储、Markdown 渲染、artifacts 组件、导出组件与流式工具循环实现文件；未启动应用与测试
>
> 调查范围：生成式输出协议、对象模型、增量更新、投影表面、运行环境、交互编辑、持久化分享、模型回流与资源治理；明确排除 Chat 会话上下文装配、插件/MCP 的注册与调度语义（Agent 工具类目）、插件市场治理与仓库平台分布
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 是纯聊天应用，模型输出全部止步于“消息内的 Markdown 渲染”，没有独立输出对象模型。唯一贴近“生成式输出”的能力是 HTML Artifact 预览（界面标题 NextChat Artifacts）：模型输出的 `<!DOCTYPE html>` 文本或 ` ```html ` 代码块被探测后，在沙箱 iframe 中作为完整 HTML 页面运行，支持重载、全屏、下载单文件，并可经服务端中转上传到 Cloudflare KV 获得 md5 分享链接、通过独立路由 `/artifacts/:id` 重新打开。该能力是渲染期从消息文本临时推导的投影：无稳定对象 ID（分享 id 是内容 md5）、无类型/状态/版本字段、不可编辑、模型无法查询或继续修改，持久化事实源始终是消息文本。

能力等级判定：**主体为 G0（格式化回复）**；HTML Artifact 预览具备 G3 的执行强度（沙箱 iframe 运行 HTML/CSS/JS 且用户可实际操作页面、重载、全屏、下载），但因缺少对象身份、编辑与模型回流，不构成完整 G3 判定，按“G0 主体 + 部分 G3 预览能力”横向描述。DALL-E 3 与 SD 图像输出属于 G1 级别的可查看/复用内容，同样无对象生命周期。插件（OpenAPI 工具）与 MCP 的执行属于 Agent 工具类目，其输出仍物化为普通消息。

## 系统边界与完整主链路

**边界**：生成式输出与运行时只覆盖两条主线——消息内 Markdown/HTML 渲染与分享；SD 图像面板。消息如何进入时间线（Chat）、工具如何调度（Agent 工具）、会话上下文装配均不在本笔记展开。

**主链路（HTML Artifact：触发 → 生成 → 运行 → 交互 → 保存 → 重新打开）**：

1. **触发**：模型在助手消息中输出 `<!DOCTYPE html>` 开头的裸文本或 ` ```html ` 代码块。`_MarkDownContent` 在渲染前调用 `tryWrapHtmlCode` 把裸 doctype 文本补成代码块（`app/components/markdown.tsx:249-268`）；`PreCode` 挂载后在 `code.language-html` 或 `<!DOCTYPE`/`<svg`/`<?xml` 前缀命中时提取 `htmlCode`（`app/components/markdown.tsx:83-100`），600ms 防抖。开关为全局 `config.enableArtifacts` 与会话 mask 的 `mask.enableArtifacts` 双重允许（`markdown.tsx:102-104`；`app/store/config.ts:54`；`app/store/mask.ts:21`）。
2. **生成**：流式 SSE 逐 token 拼接文本，`onUpdate` 整体覆盖 `botMessage.content`（`app/store/chat.ts:464-472`）；流结束 `key` 从 `"loading"` 变 `"done"` 触发 Markdown 重挂载并重新提取（`app/components/chat.tsx:1970-1972`）。
3. **运行**：`HTMLPreview` 把源码注入 iframe `srcDoc`，同时注入一段 ResizeObserver 脚本回传高度（`app/components/artifacts.tsx:81-105`），沙箱为 `allow-forms allow-modals allow-scripts`（`artifacts.tsx:100`），外层包 `FullScreen` 容器并附重载按钮与分享按钮（`markdown.tsx:151-171`）。
4. **交互**：页面脚本在 iframe 内运行；用户可操作页面内容、重载（换 key 重建 iframe，`artifacts.tsx:64-68`）、全屏（`app/components/ui-lib.tsx:555`）。无源码编辑。
5. **保存**：HTML 源码不单独落盘，随消息文本存入 IndexedDB（zustand persist，`app/utils/store.ts:37`、`app/utils/indexedDB-storage.ts`）。分享时 POST 全文到 `/api/artifacts`，服务端以 md5 为 key 写入 Cloudflare KV（`app/api/artifacts/route.ts:12-50`；`artifacts.tsx:127-143`），返回 id 与分享 URL `#/artifacts/<md5>`。
6. **重新打开**：独立路由 `/artifacts/:id`（`app/components/home.tsx:177-182`）→ `Artifacts` 组件 GET `/api/artifacts?id=` 取回全文（`artifacts.tsx:212-227`）→ 同一 `HTMLPreview` iframe 渲染；另可下载 `.html` 单文件或复制链接（`artifacts.tsx:165-200`）。

主链已按静态代码走通；未运行验证（见“未验证事项”）。

## 1. 触发方式、输出协议与对象模型

- **触发方式**：全部为**模型自由文本探测**，无结构化 part、无专用标记语言、无工具调用触发的输出对象。HTML 探测规则见 `markdown.tsx:89-99`；MCP 用 ` ```json:mcp:{clientId}` 代码块信息串触发（`app/mcp/utils.ts:2-8`，属 Agent 工具交点点）。
- **协议鲁棒性**：无协议解析层，因此没有半截流、转义、嵌套处理；误触发仅靠 `enableArtifacts` 开关与“以 doctype/svg/xml 前缀开头”的启发式（`markdown.tsx:94-97`）。裸 HTML 补代码块的正则会忽略已含 ``` 的内容（`markdown.tsx:252-254`）。
- **对象模型**：**不存在输出对象类型**。消息模型 `ChatMessage` 仅含 `id/role/date/streaming/isError/model/content/tools/audio_url/isMcpResponse`（`app/store/chat.ts:57-66`），无 artifact/object/version 字段。Artifact 的“id”仅在分享时由 `md5(全文)` 生成（`route.ts:14`），内容变化即 id 变化，无版本与状态。事实源单一：**消息文本**。预览 DOM 与 KV 副本都是从消息文本派生的投影。

## 2. 增量生成、更新与最终化

- 更新粒度：**整段文本覆盖**。所有平台流式实现均为 `responseText += fetchText; options.onUpdate?.(responseText, fetchText)`（如 `app/client/platforms/baidu.ts:157-178`、`iflytek.ts:117-135`），`onUpdate` 将全文写回 `botMessage.content` 并触发状态更新（`store/chat.ts:464-472`）。无稳定前缀、节点 patch、AST 或文件 diff。
- 最终化：`onFinish` 置 `streaming=false`、补日期、追加到会话并触发 `onNewMessage`（`store/chat.ts:473-481`）；失败时把错误对象以 JSON 文本追加进消息内容并置 `isError`（`store/chat.ts:498-518`）。中止由 `ChatControllerPool` 与 AbortController 收口。
- Artifact 提取在挂载期一次性执行（`markdown.tsx:107-131` 的 `useEffect` 依赖为空），流式中途的预览内容以“开始挂载时已收到的文本”为准，流结束后随 `key` 变化重挂载再提取（推断：中途更新不会增量刷新 iframe 内容）。

## 3. 投影表面与多视图关系

- 消息内（inline）：Mermaid 图（`markdown.tsx:28-72`）、HTML 预览嵌于代码块下方（`markdown.tsx:151-171`）。
- 独立路由（external-ish）：`/artifacts/:id` 是应用内独立页面（`home.tsx:177-182`），不是桌面窗口或外部浏览器；分享链接可贴到任何浏览器打开同部署实例。
- 同一源码可有多个投影：消息内预览 + 分享页面 + 下载的 `.html` 文件 + KV 副本。四份状态之间**无同步机制**：下载/分享取当前 `htmlCode` 或 `code` 快照（`artifacts.tsx:154,177`），互相独立，任何一方修改都不影响其他。重新打开分享页后用户改动只存在于该 iframe，不会写回消息。

## 4. 表现类型、依赖与运行环境

| 表现 | 环境 | 依赖 |
|---|---|---|
| Markdown/GFM/KaTeX/代码高亮 | ReactMarkdown 静态 DOM（`markdown.tsx:276-287`） | react-markdown、remark-gfm、rehype-highlight |
| Mermaid 图 | 客户端渲染 SVG，可点击放大查看（`markdown.tsx:28-72`） | mermaid 库 |
| HTML/CSS/JS 页面 | `iframe srcdoc` 沙箱（`artifacts.tsx:96-104`），无 `allow-same-origin`，运行于不透明源 | 无外部依赖注入；iframe 内脚本可自行加载远程资源（推断：沙箱不阻断网络） |
| 图片消息 | `<img>`/点击弹窗（`chat.tsx:1988-2022`；`ui-lib.tsx:452`） | DALL-E 3 返回 URL 存为 `image_url` 内容（`app/client/platforms/openai.ts:128-139`） |
| SD 图像 | `/sd` 独立页面画廊，`draw` 列表（`app/store/sd.ts:21-26`） | Stability API、图片上传 |

无语言解释器、无 WebGL/Canvas 输出对象（`app/components/voice-print/voice-print.tsx` 的 canvas 是语音波形可视化，非输出对象）、无完整项目/桌面挂件。

## 5. 用户交互、事件与错误反馈

- iframe 高度回传：`postMessage({id, height, title})` → 父窗口按 `frameId` 校验后更新高度（`artifacts.tsx:50-62`），这是唯一的沙箱→宿主事件通道。
- 重载：`reload()` 换 `nanoid` key 重建 iframe（`artifacts.tsx:64-68`）。
- 错误反馈：KV 读写失败仅 toast（`artifacts.tsx:224`、`142`）；iframe 内页面错误无回传通道（推断：无法观测页面内 JS 异常）。
- 交互状态恢复：消息内预览的 iframe 状态随组件重挂载丢失；会话重开（rehydrate）后预览从消息文本重新推导，无保留的交互状态（`app/utils/store.ts:39-42`）。
- 消息编辑：全文编辑弹窗 `showPrompt`（`chat.tsx:1815-1839`）；`EditMessageModal` 批量编辑消息列表（`chat.tsx:850-912`）。均无选区/结构化编辑。

## 6. 编辑、diff、版本与协作

- **不存在**：全文覆盖编辑（`chat.tsx:1815`、`mask.tsx:324` 的 `ContextPrompts`），无 diff、无 patch、无 CRDT、无撤销/分支/接受拒绝。Artifact 预览无任何编辑入口。
- 版本：仅 KV 的 `expiration_ttl`（TTL > 60 秒时启用，`route.ts:24-30`）与 md5 天然的内容寻址，无历史版本。

## 7. 能力桥、执行位置与权限范围

- **HTML 预览**：执行位置为宿主 DOM 内的沙箱 iframe（`artifacts.tsx:96-104`），sandbox 属性授予 `allow-forms/allow-modals/allow-scripts`；无 `allow-same-origin`（不透明源，无法访问宿主存储，推断）、无 `allow-downloads`、无 `allow-popups`。唯一的宿主桥是高度/标题 postMessage。
- **插件函数工具**（Agent 工具交点点）：OpenAPI 定义编译为 function-calling 工具（`app/store/plugin.ts`），由浏览器端直接 fetch 外部 API 执行（`app/utils/chat.ts:457-503`），无沙箱；结果文本注入下一轮请求并展示为工具状态卡片（`chat.tsx:1949-1967`）。
- **MCP**（Agent 工具交点点）：` ```json:mcp:` 代码块触发服务端 `executeMcpAction`（`store/chat.ts:827-856`），经 stdio 子进程连接 MCP server（`app/mcp/client.ts:9-39`），结果作为 `isMcpResponse` 用户消息回流（`store/chat.ts:844-848`）。执行在 Node 服务端进程，非浏览器。
- **桌面壳**：Tauri 仅提供 `stream_fetch` HTTP 代理命令（`src-tauri/src/main.rs:8`、`src-tauri/src/stream.rs:34-35`），无 webview 专属输出能力；导出图片走 `__TAURI__.dialog.save` + `fs.writeBinaryFile`（`exporter.tsx:457-477`）。
- 无能力授予/审批模型，无跨域代理策略应用于 iframe 内容。

## 8. 持久化、恢复、分享与导出

- 消息与 SD draw 列表持久化于 IndexedDB（zustand persist，`utils/store.ts:37`、`store/sd.ts:159-162`）；会话重开自动 rehydrate（`utils/store.ts:39-42`）。
- Artifact 分享：POST 全文 → KV（md5 key，可选 TTL）；GET 按 id 取回（`route.ts:12-63`）。依赖服务端环境变量 `CLOUDFLARE_ACCOUNT_ID/KV_NAMESPACE_ID/KV_API_KEY/KV_TTL`（`app/config/server.ts:245-248`），未配置时分享不可用（推断，未运行验证）。
- 导出：会话级导出 Markdown/JSON/长图（`app/components/exporter.tsx:140-197`、`ImagePreviewer`）；Artifact 单文件下载（`artifacts.tsx:176-180`）。均按当前消息文本快照导出，不包含 iframe 运行状态。
- 删除/迁移：无输出对象删除语义；KV 过期依赖 TTL，消息删除即删除对象。

## 9. 模型回流、对象感知与持续维护

- **不存在对象回流**：模型上下文只装配历史消息文本（`store/chat.ts:542-640`），没有任何输出对象列表、源码读取、运行状态观察或定向修改接口。Artifact 在下一轮只能靠消息文本里的 HTML 源码重新生成，无法引用稳定对象身份。
- MCP 响应作为用户消息回流（`store/chat.ts:844-848`）属于工具结果回流而非输出对象回流。
- 会话总结（`summarizeSession`）只影响记忆文本，不维护输出对象。

## 10. 生命周期、资源治理与性能

- 消息列表按页渲染（`CHAT_PAGE_SIZE`，`chat.tsx:1387-1402`）：离开视口的消息组件卸载，其 iframe 随之销毁，无定时器/动画显式登记（推断：销毁即释放）。
- iframe 重载通过换 key 重建（`artifacts.tsx:98,66`），旧帧由 React 卸载。
- 长会话性能：Markdown 重挂载策略 `key={streaming ? "loading" : "done"}`（`chat.tsx:1971`）与 600ms 防抖提取（`markdown.tsx:83-100`）；无对象级限额或冻结机制。
- 声音 TTS 输出 `audio_url` 消息（`chat.tsx:2024-2027`）为媒体播放，无生命周期治理。

## 11. 测试、已确认边界与未验证事项

**测试**：仓库 34 个测试文件集中在工具函数与协议解析（`test/`），与输出运行时相关者仅 `extract-mcp-json.test.ts`、`is-mcp-json.test.ts`、`create-message.test.ts`、`format-chunks.test.ts`。**未找到** artifacts 渲染、iframe 沙箱行为、KV 分享、导出、持久化恢复、资源释放等任何测试（检查范围：`test/` 全部文件）。全部结论未经运行验证。

**已确认边界（本次搜索范围：`app/`、`src-tauri/`、`docs/`、`README*.md` 全量文本）**：

- 无 notebook、code interpreter、执行引擎（关键词 `notebook|sandbox|webview|CRDT|code interpreter` 仅命中 `artifacts.tsx:100` 的 iframe sandbox 属性一处）。
- 无 diff/patch/版本/CRDT 编辑机制（关键词 `diff|patch` 无输出编辑相关命中）。
- 无 canvas/WebGL 输出对象；无桌面挂件/独立应用窗口（Tauri 仅流代理）。
- 仓库内无 Artifacts 的用户文档（`docs/` 与 `README*.md` 中无 artifact 字样；唯一文案是 `app/locales/en.ts:770` 的设置项说明）。

## 12. 关键源码索引

- `app/components/markdown.tsx:83-174`：HTML/Mermaid 探测与预览入口（PreCode、renderArtifacts）
- `app/components/artifacts.tsx:36-107`：HTMLPreview 沙箱 iframe；`109-203` 分享按钮；`205-266` 独立页面
- `app/api/artifacts/route.ts:12-63`：Cloudflare KV 存取，md5 id
- `app/store/chat.ts:57-76`：ChatMessage 对象模型；`464-527` 流式更新与最终化；`827-856` MCP 触发
- `app/utils/chat.ts:448-522`：工具循环与整段文本收口
- `app/utils/store.ts:29-78`：IndexedDB 持久化与 rehydrate
- `app/components/chat.tsx:1815-1839,850-912`：全文编辑；`1949-1967` 工具卡片
- `app/components/home.tsx:177-182`：`/artifacts/:id` 路由
- `app/store/sd.ts:21-162`：SD 图像持久化列表
- `app/mcp/client.ts:9-39`：stdio 子进程执行位置

## 设计取舍与已确认边界

- **以消息文本为唯一事实源**是贯穿设计：Artifact 预览不创建任何持久化对象，因此“对象”天然随消息复制、分享和删除，但也因此没有身份、版本与定向维护。
- **执行强度与对象能力分离**：iframe 沙箱授予了脚本执行，但除高度回传外没有任何能力桥；这是“展示型运行”而非“运行环境”。
- **MCP/插件走消息内标记而非 typed part**：` ```json:mcp:` 与 OpenAPI 工具调用都与普通代码块同通道，协议开放度低、误触发由前缀启发式兜底，换来的是零渲染层改动。
- **分享依赖自托管服务端**：KV 分享在静态导出（buildMode=export）或未配置 Cloudflare 环境变量时不可用（推断，未验证）。
- **文档与实现不一致**：README/docs 未提及 Artifacts，但代码与设置项文案（`locales/en.ts:770`）存在该能力；本笔记以代码为准。

## 未验证事项

- 未启动应用：流式渲染过程中的 iframe 内容行为、iframe 内页面网络能力、沙箱边界（无 same-origin 时的宿主访问限制）、全屏交互、KV 分享端到端流程、IndexedDB 恢复后预览重建均为静态推断。
- `cloudflareKVTTL` 的解析与 KV 权限错误路径未验证。
- 桌面端（Tauri）下 Artifacts 分享与下载（`tauriFetch`、`downloadAs`）未运行验证。
- 消息虚拟滚动（分页卸载）对 iframe 生命周期的实际影响未运行验证。
