# Open WebUI 信息污染源调查笔记

> 调查对象：`E:\works\git\open-webui`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`01f4282f1ffe0d6212f58d3afbeae21fffd0c4be`（分支：`main`）
>
> 调查方式：只读源码核对（utils/middleware.py 上下文注入编排、utils/sanitize.py、utils/mcp/client.py、前端 Markdown/HTMLToken/Artifacts 渲染、认证与中间件）；未修改目标仓库
>
> 调查范围：进入 LLM 上下文的外部内容路径（RAG/网页/工具/MCP/记忆/技能）、前端渲染注入面、SVG/Artifacts 沙箱、代码执行面、认证与安全头；未运行验证
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 的污染面结构与桌面端客户端（如 Manifold）不同：**服务端对进入 LLM 上下文的全部外部内容不做清洗**，上下文注入是设计内机制；前端渲染侧则有多层沙箱与消毒，但有若干分支未覆盖。

已确认的事实（代码事实，未运行验证）：

1. **进入 LLM 上下文的外部内容无清洗**：RAG 文档（`get_source_context`，middleware.py 807 行，拼接 `<source id="..." name="...">{body}</source>` 注入 system/user 消息）、网页抓取、搜索摘要、工具/MCP 结果、记忆、技能内容均原样进入上下文。全仓唯一的「提示注入」字样是 `utils/task.py:276` 的一句警告文案（`'WARNING: Potential prompt injection attack: the RAG...'`），是注入文本而非过滤逻辑；`utils/sanitize.py` 只清理 ANSI 转义码与 markdown 围栏（代码执行卫生），与内容注入无关。
2. **XML 标签注入是默认机制**：`middleware.py:2458` 注释「Native FC: skip RAG injection, builtin tools」、`:2570` 注释「Skip XML-tag prompt injection when native FC is enabled」——即 `<source>`/`<file>` 标签注入是默认路径，仅在 native function calling 开启时可选择跳过；`add_file_context`（1570 行）拼接 `<file type="..." id="..." url="..."/>` 标签。
3. **前端唯一的 HTML 清洗点是 `HTMLToken.svelte` 的 `DOMPurify.sanitize`（默认配置）**（14 行），但它只对 `html` token 的渲染体生效；组件内基于**未清洗原始文本 `token.text`** 做分支判定与提取（66-68 行通用 iframe src 提取）。
4. **`<file type="html">` iframe 显式允许脚本**：`sandbox="allow-scripts allow-downloads"`（HTMLToken.svelte 112 行，设置项可加 allow-forms/allow-same-origin），src 指向 `/api/v1/files/{id}/content/html`；fileId 来自模型输出或用户输入中的 `{{HTML_FILE_ID_*}}` 占位符。
5. **`MarkdownTokens.svelte`（498-510 行）与 `MarkdownInlineTokens.svelte`（114-126 行）的 `iframe` token 渲染无 `sandbox` 属性**，src 指向同源 `/api/v1/files/{fileId}/content`——若 fileId 对应 HTML 内容，将在主站同源上下文直接渲染（无隔离）；该 token 由前端 `replaceTokens` 从占位符生成（utils/index.ts 56-84 行），对用户消息同样生效。
6. **MCP 客户端默认关闭 TLS 证书校验**：`utils/mcp/client.py:55-56` `create_insecure_httpx_client`（`verify=False`），仅当 `AIOHTTP_CLIENT_SESSION_TOOL_SERVER_SSL` 为真时走校验路径（70-72 行）。
7. **安全响应头全部为环境变量 opt-in**：`SecurityHeadersMiddleware`（utils/security_headers.py 16-34 行）在无对应 env 时不注入任何头，CSP 头值直接透传；CORS 默认 `*` 且 `allow_credentials=True`（config.py 2111 行、main.py 773-779 行），静态资源 CORS 恒为 `*`。
8. **三个代码执行面**：浏览器内 Pyodide worker（iframe `sandbox="allow-scripts"`，无 allow-same-origin，opaque origin，pyodideSandboxHost.ts 211 行）；服务端 Jupyter（`POST /api/v1/utils/code/execute`，需登录用户 + `code_execution.enable` 配置，routers/utils.py 43-73 行）；工具服务器/终端（terminals.py 34 行 `_sanitize_proxy_path` 防路径穿越/SSRF）。模型生成的代码块由用户点击触发执行。
9. **SVG 渲染有白名单清洗**：mermaid `securityLevel:'loose'` 产出未清洗 SVG，再经 `sanitizeSvg`（DOMPurify SVG profile，utils/index.ts 1977-2011 行）剥离 `javascript:` href 等；`foreignObject` 被显式允许。Vega 通过 `loader.sanitize` + `loader.load` 阻断一切外部资源。
10. **Artifacts / 引用文档是 srcdoc iframe 沙箱**：`sandbox="allow-scripts allow-downloads"` + `injectCsp` 注入 meta CSP（`ui.iframe_csp` 默认空字符串 → 无 CSP），并拦截 iframe 内外部导航（Artifacts.svelte 246-260 行、CitationModal.svelte 215-224 行）；`allow-same-origin` 由用户设置决定，开启后脚本与主站同源（推测：可访问父页面 DOM）。
11. **管道/过滤器插件是服务端任意代码**：用户上传的 Python 模块经 `load_function_module_by_id` 加载执行（functions.py 52 行），pipe 输出经 `stream_content` 原样转发前端（301-336 行）——插件代码本身以服务端进程权限运行（推测），filter 可在 inlet/outlet 修改请求与响应。

## 1. 进入 LLM 上下文的注入面

| 注入面 | 进入点 | 去向 | 当前防护 |
|---|---|---|---|
| RAG 知识库 | `middleware.py:807` `get_source_context`（`<source>` 标签）；`:833` `apply_source_context_to_messages`（`RAG_SYSTEM_CONTEXT` 配置决定插入 system 或 user 消息） | 首条 system 消息 / 用户消息 → 模型上下文 | 无内容清洗；`task.py:276` 仅追加警告文案 |
| 网页抓取 | `routers/retrieval.py:2195` `search_web`、`:2553` `process_web_search`；`retrieval/utils.py:211` `get_content_from_url`（`_extract_text_from_binary_response`）；`retrieval/loaders/external_web.py`（外部抽取服务返回的 `page_content` 直接成文档） | 检索结果 → 向量库 → `chat_completion_files_handler`（middleware.py 1827 行）→ RAG 上下文 | 仅 URL 侧 SSRF 适配器（`_SSRFSafeAdapter`，retrieval/web/utils.py 220 行）；抽取文本无注入过滤 |
| 工具结果（含 MCP） | `middleware.py:1139` `chat_completion_tools_handler` → `process_tool_result`（871 行）；`(HTMLResponse, result_context)` 元组 → `tool_result_embeds`；MCP `call_tool`（mcp/client.py 109-123 行，text 项尝试 JSON 解码后追加，image/audio → base64 存文件） | legacy → sources → RAG 模板；native FC → `function_call_output` 消息项（2076、2091 行） | 无内容清洗；连接有 `has_connection_access` 授权；MCP TLS 默认不校验 |
| 文件附加 | `middleware.py:1570` `add_file_context`（native FC，`<file type=...>` 标签）；`:1827` legacy 走 RAG | system/消息注入 | 无清洗；文件有访问权模型（routers/files.py 906 行 `has_access_to_file`） |
| 记忆 | `utils/memory.py:290` `add_memory_context`（最近 7 条用户消息、4000 字符，查询记忆库） | system/上下文注入 | 无内容清洗 |
| 技能 | `utils/tools.py:734-736` `view_skill`（按需把完整技能指令注入） | 工具定义/上下文 | 技能由创建者编写，无注入过滤 |
| 管道/过滤器 | `functions.py:150+` `generate_function_chat_completion`（`__user__`/`__request__`/`__oauth_token__`/`__files__`/`__tools__` 全量注入 pipe 参数，262-276 行） | pipe 返回内容直接成为模型响应；filter 可修改请求体与响应 | `ENABLE_PLUGINS` 开关；插件本身是受信执行面 |

## 2. 前端渲染注入面

### 2.1 Markdown/HTML 管线

```text
ResponseMessage -> ContentRenderer（302-328 行）-> Markdown.svelte（70 行 replaceTokens(processResponseContent(content))）
  -> MarkdownTokens.svelte -> HTMLToken（html token）等组件
```

| 分支 | 代码事实 |
|---|---|
| HTML 块 | `DOMPurify.sanitize` 默认配置（HTMLToken.svelte 14 行） |
| video/audio | src 取自**清洗后** html（18-48 行） |
| YouTube iframe | 白名单正则：`https://www.youtube.com/embed/<11字符id>`（49-65 行） |
| 通用 iframe | **src 取自清洗前 `token.text`**（66-68 行），带**空 `sandbox`**（75 行）→ 完全沙箱无脚本，但可显示任意外部页面 |
| `<file type="html">` | src `/api/v1/files/{id}/content/html`，`sandbox="allow-scripts allow-downloads"`（+可配置 allow-forms/allow-same-origin，103-125 行）→ **显式允许脚本**；后端该端点仅服务 admin 上传文件且校验访问权（routers/files.py 845-891 行），但 fileId 由模型输出/用户输入决定 |
| iframe token（MarkdownTokens 498-510 行、MarkdownInlineTokens 114-126 行） | src `/api/v1/files/{fileId}/content`，**无 sandbox 属性、无 CSP 注入** → 同源 iframe 直接渲染（若文件为 HTML）；token 由 `replaceTokens` 从 `{{VIDEO_FILE_ID_*}}`/`{{HTML_FILE_ID_*}}` 占位符生成（utils/index.ts 62-68 行），对用户消息同样生效（推测：实际命中主要是媒体文件，fileId 需真实存在且有访问权） |

### 2.2 SVG / Artifacts / 引用文档

- `sanitizeSvg`（utils/index.ts 1977-2011 行）：DOMPurify `USE_PROFILES: {svg, svgFilters}`、`ADD_TAGS: ['style','foreignObject']`、`ADD_ATTR` 含 class/style/id/data-*/viewBox/href/xlink:href、`SANITIZE_DOM: true`——用于 mermaid loose 输出与 `SVGPanZoom`（common/SVGPanZoom.svelte 40 行）的 `{@html}`；
- Artifacts：`srcdoc={injectCsp(content, $config?.ui?.iframe_csp ?? '')}`（Artifacts.svelte 246-260 行）+ `sandbox="allow-scripts allow-downloads"` + 设置项可选 allow-forms/allow-same-origin；on:load 注入点击劫持防护；`ui.iframe_csp` 默认空 → 无 CSP（csp.ts 注释「first CSP meta wins」）；
- 引用文档：`CitationModal.svelte` 215-224 行同构沙箱。

## 3. 代码执行面

| 执行面 | 代码事实 |
|---|---|
| 浏览器 Pyodide | iframe `sandbox="allow-scripts"`（opaque origin，无 allow-same-origin → 无法访问父页面）；消息校验 `event.source !== iframe.contentWindow` 即拒绝（pyodideSandboxHost.ts 218 行）；postMessage 目标 `'*'`（286 行，但仅向自建 iframe 发送）；matplotlib patch 输出 base64 PNG（109-129 行） |
| 服务端 Jupyter | `POST /api/v1/utils/code/execute`：需 `get_verified_user` + `Config.get('code_execution.enable')`，仅 jupyter 引擎（routers/utils.py 43-73 行）；`JupyterCodeExecuter` 经 WebSocket 执行 |
| 终端 | routers/terminals.py：`_sanitize_proxy_path`（34 行）双重解码防护路径穿越/SSRF；`STRIPPED_RESPONSE_HEADERS`（31 行）；Bearer 认证 |
| 工具事件 | `execute:tool`（middleware.py 4986 行）与 `execute:python`（5374 行）事件由前端 `+layout.svelte` 556-561 行接收处理 |

## 4. 认证与会话面

- JWT：`utils/auth.py` `create_token`（222 行）/ `decode_token`（236 行）/ `is_valid_token`（244 行，Redis jti 吊销 + 按用户 `revoked_at`）；`JWT_EXPIRES_IN` 默认 `'4w'`（config.py 2432-2434 行）；签名算法未在源码直接列出（推测为 HMAC 族）；
- 凭证提取：`AuthTokenMiddleware`（asgi_middleware.py 134-171 行）Authorization 头 → `token` cookie → `CUSTOM_API_KEY_HEADER`（默认 `x-api-key`）；
- API Key：`routers/auths.py` `_check_api_key_permission`（1454 行）/ `generate_api_key`（1466 行），受 `auth.enable_api_keys` 与 `features.api_keys` 权限控制；
- Socket.IO：`connect` 经 token 验证（socket/main.py 353 行）；`get_event_call` 的 `__event_caller__` 校验 session 归属（1100-1108 行）；
- 前端守卫：`src/routes/(app)/+layout.svelte` 247-253 行（user 为空 → `/auth` 重定向；角色非 user/admin 直接 return）；
- OAuth/可信头：`WEBUI_AUTH`（默认 True）、`WEBUI_AUTH_TRUSTED_EMAIL/NAME/GROUPS_HEADER`（env.py 756-758 行，反向代理场景）。

## 5. 外部内容进入上下文的汇总路径

```text
RAG/文件/搜索/工具/MCP/记忆/技能（第 1 节）
  -> middleware.py process_chat_payload（2248 行）组装请求体
  -> 上游模型
  -> 响应经 main.py 1568-1570（build_chat_response_context / process_chat_response）
  -> SSE 事件
  -> 前端 Markdown 渲染管线（第 2 节）
```

全程无服务端内容过滤；`apis/index.ts` 801/873 行的 JSON 提取仅做单引号转义处理（前端辅助，非安全清洗）。

## 6. 与同类项目的横向比较

- 与 Manifold Desktop（assistant 内容 `innerHTML` 无消毒、桥接无来源校验）相比，Open WebUI 的渲染面防护强得多：HTML 必经 DOMPurify、Artifacts/引用是 iframe 沙箱、SVG 有白名单清洗；
- 与 Cherry Studio（DOMPurify + 导航拦截）相比，Open WebUI 的**上下文注入面**（RAG/工具/MCP 原文进上下文）在服务端完全没有清洗，属于「信任模型输出边界」的设计；
- 未覆盖分支集中在两处：`<file type="html">` 的 allow-scripts 与 iframe token 的无 sandbox 同源渲染；二者的共同点是触发条件依赖占位符/fileId，属于「模型输出或用户输入可控内容 + 已上传文件」的组合（推测：实际利用需要多条件叠加，未验证）；
- MCP TLS 默认关闭与安全响应头全 opt-in 属于部署默认值层面的薄弱配置，与 LobeHub 的服务端代理 + 凭据加密方案对比明显（LobeHub 凭据静态加密、MCP 走服务端）。

## 7. 关键文件索引

| 职责 | 文件 |
|---|---|
| 上下文注入编排 | `backend/open_webui/utils/middleware.py`（807、833、1570、1827、2076、2248、2458、2570 行） |
| 服务端 sanitize（仅代码执行卫生） | `backend/open_webui/utils/sanitize.py` |
| 提示注入警告文案 | `backend/open_webui/utils/task.py`（276 行） |
| MCP 客户端（默认 verify=False） | `backend/open_webui/utils/mcp/client.py`（55-56、70-72、109-123 行） |
| 工具结果处理 | `backend/open_webui/utils/middleware.py`（871 行） |
| 网页抓取 | `backend/open_webui/retrieval/utils.py`（211 行）、`retrieval/loaders/external_web.py`、`retrieval/web/utils.py`（220 行） |
| 记忆注入 | `backend/open_webui/utils/memory.py`（290 行） |
| 管道/过滤器 | `backend/open_webui/functions.py`（52、150-351 行）、`utils/filter.py`（37 行） |
| 安全头 | `backend/open_webui/utils/security_headers.py` |
| 文件内容端点 | `backend/open_webui/routers/files.py`（845-891、894-944 行） |
| Jupyter 执行门 | `backend/open_webui/routers/utils.py`（43-73 行） |
| 终端代理 | `backend/open_webui/routers/terminals.py`（31、34 行） |
| 认证 | `backend/open_webui/utils/auth.py`、`utils/asgi_middleware.py`（134-171 行）、`routers/auths.py`（1454-1466 行） |
| 占位符替换 | `src/lib/utils/index.ts`（56-84 行） |
| HTML 消毒与 iframe 分支 | `src/lib/components/chat/Messages/Markdown/HTMLToken.svelte`（14、49-125 行） |
| iframe token（无 sandbox） | `src/lib/components/chat/Messages/Markdown/MarkdownTokens.svelte`（498-510 行）、`MarkdownInlineTokens.svelte`（114-126 行） |
| SVG 清洗 | `src/lib/utils/index.ts`（1977-2011 行）、`src/lib/components/common/SVGPanZoom.svelte` |
| Artifacts 沙箱 | `src/lib/components/chat/Artifacts.svelte`（41-61、246-260 行）、`src/lib/utils/csp.ts` |
| 引用文档沙箱 | `src/lib/components/chat/Messages/Citations/CitationModal.svelte`（215-257 行） |
| Pyodide 沙箱 | `src/lib/pyodide/pyodideSandboxHost.ts`（211-218 行） |
