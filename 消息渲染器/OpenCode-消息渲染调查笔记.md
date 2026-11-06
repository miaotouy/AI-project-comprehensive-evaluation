# OpenCode 消息渲染器调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：只读源码静态梳理消息内容模型、事件到 store 的投影、时间线行模型、渲染组件、markdown 管线与性能策略；未运行构建与浏览器验证
>
> 调查范围：共享渲染层（`packages/session-ui`）、App 侧虚拟列表与数据装载、TUI 渲染链路与桌面壳层边界；视觉效果与交互行为需运行验证
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

OpenCode 2.x 的 Web/桌面消息渲染由 `packages/session-ui` 提供，App 补充虚拟列表、滚动与数据装载；TUI 使用独立的终端行分组、消息与 markdown 组件。两套表现层读取同一带类型消息模型及助手内容数组。Web 的消费入口为 [message-timeline.tsx](../../opencode/packages/app/src/session/timeline/message-timeline.tsx#L20-L22)，终端组件装配见 [TUI 会话页](../../opencode/packages/tui/src/routes/session/index.tsx#L105-L134)。

流式更新分两层：服务端 durable 事件先投影到客户端消息存储，再由时间线投影（`timeline/projection.ts`）生成行模型；文本正文另走节流渲染（24ms 步进）与按块的 markdown 增量更新。markdown 管线为「marked 切块 → Web Worker 解析与高亮 → DOMPurify 清洗 → 把 HTML 解析成节点树后用 Solid 渲染根按 key 增量更新」，代码高亮改用 `@pierre/highlights`，并新增 Mermaid 渲染。

## 总体渲染链路

```text
durable 事件（session.text.delta / tool.* / step.*）
  -> App 事件源（runtime/server/client.tsx）与同步层
  -> 消息存储（SessionMessage.Info 与内容数组）
  -> 时间线投影（session-ui/src/timeline/projection.ts）
       constructSessionMessageRows -> TimelineRow 行模型
  -> App 虚拟列表（session/timeline/virtualizer.tsx）
  -> 行渲染（timeline/session-timeline-row.tsx）-> 消息内容（message/message-content.tsx）
  -> 工具渲染器（tools/tool-renderer.tsx）
  -> 文本：节流 + markdown 管线（components/markdown.tsx）
       marked 切块 -> Worker 解析/高亮 -> DOMPurify -> 节点树 -> Solid 增量更新
```

## 1. 消息内容模型

- 消息是带类型的联合：用户、助手、系统、合成、技能、shell、压缩、空闲与三类状态切换（见会话与消息管理笔记）。渲染器按类型分派，助手消息再按内容项渲染。
- 助手内容项三种：文本、推理、工具。工具项带流式输入、运行中、完成、失败等状态与结果内容。
- 对话轮次由空闲消息收口：时间线把每轮用户输入到空闲标记之间的步骤归为一段（`timeline/user-runs.ts`）。
- 文件与图片附件在消息中以引用形式存在，渲染时按需取字节。

## 2. 时间线行模型

行模型是渲染的核心抽象（`packages/session-ui/src/timeline/timeline-row.ts`），覆盖：

| 行类型 | 用途 |
|---|---|
| TurnGap | 轮次之间的间隔 |
| UserMessage | 用户消息 |
| Shell / Notice | shell 执行与系统提示行 |
| TurnDivider | 轮次分隔 |
| AssistantPart | 助手内容分组（单条或上下文组） |
| Thinking | 推理摘要行 |
| Error / Retry | 错误与重试状态 |
| CompactionQueued | 待执行的压缩 |
| TurnDiff | 轮次级文件变更 |
| Activity | 执行活动摘要 |

- **投影**：`constructSessionMessageRows` 与 `constructMessageRows` 把消息与内容项转成行（`projection.ts:242、482`）；连续的文件读取类工具会合并成上下文组，工具组按类型聚合。
- **行复用**：`reuseTimelineRows`（`projection.ts:777`）按 key 复用上一帧的行对象，避免整表重建。
- **内容定位**：`resolveContent`/`contentEntries` 提供按内容 id 查找与遍历（`projection.ts:639、650`）。

## 3. 虚拟化、滚动与度量

- **虚拟列表**：App 用 `@tanstack/solid-virtual`（`packages/app/src/session/timeline/virtualizer.tsx`），行绝对定位并按测量结果更新高度；滚动锚定与末尾跟随由 App 层负责。
- **自动滚动**：贴近底部、用户上滚、内容追加等条件决定是否回贴底部；实现集中在 App 的时间线控制器与虚拟化辅助函数。
- **锚点**：会话/hash 锚点定位走 App 的滚动辅助逻辑，与自动滚动互斥。
- **行高缓存**：测量快照缓存有限条数，避免切会话后重新测量。

## 4. 消息壳层与角色分派

- **用户消息**：文本、引用、附件与操作栏（复制、回退、编辑）。
- **助手消息**：按内容数组顺序渲染，最后一个非空文本项显示元信息（Agent、模型、耗时、是否中断）。
- **推理内容**：默认折叠为摘要行，展开后按 markdown 渲染。
- **操作栏与头部菜单**：会话头部提供重命名、导出、归档、删除等命令；消息级提供复制与回退。

## 5. Markdown 与代码高亮管线

- **切块**：`markdown-stream.ts` 用 marked 的 lexer 切成块，流式时只投影尾部块并补全未闭合语法；mermaid 与 code 块单独成类。
- **解析与高亮**：`markdown.worker.ts` 在 Web Worker 内解析；代码高亮用 `@pierre/highlights` 的 `codeToTokens` 与流式 `LiveTokenizer`，主题来自 `@opencode/ui/context/highlight-theme` 的 OpenCode 主题。
- **清洗**：`markdown-cache.tsx` 用私有 DOMPurify 实例清洗非代码块 HTML，禁止 style/script 内容，允许 svg/path 等必要标签。
- **DOM 更新**：`markdown-solid.tsx` 把清洗后的 HTML 解析成带 key 的节点树，用 Solid 的 `render` 与 store 的 `reconcile` 增量更新；代码块按 token 增量追加或裁剪。
- **装饰**：代码块外壳与复制按钮、内联代码分类（路径/URL）、内联 URL 转链接、表格横向滚动、Mermaid SVG 渲染（`markdown-mermaid.ts`）。
- **主题与缓存**：markdown 渲染结果有 LRU 缓存；首页会预载常用 markdown。
- **数学**：katex 支持行内与块级公式；mermaid 由独立渲染函数生成 SVG。

## 6. 工具渲染

- **工具渲染器**：`tools/tool-renderer.tsx` 按工具名分派到专用组件，覆盖 `read`/`list`/`glob`/`grep`/`browser`/`webfetch`/`websearch`/`subagent`/`shell`/`execute`/`edit`/`write`/`patch`/`question`/`skill` 等；未识别的工具走通用壳。
- **通用壳**：`basic-tool.tsx` 提供折叠容器、状态副标题、参数摘要、延迟挂载与高度动画。
- **输出渲染**：搜索结果走 markdown 或列表；shell 输出去掉 ANSI 后按等宽文本渲染；编辑/写入/补丁用 diff 视图（`pierre` 包）；错误统一错误卡片。
- **上下文组**：连续读取类工具合并成可折叠组，减少时间线噪音。
- **待办与提问**：`todowrite` 渲染为只读清单；`question` 以交互表单呈现。

## 7. 安全隔离

- 非代码块 HTML 一律经 DOMPurify 清洗后才进入 DOM。
- 链接统一加 `target="_blank"` 与 `rel="noopener noreferrer"`；图片协议走清洗器的 URI 白名单。
- Mermaid 渲染输出 SVG，仍经过外壳清洗与样式约束。
- 文件插件另有 HTML/PDF 专用预览入口，超出普通消息 markdown 的清洗管线。HTML 经 Blob URL 放入 iframe，sandbox 允许脚本、弹窗、表单和模态框，未授予同源权限；PDF 使用浏览器查看器（[artifact-view.tsx](../../opencode/packages/gui-plugins/src/file/artifact-view.tsx#L624-L638)）。托管 Artifact 的 HTTP 文件响应另设 CSP `sandbox allow-scripts`（[视图处理器](../../opencode/packages/server/src/handlers/artifact.ts#L210-L224)）。

## 8. 交互反馈与可访问性

- **复制**：消息、代码块、diff 都有复制入口，复制成功后短暂切换状态图标。
- **折叠**：工具与推理内容可折叠，折叠状态按会话记忆。
- **重试**：重试状态由独立组件展示尝试次数与倒计时。
- **审批与问答**：审批 dock 与提问表单属于 Composer 区域（见 Chat UI 笔记），渲染层只提供展示组件。
- **可访问性**：键盘导航、ARIA 与读屏细节本次未展开，需运行验证。

## 9. 性能策略

- 时间线投影与行复用避免整表重建；虚拟列表只渲染可见行。
- 文本正文节流渲染（24ms 步进），长文本不会每帧全量重排。
- markdown 解析与高亮在 Worker 中执行，主线程只做节点树更新；每个 key 单活跃解析任务，过期任务被替换。
- 代码 token 增量更新只处理尾部变化；完成的块整体替换。
- 缓存：markdown LRU、行高快照、图片预览按需创建。

## 10. TUI 与桌面端边界

- **TUI**：复用 `session-ui` 的内容组件与工具渲染器；markdown 由终端渲染层处理（语法高亮与表格按终端能力降级），时间线由 TUI 自己的会话视图组织。
- **桌面端**：渲染完全复用 App，Electron 主进程只负责窗口、文件选择、外部链接与本地服务端管理；preload 注入平台能力。

## 11. 未验证事项

1. 未运行浏览器：虚拟列表滚动、增量 DOM 更新与流式节流的视觉效果与性能未实测。
2. DOMPurify 默认 URI 白名单对图片与链接协议的实际拦截行为未运行验证。
3. Worker 解析在超长消息与高并发流式下的行为未实测。
4. TUI 终端高亮与表格在窄终端下的降级效果未验证。
5. 无障碍与主题切换的运行时行为未展开验证。

## 12. 关键源码索引

- `packages/session-ui/src/timeline/timeline-row.ts`：行模型
- `packages/session-ui/src/timeline/projection.ts`：行投影与复用
- `packages/session-ui/src/timeline/session-timeline.tsx`、`session-timeline-row.tsx`：时间线组件
- `packages/session-ui/src/message/message-content.tsx`：消息内容渲染与节流
- `packages/session-ui/src/tools/tool-renderer.tsx`：工具渲染分派
- `packages/session-ui/src/components/markdown.tsx`、`markdown.worker.ts`、`markdown-stream.ts`、`markdown-cache.tsx`、`markdown-solid.tsx`：markdown 管线
- `packages/app/src/session/timeline/virtualizer.tsx`、`controller.tsx`：虚拟列表与滚动
- `packages/app/src/runtime/server/`：客户端事件与数据装载
- `packages/ui/src/context/marked-base.tsx`、`highlight-theme`：解析器基础与高亮主题
