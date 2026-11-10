# NextChat 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/ChatGPTNextWeb/NextChat`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`1d3dc331512929a4b1d3e82354e72acce33b5c7a`（分支：`main`）
>
> 调查方式：静态代码阅读；对 `app/` 全部 `*.ts/*.tsx`、`src-tauri/src/*.rs` 与 `docs/` 做关键词扫描（artifact、canvas、sandbox、iframe、webview、notebook、diff、patch、execution、runtime、preview、markdown、plugin、mask、MCP、CRDT、code interpreter），并精读消息存储、Markdown 渲染、artifacts 组件、导出组件与流式工具循环实现文件；未启动应用与测试
>
> 调查范围：生成式输出协议、对象模型、增量更新、投影表面、运行环境、交互编辑、持久化分享、模型回流与资源治理；明确排除 Chat 会话上下文装配、插件/MCP 的注册与调度语义（Agent 工具类目）、插件市场治理与仓库平台分布
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 是纯聊天应用，模型输出全部止步于“消息内的 Markdown 渲染”，没有独立输出对象模型。唯一贴近“生成式输出”的能力是 HTML Artifact 预览（界面标题 NextChat Artifacts）：模型输出的 `<!DOCTYPE html>` 文本或 ` ```html ` 代码块被探测后，在沙箱 iframe 中作为完整 HTML 页面运行，支持重载、全屏、下载单文件，并可经服务端中转上传到 Cloudflare KV 获得 md5 分享链接、通过独立路由 `/artifacts/:id` 重新打开。该能力是渲染期从消息文本临时推导的投影：无稳定对象 ID（分享 id 是内容 md5）、无类型/状态/版本字段、预览内无源码编辑器、模型无对象级查询或定向修改接口，持久化事实源始终是消息文本。

能力等级判定：**主体为 G0（格式化回复）**；HTML Artifact 预览具备 G3 的执行强度（沙箱 iframe 运行 HTML/CSS/JS 且用户可实际操作页面、重载、全屏、下载），但因缺少对象身份、编辑与模型回流，不构成完整 G3 判定，按“G0 主体 + 部分 G3 预览能力”横向描述。DALL-E 3 与 SD 图像输出属于 G1 级别的可查看/复用内容，同样无对象生命周期。插件（OpenAPI 工具）与 MCP 的执行属于 Agent 工具类目，其输出仍物化为普通消息。

## 系统边界与完整主链路

**边界**：生成式输出与运行时只覆盖两条主线——消息内 Markdown/HTML 渲染与分享；SD 图像面板。消息如何进入时间线（Chat）、工具如何调度（Agent 工具）、会话上下文装配均不在本笔记展开。

**主链路（HTML Artifact：触发 → 生成 → 运行 → 交互 → 保存 → 重新打开）**：

1. **触发**：模型在助手消息里输出以 `<!DOCTYPE html>` 开头的裸文本，或围栏标记为 html 的代码块，渲染链路据此判断是否生成预览。
   - 预处理：`tryWrapHtmlCode` 把裸 doctype 文本补成代码块（`app/components/markdown.tsx:249-268`）；
   - 探测：`PreCode` 挂载后，语言为 html 或内容以 doctype、svg、xml 前缀开头时提取 HTML 源码，提取带 600ms 防抖，同一次判定也决定是否允许渲染（`markdown.tsx:83-104`）；
   - 开关：渲染由全局 `enableArtifacts` 与会话 mask 的 `enableArtifacts` 双重控制，两处都开启才生效，两个配置项分别在 `app/store/config.ts:54` 与 `app/store/mask.ts:21`。
2. **生成**：流式 SSE 逐 token 拼接文本，每轮回调把累计全文整体覆盖到 `botMessage.content`，并触发一次状态更新（`app/store/chat.ts:464-472`）；流结束后消息 key 由 `"loading"` 变成 `"done"`，Markdown 随之重挂载并重新提取一次（`app/components/chat.tsx:1970-1972`）。
3. **运行**：`HTMLPreview` 把源码写进 iframe 的 `srcDoc`，并注入脚本回传高度；沙箱只授予表单提交、模态框与脚本执行三项权限。外层容器负责全屏，并附上重载与分享按钮（`app/components/artifacts.tsx:81-105`、`app/components/markdown.tsx:151-171`）。
4. **交互**：页面脚本在 iframe 内运行，用户可以直接操作页面内容、重载与全屏；重载会换一个新 key 重建 iframe，全屏由通用 UI 组件承担（`app/components/artifacts.tsx:64-68`、`app/components/ui-lib.tsx:555`）。预览层没有源码编辑器。
5. **保存**：HTML 源码没有单独落盘，它作为消息文本的一部分由 zustand persist 写入 IndexedDB（`app/utils/store.ts:37`、`app/utils/indexedDB-storage.ts`）。分享时把全文 POST 到 `/api/artifacts`，服务端以内容 md5 为 key 写进 Cloudflare KV，并返回 id 与 `#/artifacts/<md5>` 形式的分享地址（`app/api/artifacts/route.ts:12-50`）。
6. **重新打开**：独立路由 `/artifacts/:id` 由 `Artifacts` 组件按 id 从接口取回全文，再交给同一个 `HTMLPreview` iframe 渲染；页面上还可下载 `.html` 单文件或复制链接（`app/components/home.tsx:177-182`、`app/components/artifacts.tsx:165-227`）。

主链已按静态代码走通；未运行验证（见“未验证事项”）。

## 1. 触发方式、输出协议与对象模型

- **触发方式**：所有预览与输出对象都来自模型自由文本的探测，没有结构化 part、专用标记语言，也没有由工具调用直接产出的对象；HTML 探测规则见 `markdown.tsx:89-99`。
- **Agent 工具交点点**：MCP 请求由围栏标记为 `json:mcp:{clientId}` 的代码块触发，归入 Agent 工具类目（`app/mcp/utils.ts:2-8`）。
- **协议鲁棒性**：渲染链路上没有协议解析层，因此不存在半截流、转义与嵌套的处理；误触发由 `enableArtifacts` 开关和“内容以 doctype/svg/xml 前缀开头”的启发式规则兜底，裸 HTML 补代码块的正则会跳过已经带围栏的内容（`markdown.tsx:94-104`、`252-254`）。
- **对象模型**：消息里没有输出对象类型，消息模型 `ChatMessage` 的字段只有（`app/store/chat.ts:57-66`）：

  ```text
  id / role / date / streaming / isError / model / content / tools / audio_url / isMcpResponse
  ```

  无 artifact/object/version 字段。Artifact 的“id”仅在分享时由 `md5(全文)` 生成（`route.ts:14`），内容变化即 id 变化，无版本与状态。事实源单一：**消息文本**。预览 DOM 与 KV 副本都是从消息文本派生的投影。

## 2. 增量生成、更新与最终化

- 更新粒度：**整段文本覆盖**。所有平台流式实现均为“响应全文累加 + 回调全文覆盖”模式（如 `app/client/platforms/baidu.ts:157-178`、`iflytek.ts:117-135`）：

  ```ts
  responseText += fetchText;
  options.onUpdate?.(responseText, fetchText);
  ```

  `onUpdate` 把累计后的全文写回 `botMessage.content` 并触发状态更新，更新粒度因此只有全文，没有稳定前缀、节点 patch、AST 或文件 diff（`store/chat.ts:464-472`）。
- 最终化按三种收尾路径处理（`store/chat.ts:473-518`）：
  - 正常结束：`onFinish` 置 `streaming=false`、补日期、把消息追加进会话并触发 `onNewMessage`；
  - 失败：错误对象以 JSON 文本追加进消息内容，同时置 `isError`；
  - 中止：由 `ChatControllerPool` 与 `AbortController` 收口。
- Artifact 提取在组件挂载期一次性执行，也就是那个依赖为空的 `useEffect`；流式中途的预览内容以“开始挂载时已收到的文本”为准，流结束后随 `key` 变化重挂载再提取一次（推断：中途更新不会增量刷新 iframe 内容，`markdown.tsx:107-131`）。

## 3. 投影表面与多视图关系

- 消息内（inline）：Mermaid 图与 HTML 预览都嵌在消息正文中，预览位于代码块下方（`markdown.tsx:28-72`、`151-171`）。
- 独立路由（external-ish）：`/artifacts/:id` 由应用自身路由渲染成独立页面，分享链接贴到任何浏览器都能打开同一部署实例（`home.tsx:177-182`）。
- 同一份源码可以同时有多个投影：消息内预览、分享页面、下载的 `.html` 文件与 KV 副本。四份状态之间没有同步机制，下载与分享都取当时的源码快照，任何一方改动都不影响其他；重新打开分享页后的改动只留在该 iframe 内，不会写回消息（`artifacts.tsx:154,177`）。

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

- iframe 高度回传：注入脚本只把 frame id 与高度发给父窗口，父窗口按 id 匹配后更新高度。标题走的是另一条路径：父窗口在匹配之前就读取每条 window message 里的 title，既不检查消息来源，也不校验 id，而注入脚本本身并不发送标题，因此这条通道的来源未经校验，页面标题回报不可靠。见 [监听器](../../NextChat/app/components/artifacts.tsx#L50-L62)、[注入脚本](../../NextChat/app/components/artifacts.tsx#L81-L87)。
- 重载：`reload()` 用 `nanoid` 生成新 key，重建 iframe（`artifacts.tsx:64-68`）。
- 错误反馈：KV 读写失败只弹一个 toast；iframe 内的页面错误没有回传通道（推断：页面内 JS 异常无法观测，`artifacts.tsx:224`、`142`）。
- 交互状态恢复：消息内预览的 iframe 状态随组件重挂载一起丢失；会话重新打开（rehydrate）后，预览从消息文本重新推导，交互状态不会保留（`app/utils/store.ts:39-42`）。
- 消息编辑：全文编辑在 `showPrompt` 弹窗里完成，`EditMessageModal` 负责批量编辑消息列表，两处都没有选区编辑与结构化编辑（`chat.tsx:1815-1839`、`850-912`）。

## 6. 编辑、diff、版本与协作

- 用户可编辑消息全文，从而改变后续重新提取的 HTML 源码；Artifact 预览本身没有源码编辑器、补丁或协作机制。消息编辑属于聊天层，源码重新提取仍受预览挂载时机约束。
- 版本：仅 KV 的 `expiration_ttl`（TTL > 60 秒时启用，`route.ts:24-30`）与 md5 天然的内容寻址，无历史版本。

## 7. 能力桥、执行位置与权限范围

- **HTML 预览**：执行位置是宿主 DOM 内的沙箱 iframe，sandbox 只授予表单提交、模态框与脚本执行三项权限；页面没有 same-origin，因此处于不透明源，读不到宿主存储（推断），下载与弹窗权限同样未开。唯一的宿主桥是用于高度与标题的 postMessage 通道（`artifacts.tsx:96-104`）。
- **插件函数工具**（Agent 工具交点点）：OpenAPI 定义被编译成 function-calling 工具，由浏览器端直接 fetch 外部 API 执行，没有沙箱；返回文本会注入下一轮请求，并以工具状态卡片展示（`app/store/plugin.ts`、`app/utils/chat.ts:457-503`、`chat.tsx:1949-1967`）。
- **MCP**（Agent 工具交点点）：围栏为 `json:mcp:` 的代码块会触发服务端 `executeMcpAction`；执行发生在 Node 服务端进程，经 stdio 子进程连接 MCP server，返回结果作为 `isMcpResponse` 用户消息回流（`store/chat.ts:827-856`、`app/mcp/client.ts:9-39`）。
- **桌面壳**：Tauri 只提供 `stream_fetch` HTTP 代理命令，没有 webview 专属的输出能力；导出图片走 Tauri 对话框与二进制写入（`src-tauri/src/main.rs:8`、`src-tauri/src/stream.rs:34-35`、`exporter.tsx:457-477`）。
- 项目没有能力授予或审批模型，跨域代理策略也没有作用到 iframe 内容上。

## 8. 持久化、恢复、分享与导出

- 消息与 SD 的 draw 列表都由 zustand persist 存进 IndexedDB，会话重新打开时自动 rehydrate（`utils/store.ts:37-42`、`store/sd.ts:159-162`）。
- Artifact 分享先把全文 POST 到 KV（以 md5 为 key，可选 TTL），再由 GET 按 id 取回；服务端依赖一组 Cloudflare 环境变量（`route.ts:12-63`、`app/config/server.ts:245-248`）：

  ```text
  CLOUDFLARE_ACCOUNT_ID / KV_NAMESPACE_ID / KV_API_KEY / KV_TTL
  ```

  未配置时分享不可用（推断，未运行验证）。
- 导出：会话级导出 Markdown/JSON/长图（`app/components/exporter.tsx:140-197`、`ImagePreviewer`）；Artifact 单文件下载（`artifacts.tsx:176-180`）。均按当前消息文本快照导出，不包含 iframe 运行状态。
- 删除/迁移：删除消息会移除本地源码与该消息的预览，但分享副本独立留在 KV；此路由只导出 GET/POST，没有随消息删除清理 KV 的调用。TTL 大于 60 秒时设置过期，否则本段代码未指定过期时间。见 [Artifact 存取路由](../../NextChat/app/api/artifacts/route.ts#L12-L71)。

## 9. 模型回流、对象感知与持续维护

- **不存在对象回流**：模型上下文只装配历史消息文本（`store/chat.ts:542-640`），没有任何输出对象列表、对象级源码读取、运行状态观察或定向修改接口。Artifact 在下一轮只能靠消息文本里的 HTML 源码重新生成，无法引用稳定对象身份。
- MCP 响应作为用户消息回流（`store/chat.ts:844-848`）属于工具结果回流而非输出对象回流。
- 会话总结（`summarizeSession`）只影响记忆文本，不维护输出对象。

## 10. 生命周期、资源治理与性能

- 消息列表分页渲染，页大小由 `CHAT_PAGE_SIZE` 控制：离开视口的消息组件会卸载，它内部的 iframe 随之销毁，代码里没有为定时器或动画单独登记（推断：销毁即释放，`chat.tsx:1387-1402`）。
- iframe 重载靠换 key 重建，旧帧由 React 卸载（`artifacts.tsx:98,66`）。
- 长会话性能由两处策略承担：Markdown 按流式状态换 key 重挂载（`key={streaming ? "loading" : "done"}`），以及 HTML 提取做 600ms 防抖；对象级限额与冻结机制没有实现（`chat.tsx:1971`、`markdown.tsx:83-100`）。
- 声音 TTS 的输出是一条 `audio_url` 消息，按普通媒体播放处理，没有生命周期治理（`chat.tsx:2024-2027`）。

## 11. 测试、已确认边界与未验证事项

**测试**：仓库 34 个测试文件集中在工具函数与协议解析（`test/`），与输出运行时相关者仅四个：

- `extract-mcp-json.test.ts`
- `is-mcp-json.test.ts`
- `create-message.test.ts`
- `format-chunks.test.ts`

**未找到** artifacts 渲染、iframe 沙箱行为、KV 分享、导出、持久化恢复、资源释放等任何测试（检查范围：`test/` 全部文件）。全部结论未经运行验证。

**已确认边界（本次搜索范围：`app/`、`src-tauri/`、`docs/`、`README*.md` 全量文本）**：

- 仓库里没有 notebook、code interpreter 或执行引擎，用 `notebook|sandbox|webview|CRDT|code interpreter` 检索时只命中沙箱 iframe 属性一处（`artifacts.tsx:100`）。
- 输出编辑方面没有 diff、patch、版本或 CRDT 机制；用 `diff|patch` 检索没有命中与输出编辑相关的代码。
- 没有 canvas 或 WebGL 输出对象，也没有桌面挂件与独立应用窗口（Tauri 只做流代理）。
- 仓库里没有介绍 Artifacts 的用户文档：`docs/` 与 `README*.md` 都不含 artifact 字样，唯一的用户可见文案是设置项说明（`app/locales/en.ts:770`）。

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

- **消息文本是唯一事实源**，这一点贯穿各处实现：Artifact 预览不创建任何持久化对象，因此本地预览随消息复制与删除，发布到 KV 的副本则独立保留，但也因此没有身份、版本与定向维护。
- **执行强度与对象能力分离**：iframe 沙箱授予了脚本执行，但除高度回传外没有任何能力桥；这是“展示型运行”而非“运行环境”。
- **两条工具协议分别处理**：MCP 从消息文本中的 fenced block 提取请求；OpenAPI 插件通过原生 `tool_calls` 收集调用并回注工具结果，不依赖普通代码块解析。前者受围栏与 JSON 提取规则约束，后者的执行状态通过消息工具元数据展示；目录、执行和回注细节见 [Agent 工具笔记](<../Agent工具/NextChat-Agent工具调查笔记.md#L17-L22>)。
- **分享依赖自托管服务端**：KV 分享在静态导出（buildMode=export）或未配置 Cloudflare 环境变量时不可用（推断，未验证）。
- **文档与实现不一致**：README/docs 未提及 Artifacts，但代码与设置项文案（`locales/en.ts:770`）存在该能力；本笔记以代码为准。

## 未验证事项

- 未启动应用：流式渲染过程中的 iframe 内容行为、iframe 内页面网络能力、沙箱边界（无 same-origin 时的宿主访问限制）、全屏交互、KV 分享端到端流程、IndexedDB 恢复后预览重建均为静态推断。
- `cloudflareKVTTL` 的解析与 KV 权限错误路径未验证。
- 桌面端（Tauri）下 Artifacts 分享与下载（`tauriFetch`、`downloadAs`）未运行验证。
- 消息虚拟滚动（分页卸载）对 iframe 生命周期的实际影响未运行验证。
