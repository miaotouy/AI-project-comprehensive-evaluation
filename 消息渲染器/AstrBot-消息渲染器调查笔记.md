# AstrBot 消息渲染器调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`a9bb8a64ca69657e6262e3ca06541ecaf3a6d1ca`（分支：`master`）
>
> 调查方式：只读源码与仓库文档交叉梳理；未修改目标仓库
>
> 调查范围：消息组件体系、消息链与结果模型、事件发送入口、装饰/发送阶段、平台出站入站转换、流式、WebChat 前后端渲染管线、媒体转换与文件服务
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 的消息渲染是"**统一组件链 + 平台自治转换**"架构：LLM 输出与插件结果先归一化为 `MessageChain`（`BaseMessageComponent` 列表），再交给各平台适配器自行转换为平台消息格式；**没有统一的转换函数**，每个适配器自实现出站/入站。组件体系源自 MIT 许可的 Lxns-Network/Naku 项目（components.py:1-22 许可证头）。

关键事实（快照 a9bb8a6）：

- **组件体系**：组件枚举 22 种，基类提供同步/异步双轨序列化（`toDict` 与 `to_dict`），并覆写 repr 把 base64 与超长字段截断，日志与异常输出自动安全（components.py:35-110）。
- **业务语义元协议**：`MessageChain.type` 字段（message_event_result.py:33-34）承载 `tool_call`/`reasoning`/`audio_chunk` 等业务语义，仅 WebChat 出站序列化与前端消费，其他平台忽略。
- **装饰阶段做链重写**（result_decorate/stage.py:21-439）：集中完成思考内容注入、TTS 文本转音频、文本转图、超长转发和 @/Reply 前缀五类重写，细节见 §4.1 表格。
- **RespondStage 分段发送**（respond/stage.py:169-325）：校验组件有效性、提取 Reply/At 为"头"、Record 强制单独发、间隔随机防风控、流式直通与重复文本防重，细节见 §4.2。
- **平台层处理长度与协议差异**：Telegram 4096 逐级切分、LINE 5000 截断、aiocqhttp 缓冲合并或句号切分双策略、QQ 官方 Markdown 流式、Satori 转义等。
- **WebChat 半开放协议**：出站 `{"type","data",...}` + `[IMAGE]/[RECORD]/[FILE]` 前缀字符串（webchat_event.py:50-149），前端反向解析；历史记录走结构化 parts（message_parts_helper.py）。
- **前端渲染**：`messageBlocks()` 按 think/tool_call/content 切块（useMessages.ts:1317-1359），`MarkdownRender` 流式 + `MARKDOWN_RENDER_MAX_LIVE_NODES=320` 节点上限。

## 总体调用链

```text
LLM 结果 / 插件 CommandResult
  → MessageEventResult（继承 MessageChain，result_content_type 标记来源）
  → ResultDecorateStage（result_decorate/stage.py:21-439）
      reasoning 注入 / TTS / t2i / 转发 / @/Reply 前缀 → 链重写
  → RespondStage（respond/stage.py:169-325）
      校验 → 分段/直通/防重 → event.send(chain) / event.send_streaming(async_stream)
  → 平台 AstrMessageEvent.send / send_streaming（平台重写）
      aiocqhttp: _parse_onebot_json → send_group/private_msg
      telegram: 4096 切块 → markdownify → send_message
      webchat: 逐组件 → webchat_queue_mgr → SSE/WebSocket → 前端 MessageList.vue
入站消息（反向）
  → 适配器 parse 平台 payload → ComponentTypes 表解析为组件列表 → event.message_obj
```

## 1. 消息组件体系（components.py，944 行）

### 1.1 枚举与基类

- `ComponentType`（:46-70）：22 种组件，其中 RPS/Dice/Shake/Contact/Location 标注 TODO，仅占位。完整清单：

  ```text
  Plain / Image / Record / Video / File / Face / At / Node / Nodes / Poke / Reply
  / Forward / RPS / Dice / Shake / Share / Contact / Location / Music / Json / Unknown
  ```
- `BaseMessageComponent(BaseModel)`（:73-110）：
  - `type: ComponentType` 必填（:74）；
  - `__repr_args__`（:79-96）：覆盖 pydantic repr，`base64://` 前缀显示为 `base64://<N chars>`，>64 字符截断——日志与异常输出自动安全；
  - `toDict()`（:98-106）：跳过 type 与 None 值，输出 `{"type": type.lower(), "data": {...}}`；
  - `to_dict()`（:108-110）：默认回退同步版本，**需下载/注册的组件重写**。

### 1.2 关键组件

| 组件 | 位置 | 要点 |
|---|---|---|
| `Plain` | :113-124 | `text` 字段；`toDict` 输出 `{"type":"text",...}`（OneBot 兼容别名，"plain" 也映射到 Plain，:919-922） |
| `Face` | :127+ | `id`；`toDict` 输出 `{"type":"face","data":{"id"}}` |
| `Image` | :501-581 | 工厂 `fromURL`（校验 http/https，:512-516）/`fromFileSystem`（`file=as_uri()` + `path` 双字段，:518-521）/`fromBase64`（:523-525）/`fromBytes`/`fromIO`；`convert_to_file_path`/`convert_to_base64` 走 `MediaResolver`（:535-558）；`register_to_file_service` 注册文件服务（:560-581，未配 `callback_api_base` 抛错） |
| `Reply` | :584-611 | `id`/`chain`/`sender_id` 等；`toDict` **仅输出 `{"type":"reply","data":{"id"}}`**（OneBot 标准，:609-611）；`text/qq/seq` 标 deprecated（:599-604） |
| `At`/`AtAll` | :410-429 | `qq=="all"` 即 @全体 |
| `Node`/`Nodes` | :647-733 | 合并转发；`Node.to_dict` 递归序列化（Image/Record 转 base64） |
| `Json` | :736-743 | `data: dict`，构造可传 JSON 字符串自动解析 |
| `File` | :764-916 | `file` property 同步下载 URL；`get_file` 异步；`_sanitize_file_component_name` 清洗文件名（去 `\x00`、路径剥壳） |
| `Record` | :135-285 | file/url/text/path 多源兜底（处理 NapCat 裸文件名）；统一转 wav；可注册文件服务 |
| `Video` | :288-407 | 同兜底链；非 http 注册文件服务返回回调链接 |

### 1.3 注册表（:919-944）

`ComponentTypes: dict[str, type]`——字符串名→类映射，`"text"` 与 `"plain"` 都映射 `Plain`。**所有平台入站解析统一用此表**（如 aiocqhttp_platform_adapter.py:251）。

## 2. 消息链与结果模型（message_event_result.py，288 行）

### 2.1 MessageChain（:17-192）

```python
chain: list[BaseMessageComponent]
use_t2i_: bool | None = None        # None 跟随用户设置（:29）
use_markdown_: bool | None = None   # None 跟随平台默认（:30-32）
type: str | None = None             # 业务语义元协议（:33-34）
```

- `derive(chain)`（:36-47）：继承 `use_t2i_/use_markdown_/type` 的派生链（RespondStage 分段发送用）；
- 构建方法（:49-147）：文本消息、@某人、@全体、三种图片来源（url/文件/base64）与 t2i、markdown 模式的快捷构造，均继承基础字段；
- `get_plain_text(with_other_comps_mark)`（:149-168）：默认空格拼接所有 Plain；带标记时非 Plain 输出 `[类名]`、Json 输出 `data`；
- `squash_plain()`（:170-192）：所有 Plain 聚合到第一个 Plain（aiocqhttp 非流式缓冲合并用）。

### 2.2 结果类型

- `EventResultType`（:195-205）：CONTINUE/STOP；
- `ResultContentType`（:208-220）：`LLM_RESULT / AGENT_RUNNER_ERROR / GENERAL_RESULT / STREAMING_RESULT / STREAMING_FINISH`；
- `MessageEventResult(MessageChain)`（:223-284）：`result_type`（默认 CONTINUE）、`result_content_type`（默认 GENERAL）、`async_stream`；`is_llm_result()`/`is_model_result()`（:275-284）；
- `CommandResult = MessageEventResult` 兼容别名（:287-288）。

## 3. 事件发送入口（astr_message_event.py）

- `process_buffer`（:267-278）：不支持流式的平台 fallback——按正则切句 `send` + `asyncio.sleep(1.5)` 限速；
- `send_streaming`（:280-292）：基类仅 `asyncio.create_task(Metric.upload(...))` 上传指标 + 标记 `_has_send_oper`——**真正实现全部在平台子类**（docstring：仅 telegram、qq official 私聊支持，fallback 仅 aiocqhttp）；
- `send_typing`/`stop_typing`（:294-304）：默认空实现，平台按需重写；
- `set_result`（:314-341）：str 自动包 `MessageEventResult().message()`；chain=None 兜底 `[]`；
- `stop_event`/`continue_event`/`is_stopped`（:343-365）：`_force_stopped` 与结果类型双源；
- `should_call_llm`（:367-372）：只阻止默认 LLM 链路，不阻止插件内请求；
- `_outline_chain`（:144-171）：日志概要（Image→`[图片]`、Face→`[表情:id]` 等占位）；
- `request_llm`（:420-474）：返回 ProviderRequest。

## 4. 流水线：装饰与发送

### 4.1 ResultDecorateStage（result_decorate/stage.py:21-439）

初始化（:23-102）一次性读取本阶段全部可调项：回复与 @ 相关开关、文本转图阈值与策略、转发阈值、TTS 触发概率、分段回复配置、内容安全复查（复用 ContentSafetyCheckStage 实例）与思考内容显示开关。配置键如下：

```text
reply_prefix / reply_with_mention / reply_with_quote
t2i_word_threshold（默认 150、下限 50） / t2i_strategy（local/remote）
forward_threshold
TTS trigger_probability（夹在 [0,1]）
分段回复配置（:58-88） / 内容安全复查（:91-99） / show_reasoning（:101-102）
```

| 装饰 | 位置 | 行为 |
|---|---|---|
| 思考内容注入 | :287-309 | `show_reasoning` + `_llm_reasoning_content` extra：lark 插 `Json(lark_collapsible_panel_reasoning)` 折叠面板（:294-305），其他平台 `Plain(f"🤔 思考: {content}\n\n────\n")`（:307-309） |
| TTS 替换 | :311-360 | `should_tts` 时每个长度>1 的 Plain 段经 `tts_provider.get_audio` 转 `Record`（file=url 或本地路径，:345-351）；`dual_output` 同时保留文本（:352-353）；`use_file_service` + `callback_api_base` 时注册文件服务返回 `{cb}/api/file/{token}`（:327-343）；失败回退文本（:354-357） |
| 文本转图片 | :362-404 | `use_t2i_ is None and 全局t2i` 或 `use_t2i_` 时，链首连续 Plain 拼接（非 Plain 断链 :367-371）；超过 `t2i_word_threshold` 时 `html_renderer.render_t2i` 渲染（`use_network` 与 `template_name` :376-381）；渲染 >3s 记 warning（:387-391）；**结果整链替换为单图**（http→Image.fromURL / file_service→URL / 本地→fromFileSystem，:392-404）——丢失 At/Reply/Record |
| 超长转发 | :406-418 | aiocqhttp 平台纯文本超过 `forward_threshold` 时包成 `Node(uin=self_id, name="AstrBot")` 合并转发（:413-418） |
| @/回复前缀 | :420-439 | `can_decorate`（仅 Plain+Image，:421-423）：群聊 + `reply_with_mention` → 插 `At`（首个 Plain 前补 `\n`，:426-435）；`reply_with_quote` → 插 `Reply(id=message_id)`（:438-439） |

### 4.2 RespondStage（respond/stage.py:169-325）

组件有效性校验表（:21-50）：对每种组件规定一条非空判定，例如文本 strip 后非空、Record 必须带文件、Reply 必须带 id 与发送者、Music 按 custom 类别区分等。

`process` 流程：

1. 无结果 / `_streaming_finished` 防重（:176-181）/ `STREAMING_FINISH` 置标记返回（:179-181）；
2. **防重**（:182-204）：`send_message_to_user` 已发过的纯文本（会话内记录 `_send_message_to_user_current_session_plain_texts`）+ 链仅 Plain/Reply/At → 跳过；
3. **流式直通**（:211-225）：`STREAMING_RESULT` → `event.send_streaming(result.async_stream, realtime_segmenting)`（realtime_segmenting = `unsupported_streaming_strategy == "realtime_segmenting"`，:216-222）；
4. **路径映射**（:227-233）：`path_mapping` 平台设置对 File 段生效（`path_Mapping`）；
5. 空链校验（:235-241）+ 空 Plain 移除（:243-251）；
6. **分段回复**：启用条件为开关开启、结果类型符合（非 only_llm_result 或模型结果）且平台不在 QQ 官方/微信公众号/钉钉排除表（`is_seg_reply_required` :130-147）。启用后 Reply/At 先提取为"头"（:256-261），其余组件逐条按随机间隔发送（:270-284），Record 强制单独发（:255、:274-275）；间隔计算（:98-107）采用对数或均匀随机两种策略：对数模式按字数对数插值（`interval_method=="log"` 时 Plain 按 `log(wc+1, log_base)` 随机插值），否则在默认区间 [1.5, 3.5] 秒内均匀随机（默认区间 :78-88）；
7. **非分段**：链仅 Reply/At 时跳过（:286-295）；Record 先逐条单独发（:296-310），剩余链一次发（:311-320）；
8. `OnAfterMessageSentEvent` hook（:322-323）→ `clear_result`（:325）。

## 5. 平台出站适配

### 5.1 aiocqhttp / OneBot V11（aiocqhttp_message_event.py:22-234）

- `_from_segment_to_dict`（:35-67）：Image/Record → `base64://`（:37-45）；File → `to_dict()` + 绝对路径无协议头转 `file:` URI（:46-62）；Video → `to_dict()`；其余 `toDict()`；
- `_parse_onebot_json`（:69-87）：At 后**强制插入空格 Plain**防粘连（:74-78）、空 Plain 跳过（:79-83）；
- `send_message`（:125-181）：链含合并转发节点或 File 时逐条发送（:144-153），转发节点统一包成 Nodes 走群聊/私聊合并转发接口（:155-172），普通消息逐条间隔 0.5s（:181）；发送前按数字 session_id 路由群聊/私聊/事件兜底（:89-123）；
- `send_streaming`（:199-234）：非 fallback **先缓冲全部链 + `squash_plain()` 合并一次发**（:204-215）；fallback 按 `[^。？！~…]+[。？！~…]+` 正则切句逐段发（:217-233，`process_buffer` 限速 1.5s）。

### 5.2 Telegram（tg_event.py）

- `MAX_MESSAGE_LENGTH = 4096`、`SPLIT_PATTERNS` 按 `\n\n`→句子→单词逐级切块（:40-42、:84-106）；
- `_send_text_chunks`（:108-130）：`telegramify_markdown.markdownify` 转 MarkdownV2，失败降级纯文本；
- Chat action 映射（Record→UPLOAD_VOICE、Video→UPLOAD_VIDEO 等，:64-70）；语音被禁降级文档发送（:184+）。

### 5.3 其他平台

| 平台 | 特点 |
|---|---|
| QQ 官方（botpy） | `_qqofficial_retry`（HTTP 500/504 重试）；私聊 Markdown 流式 |
| Satori | `_convert_component_to_satori`，`& < >` 转义 |
| LINE | 文本截断 5000 字符 |
| Discord | content/files/embeds 解析 |
| Mattermost | `squash_plain` 合并文本 |
| KOOK | `_wrap_message` |
| Slack | mrkdwn section blocks |
| wecom/wecom_ai_bot | 见平台源目录适配器 |

## 6. 平台入站适配

- **aiocqhttp**（aiocqhttp_platform_adapter.py:198-409）：要求 OneBot array 格式，按段类型 groupby 路由（:243）；text/file/reply 递归解析（reply 调 `get_msg` 拉引用链）、at 调 `get_group_member_info` 补昵称（:344-397）、markdown 降级 Plain（:400-404）、未知段记 warning；
- **Telegram**（tg_adapter.py:591-650）：动图/视频贴纸（.tgs/.webm 非位图）改用静态缩略图转 `Image`（:597-612）；`video_note`（无文件名、不能带 caption）转 `Video` 组件（:640-649）。
- 入站统一消费 `ComponentTypes` 注册表（:251）。

## 7. 工具调用的链构建

`ToolLoopAgentRunner._handle_function_tools`（tool_loop_agent_runner.py:1089-1355）：每个工具调用产生 `MessageChain(type="tool_call")` + 单个 `Json({id, name, args, ts})`（:1118-1132）；结果链 `type="tool_call_result"`（:1333-1348）。

消费方：`astr_agent_run_util._extract_chain_json_data`（:40）取链中第一个 Json；前端 `useMessages.ts`（chainType==="tool_call" → upsertToolCall）；工具执行中缓存的图片经 `from_cached_image` 以独立链 yield（:1236-1238、:1262-1264）。

## 8. WebChat 渲染管线

### 8.1 后端（webchat_event.py:22-263）

`WebChatMessageEvent._send` 静态方法（:29-163）逐组件出站：

| 组件 | 行为 | 位置 |
|---|---|---|
| `Plain` | `{"type":"plain","data":text,"chain_type":message.type}` | :51-62 |
| `Json` | 同上但 `json.dumps(comp.data)` | :65-77 |
| `Image` | `convert_to_base64` → `data/attachments/` 落盘（mime 探测扩展名，:82-89）→ `"[IMAGE]{filename}"` | :78-101 |
| `Record` | 转 base64 存 wav → `"[RECORD]{filename}"` | :102-120 |
| `File` | `get_file` + 文件名清洗（去 `\x00`、剥路径壳 :124-131）→ `"[FILE]{stored_filename}\|{display_name}"` | :121-147 |
| 其他 | `logger.debug("webchat 忽略")` | :148-149 |

- `emit_complete` 补发 `{"type":"complete"}`（:151-161）；
- `send`（:165-180）：follow_up_captured 直通 + `_send` + 父类指标；
- `send_typing`（:182-194）：`run_started`；
- `send_streaming`（:196-263）：逐链 `_send`，累计 final_data/reasoning_content，`audio_chunk` 类型链直通（Live Mode 音频，:202-224），结束发 complete（:253-262）；
- 队列：`webchat_queue_mgr.py` 入站 maxsize=128、出站 back-queue maxsize=512，按会话 asyncio.Queue + request_id 关联（:7-207）。

### 8.2 结构化 parts（message_parts_helper.py）

- `MEDIA_PART_TYPES = {"image","record","file","video"}`（:29）；
- 入站：`parse_webchat_message_parts`（:61-184）parts→组件；`webchat_message_parts_to_message_chain`（:266-335）；
- 出站/存储：`message_chain_to_storage_message_parts`（:395-466）链→parts（附件落库）。

### 8.3 前端（dashboard）

| 模块 | 位置 | 内容 |
|---|---|---|
| `useMessages.ts` | :990-1160 `processStreamPayload` | SSE/WebSocket 双通道（TransportMode :5）；按 `msgType`/`chainType` 分派：推理进 think part、工具调用进 upsertToolCall、audio_chunk 直通；`[IMAGE]/[RECORD]/[FILE]/[VIDEO]` 前缀与 `\|` 分隔符解析（:1131-1159）；`resolvePartMedia`（:202-238）attachment_id 三级回退 |
| `messageBlocks()` | :1317-1359 | parts 流按 think/tool_call 与 content 切块——思考折叠 + 内容块渲染基础 |
| `MessageList.vue` | renderBlocks :355-361；media 分支 :38-187 | ReasoningBlock、MarkdownMessagePart、reply 引用、partUrl（:369-380）embedded_url→attachment_id→filename 回退 |
| `MarkdownMessagePart.vue` / `ThreadedMarkdownMessagePart.vue` | :12/:11 | `markstream-vue` MarkdownRender（custom-html-tags + smooth-streaming），`max-live-nodes` |
| `markdownRenderConfig.ts` | :1 | `MARKDOWN_RENDER_MAX_LIVE_NODES = 320` |
| `ToolCallCard.vue` | :1-271 | 工具调用卡片：ID/Args/Result 折叠展示（:18-39），耗时计时 |
| `IPythonToolBlock.vue` | — | Python 工具结果专属渲染 |

## 9. 媒体转换与文件服务

- `MediaResolver`（`astrbot/core/utils/media_utils.py`）：统一处理 `file://` / http / `base64://` / `data:` 四种来源，提供转路径与转 base64 两条通道（Record 固定 wav，:29-32 附近 silk↔wav 转换辅助）；
- 文件服务：`register_to_file_service` 把资源注册到 `{callback_api_base}/api/file/{token}`，由 `file_token_service` 签发 token（components.py:560-581 等）；TTS 音频、t2i 结果与 Record/Video 出站兜底复用同一机制（result_decorate :337-343、:395-401）。

## 10. 设计取舍与边界

### 10.1 已确认的设计（代码事实）

1. **统一链 + 平台自治转换**：无通用转换函数，平台特性不泄漏，代价是转换逻辑在各适配器重复；
2. **`type` 字段是流式协议的元协议**：`tool_call`/`reasoning`/`audio_chunk` 被 webchat 出站与前端两端消费，其他平台忽略——平台间行为不对称是有意的；
3. **WebChat 半开放协议**：出站 `[IMAGE]` 等前缀魔改字符串 + 前端反向解析（实时通道）；历史记录走结构化 parts（持久化通道）——两套表示并存；
4. **异步/同步双轨序列化**：`toDict()`（同步，OneBot 用）与 `to_dict()`（异步，可下载/注册）并存，调用点各自选择（`_from_segment_to_dict` 混合调用两者 :37-67）；
5. **长度限制层层下放**：RespondStage 只管语义（Record 单发、@/Reply 头、分段节奏），平台层处理 4096（TG）/5000（LINE）截断，aiocqhttp 用缓冲合并或句号切分两个极端策略（send_streaming :204-234）；
6. **装饰在链层面集中做**：插件与 LLM 结果走同一套后处理（reasoning/TTS/t2i/转发/@Reply）；
7. **前端流式节点上限 320**：长输出触发 markstream-vue 截断策略；complete 事件时前端补齐缺失文本兜底（useMessages.ts:1089-1107）。

### 10.2 取舍（平衡决策）

- **t2i 整链降级单图**：At/Reply/Record 全部丢失（result_decorate:392-404）——换取渲染质量，代价是引用语义丢失；
- **TTS dual_output**：默认可选同时保留文本（:352-353），缓解语音可读性损失；
- **分段回复默认区间 [1.5, 3.5]s**：随机插值防平台风控，log 模式按字数增长（:98-107）；
- **aiocqhttp 非 fallback 流式缓冲**：非流式支持平台干脆缓冲完再发（:204-215），换稳定性；
- **webchat 附件名用时间戳**：`generate_timestamp_id()` 避免原始文件名冲突与路径穿越（:87、:133）。

### 10.3 静态推断的潜在问题（源码推断，未实测）

1. **`squash_plain` 修改首个 Plain 对象原地**（message_event_result.py:188-189）——若同一 Plain 实例被多处引用，可能有副作用；
2. **流式缓冲无上限**：aiocqhttp 非 fallback 缓冲整条流（aiocqhttp_message_event.py:204-214），超长流内存峰值=全文；
3. **t2i 拼接只取链首连续 Plain**（result_decorate:367-371）：Plain 后跟非 Plain 则后续 Plain 不参与渲染；
4. **分段回复打断词序**：非 Plain 组件按组件粒度重排（Record 单发后剩余合发），链顺序在跨组件场景下可能与原始不同；
5. **webchat `[IMAGE]` 前缀与正文冲突**：用户文本恰好以 `[IMAGE]` 开头时前端解析歧义（未实测）。

## 11. 关键文件索引

| 文件 | 关键位置 |
|---|---|
| `astrbot/core/message/components.py` | 枚举 :46-70；基类 :73-110；Plain :113-124；Image :501-581；Reply :584-611；File :764-916；注册表 :919-944 |
| `astrbot/core/message/message_event_result.py` | MessageChain :17-192；ResultContentType :208-220；MessageEventResult :223-284 |
| `astrbot/core/platform/astr_message_event.py` | outline :144-171；process_buffer :267-278；send_streaming :280-292；set_result :314-341；request_llm :420-474 |
| `astrbot/core/pipeline/result_decorate/stage.py` | 初始化 :23-102；思考 :287-309；TTS :311-360；t2i :362-404；转发 :406-418；@/Reply :420-439 |
| `astrbot/core/pipeline/respond/stage.py` | 校验表 :21-50；分段 :130-147、256-284；间隔 :98-107；流式 :211-225；防重 :182-204 |
| `astrbot/core/platform/sources/aiocqhttp/aiocqhttp_message_event.py` | 出站 :35-87；发送 :125-181；流式 :199-234 |
| `astrbot/core/platform/sources/aiocqhttp/aiocqhttp_platform_adapter.py` | 入站 :198-409 |
| `astrbot/core/platform/sources/telegram/tg_event.py` | 限制 :40-42；切块 :84-130 |
| `astrbot/core/platform/sources/webchat/webchat_event.py` | _send :29-163；send_streaming :196-263 |
| `astrbot/core/platform/sources/webchat/message_parts_helper.py` | parts 互转 :61-466 |
| `astrbot/core/platform/sources/webchat/webchat_queue_mgr.py` | 队列上限 :7-207 |
| `astrbot/core/agent/runners/tool_loop_agent_runner.py` | 工具链 :1118-1132、:1333-1348 |
| `astrbot/core/astr_agent_run_util.py` | _extract_chain_json_data :40 |
| `dashboard/src/composables/useMessages.ts` | 分派 :990-1160；blocks :1317-1359 |
| `dashboard/src/components/chat/MessageList.vue`、`markdownRenderConfig.ts`、`message_list_comps/*` | 渲染、320 上限、ToolCallCard |
| `astrbot/core/utils/media_utils.py` | MediaResolver |

## 12. 未验证事项

1. 未启动真实平台实例，各平台出站/入站转换的线上行为未实测；
2. qqofficial 发送主体、telegram 流式 draft 编辑细节未逐行核对；
3. `result_decorate` 转发逻辑与 aiocqhttp 适配器 :410-513 区段未逐行核验；
4. 前端 markstream-vue 的节点截断策略只依据配置常量，未实测；
5. `MediaResolver` 各来源分支（silk 转换、data: URL）未逐行核验。
