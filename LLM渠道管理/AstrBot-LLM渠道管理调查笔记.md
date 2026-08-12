# AstrBot LLM 渠道管理调查笔记

> 调查对象：`E:\works\git\AstrBot`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`a9bb8a64ca69657e6262e3ca06541ecaf3a6d1ca`（分支：`master`）
>
> 调查方式：只读源码（provider 抽象层、实体、管理器、主要适配器、配置层、fallback 编排、Dashboard 后端）与仓库文档交叉梳理；未修改目标仓库
>
> 调查范围：Provider 数据模型与配置结构、注册机制与 42 个适配器、协议适配与统一消息格式、请求路由与 Model 绑定、错误处理与两层重试、Key 轮换、fallback 语义、配置持久化与热更新、Dashboard/WebUI 配置面
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 把"渠道管理"拆成**来源（provider_sources）＋模型实例（provider）**两级配置，中间由 `ProviderManager` 组装运行时实例。数据模型上，"一个 provider 配置项 = 一个能力实例"，同一来源的多模型通过 `provider_source_id` 合并配置。这与容器型客户端（一个 Provider 通道内多模型）不同，更像"每条渠道就是一个独立实例"。

五个能力子类（`Provider` / `STTProvider` / `TTSProvider` / `EmbeddingProvider` / `RerankProvider`）统一抽象，`ProviderType` 枚举 5 种；设计上允许同一适配器被多个实例复用（OpenAI 类适配器被 Groq/XAI/OpenRouter 等十几个渠道继承）。

核心事实链（详见各节）：

- **注册**：`register_provider_adapter` 装饰器在 import 时写入 `provider_registry` 与 `provider_cls_map`（register.py:6-49），同名类型直接抛 `ValueError`。真正的模块 import 发生在 `ProviderManager.dynamic_import_provider`（manager.py:356-523）——`type` 字符串到类的 `match` 分派，导入失败记 critical 并跳过。
- **加载**：`load_provider`（manager.py:597-758）先合并 source 配置、解析 `$ENV` 键（仅 chat_completion 类型）、跳过 disabled/agent_runner，再校验类继承关系后实例化，最后写 `inst_map` 与五类实例列表。
- **路由**：`get_using_provider`（manager.py:218-281）优先级为"umo 会话偏好 → 全局默认 → 实例列表第一个"；会话偏好存 SharedPreferences（`provider_perf_<type>`，umo scope）。
- **重试存在两层**：transport 层 tenacity（5 次指数退避）与 OpenAI 适配器内层（max_retries=10 的错误分类循环：429 换 key / 超长弹历史 / 非 VLM 删图 / 工具不支持去 tools / 图片审核删图）。
- **Key 轮换是错误驱动的**：`key` 数组随机择一，429/无效时剔除当前 key 换下一个（openai_source.py:1084-1103；gemini_source.py:131-158），无定时轮换与健康检查。
- **fallback 只有两个消费者**：图片模态降级（astr_main_agent.py:1348-1369）与空输出/err 回复降级（tool_loop_agent_runner.py:533-634）；普通 5xx/网络错误不走 fallback，由重试层处理。
- **配置持久化**：`data/cmd_config.json`（AstrBotConfig，dict 子类），原子写（临时文件 + fsync + os.replace + revision），启动缺项自愈；热更新经 Dashboard API → `ProviderManager`。
- **未实现机制**：无渠道池/权重/负载均衡（`provider_pool` 与 `persona_pool` 只声明在默认配置，全仓 grep 无消费者）；API Key 明文落盘，Dashboard 列表 API 向有权限前端返回完整 key。

## 总体调用链

```text
data/cmd_config.json（AstrBotConfig，dict 子类）
  ├─ provider_sources[]  键: api_key, api_base, timeout, proxy, custom_headers, key[] ...
  ├─ provider[]          键: id, provider_source_id, model, modalities, custom_extra_body, enable
  └─ provider_settings   default_provider_id / fallback_chat_models / request_max_retries / tts·stt·emb settings

ProviderManager.__init__（读取五个配置切片，manager.py:44-49）
core_lifecycle: ProviderManager.initialize()（manager.py:283-354）
  ├─ 遍历 providers_config -> load_provider
  ├─ 读 curr_provider 全局偏好（sp.get_async, scope=global）设 curr_* 实例
  └─ 后台 asyncio 任务初始化 MCP 客户端（_init_mcp_clients_bg, :344-354）

load_provider（manager.py:597-758）
  -> get_merged_provider_config（合并 source，provider 覆盖 source，id 保留 provider id）
  -> enabled? -> dynamic_import_provider（match 语句导入类）
  -> provider_cls_map 校验 -> cls_type 校验
  -> 按 ProviderType 分支实例化 -> initialize() -> inst_map + 分类列表

请求时：
  get_using_provider(provider_type, umo)  （manager.py:218-281）
    1. sp.get("provider_perf_<type>", scope=umo) 命中即用
    2. default_provider_id / stt · tts settings.provider_id（enable=false 返回 None）
    3. 各类别实例列表第一个
    ；可被 event extra selected_provider 覆盖（astr_main_agent.py:_select_provider）

AstrMessageEvent.request_llm() -> ProviderRequest(func_tool, extra_user_content_parts, ...)
Adapter.text_chat / text_chat_stream（内部 result_chain/tools_call_*）
  -> 每家适配器的 _prepare_chat_payload / error 分类循环 / request_max_retries
  -> LLMResponse（role/result_chain/reasoning/tools_call_*/raw_completion/usage）
```

## 1. Provider 数据模型与配置结构

### 1.1 实体层（`astrbot/core/provider/entities.py`）

工程内存在两个同名目录文件：`entities.py`（456 行，真身）与 `entites.py`（19 行 `from .entities import *` 兼容壳），后者是重命名迁史遗留。

| 实体 | 位置 | 要点 |
|---|---|---|
| `ProviderType` | entities.py:29-34 | 5 种能力：CHAT_COMPLETION / SPEECH_TO_TEXT / TEXT_TO_SPEECH / EMBEDDING / RERANK |
| `ProviderMeta` | :37-48 | 实例元数据：id、model、type（适配器名）、provider_type |
| `ProviderMetaData` | :51-62 | 注册元数据追加 desc / cls_type / default_config_tmpl / display_name |
| `ToolCallsResult` | :65-87 | 工具调用信息 + 结果段，提供 `to_openai_messages` 双向转换 |
| `ProviderRequest` | :90-261 | 请求载体（详见 1.2） |
| `TokenUsage` | :264-293 | input_other / input_cached / output，重载 `+` `-` 便于增量累计 |
| `LLMResponse` | :296-448 | 统一响应（详见 1.3） |
| `RerankResult` | :451-455 | rerank 返回 index + relevance_score |

### 1.2 ProviderRequest

字段（entities.py:90-117）：`prompt`、`session_id`（标注已废弃）、`image_urls`、`audio_urls`、`extra_user_content_parts`（在用户消息后追加内容块，如系统提醒/知识库结果）、`func_tool: ToolSet`、`contexts`（OpenAI 格式消息列表）、`system_prompt`、`conversation`、`tool_calls_result`（多轮工具结果，`append_tool_calls_result` :132-138）、`model`（每请求覆盖，None 用默认）。

`_print_friendly_context()`（:140-186）：日志友好，checkpoint 跳过、图片/音频折叠为 `[+N images]`，避免 base64 刷日志（与消息组件 `__repr_args__` 同样的防日志污染思路）。

`assemble_context()`（:188-261）关键行为：

1. 先放用户原始发言；无文本有图片 → `[图片]` 占位；无文本无图有音频 → `[音频]` 占位；
2. `extra_user_content_parts` 用 `model_dump_for_context()` 追加；
3. 图片 / 音频都走 `MediaResolver(...).to_base64_data()` **先转 base64 再入请求**（音频默认 target wav，strict=True），失败 warning 并跳过；
4. 退化：只有单一文本块且无额外部分时返回简单字符串格式 `{"role":"user","content": text}` 保持向后兼容；否则返回多模态 content 数组。

### 1.3 LLMResponse

统一响应（entities.py:296-448）：

- `result_chain: MessageChain`（最终渲染链）；`reasoning_content` / `reasoning_signature`；`tools_call_args/name/ids/extra_content` 四个并行数组；`raw_completion`（OpenAI/Anthropic/GenAI 原始对象）；`is_chunk`；`id`；`usage`。
- `completion_text` property：若 result_chain 存在则 `get_plain_text()`，否则 `_completion_text`；setter 会**清空链中全部 `Plain` 组件再在头部插入新 Plain**（:394-404），保证"最后一次文本写入"是权威的。
- `to_openai_tool_calls_model`（:426-443）输出 pydantic `ToolCall` 模型；旧串行方法 `to_openai_tool_calls` 打了 `@deprecated`；另外还有一个打错名字的别名 `to_openai_to_calls_model`（:445-448），双重过时痕迹。

### 1.4 配置结构与默认值

- 主配置文件 `data/cmd_config.json`（`AstrBotConfig` 是 dict 子类，`astrbot/core/config/astrbot_config.py:20,31`），明文 JSON。
- 默认值 `astrbot/core/config/default.py`：

| 配置项 | 默认值 | 行 |
|---|---|---|
| `provider_sources` / `provider` | `[]` | :100-101 |
| `fallback_chat_models` | `[]` | :105 |
| `request_max_retries` | 5 | :106 |
| `default_image_caption_provider_id` | `""` | :107 |
| `provider_pool` | `["*"]`（**无消费者**） | :109 |
| `default_personality` | `"default"` | :124 |
| `persona_pool` | `["*"]`（**无消费者**） | :125 |
| `context_limit_reached_strategy` | `"llm_compress"` | :127 |
| `llm_compress_provider_id` | `""` | :138 |
| `max_context_length` | -1（不限制轮次） | :139 |

- 迁移后模型（`astrbot/core/utils/migra_helper.py:45-128` `_migra_provider_to_source_structure`）：provider 条目只剩 6 个字段（id/provider_source_id/model/modalities/custom_extra_body/enable），key/api_base/timeout/proxy/custom_headers 全部归入 `provider_sources`。这是 v4.x 的大重构，旧 key 全部迁到 source 后 provider 变轻。

## 2. ProviderManager：加载、热更新与实例生命周期

### 2.1 结构

- `inst_map: dict[provider_id, Providers]`（manager.py:64-68）；五类列表 `provider_insts`/`stt_provider_insts`/`tts_provider_insts`/`embedding_provider_insts`/`rerank_provider_insts`（:54-63）。
- 变更通知两套并存的机制：`set_provider_change_callback`（单回调，兼容）与 `register_provider_change_hook`（多订阅），`_notify_provider_changed` 逐个发，异常只 warning（:101-128）。
- 注释明确 `curr_provider_inst` 是 deprecated 全局字段，推荐 `get_using_provider()`（:71-77）。

### 2.2 load_provider 完整流程（manager.py:597-758）

1. `get_merged_provider_config`（:525-546）：provider 有 `provider_source_id` 时合并 source config，`**source, **pc` 且保留 **provider 的 id**；
2. chat_completion 类型先跑 `_resolve_env_key_list`（:568-595）把 `$ENV` / `${ENV}` 前缀项替换为环境变量值，未设置则 warning 并留 `""`；
3. `enable=false` 跳过；`provider_type=agent_runner` 跳过（agent runner 是独立体系，不纳入本管理器实例）；
4. `dynamic_import_provider(provider_config["type"])`——如果 import 失败（缺依赖）记 critical 并 return，**该渠道静默不加载**；
5. `provider_cls_map` 查不到 → error 跳过；
6. 按 ProviderType `match` 分支实例化，`issubclass` 校验，有 `initialize()`（HasInitialize protocol，manager.py:28-31）则 await；
7. 三类（chat/stt/tts）会同步更新 `curr_*_inst`（命中默认配置或第一个）；
8. 写入 `inst_map`。

边界：embedding/rerank 没有 `_warn_about_unset_default` 之类的兜底首选项，靠调用方显式选择；实例化整段异常会 `raise`（热更新 API 能收到 500，可转 UI 错误）。

### 2.3 source 与实例的合并语义

`get_merged_provider_config`：`provider_source_id` 命中时用 source 字段填充 provider 缺失项，但始终保留 provider 自己的 `id`。因此"同一来源 + 多模型"在配置表里是 N 个 provider 条目共享一个 source 条目，运行时是 N 个独立实例。

### 2.4 terminate / reload / CRUD

- `terminate_provider`（manager.py:809-845）：从三列表移除、清 off `curr_*`、调用 `terminate()`（若有）、`del inst_map[id]`；
- `reload`（:760-804）：锁内 terminate + load + **清理配置中已被删除的实例**（按 `config_ids` 对 `inst_map` 反查 terminate，实现三列表与 config 的同步），并重选 `curr_*`；
- `delete_provider(provider_id, provider_source_id)`（:847-869）：按 id 或按 `provider_source_id` 级联删除目标 provider 集合，`config.save_config()` 后同步内存 `providers_config`（:868），删除后 API 列表查询不再读到旧实例（#9568）；
- `update_provider`（:869-891）：查 id 重复冲突才报错，替换 config，save_config，reload；
- `create_provider`（:893-909）：append config → save → load → 同步内存 `providers_config`；
- `terminate`（:911-925）：**先 cancel MCP init 后台任务**，再逐个 terminate，最后 `disable_mcp_server`。

### (misc) 全部终止时 curr 兜底

`reload` 里若 provider_insts 为空则 `curr_provider_inst = None`；若最近一次 reload 后仍有实例但 curr 为 None，则自动选第一个并`logger.info`——"自动选第一"是刻意行为不是异常。

## 3. 注册机制

### 3.1 注册装饰器语义（register.py）

- `register_provider_adapter(type_name, desc, provider_type, tmpl, display_name)`（:14-53）；
- 同名冲突：`if provider_type_name in provider_cls_map: raise ValueError`（:24-27）；
- 模板补默认：缺 `type` → 当前 type_name；缺 `enable` → False；缺 `id` → type_name（:30-37）；
- 入表后 `ProviderMetaData.id = "default"` 占位，实例化时由 load 流程用真实 id 覆盖（:38-48）。

### 3.2 已注册适配器全清单（全仓 grep 确认 42 个）

- **Chat（12）**：openai_chat_completion、openai_responses、anthropic_chat_completion、googlegenai_chat_completion、groq / longcat / xai / aihubmix / openrouter / zhipu / xiaomi / kimi_code 的 chat_completion。
- **STT（5）**：whisper_api、whisper_selfhosted、sensevoice_stt_selfhost、mimo_stt_api、xinference_stt。
- **TTS（14）**：azure_tts、dashscope_tts、edge_tts、elevenlabs_tts、fishaudio_tts_api、gemini_tts、genie_tts、gsv_tts_selfhost、gsvi_tts_api、mimo_tts_api、minimax_tts_api、openai_tts_api、volcengine_tts（+1 直通式 SDK 实现，共 14）。
- **Embedding（5）**：openai_embedding、gemini_embedding、nvidia_embedding、ollama_embedding、dashscope_embedding。
- **Rerank（5）**：vllm_rerank、xinference_rerank、bailian_rerank、nvidia_rerank、tei_rerank。
- **TokenPlan（2）**：minimax_token_plan、xiaomi_token_plan（属额外"计费/套餐"适配，未列入枚举）。

`astrbot/api/provider/` 目录仍是空的 `__init__.py`（旧清理遗留），全部实现都在 `core/provider/`。

## 4. 协议适配与统一消息格式

### 4.1 抽象基类与统一行为（provider.py）

`Provider` 基类中几个"提供默认但语义重要"的实现：

- `text_chat_stream`（:135-172）基类直接 `raise NotImplementedError`——**流式需各适配器自己实现**；
- `pop_record`（:174-187）：从 contexts **弹 2 条**首个非 system 记录（`poped==2` break），供上下文超长时重试；
- `_ensure_message_to_dicts`（:189-205）：过滤 checkpoint 消息，统一 dict；
- `test()`（:207-211）默认超时 45s，发送 `prompt="REPLY \`PONG\` ONLY"`——各适配器覆盖此探测 prompt（如 STT 用 `samples/stt_health_check.wav`，TTS 生成 `get_audio("hi")` 并校验文件大小非 0）。

TTS 基类 `support_stream()` 默认 False；`get_audio_stream`（:256-297）默认实现是"攒整段 → 一次性 get_audio → 读文件 → 队列送 (text, bytes)"，真正的边生成边送需要子类重写。

Embedding 基类提供 `get_embeddings_batch`（:344-412）：`batch_size=16 / tasks_limit=3（信号量）/ max_retries=3`，`asyncio.gather(return_exceptions=True)`，指数退避 `2**attempt`，单批最终失败会抛出"第 N 批失败"。

### 4.2 OpenAI 适配器（openai_source.py，57KB）

外层选择与错误分类是本项目渠道管理的最核心代码：

- `text_chat` / `text_chat_stream`（:1185-1337）：**内层 `for retry_cnt in range(max_retries=10)`**，每次随机 `random.choice(available_api_keys)`，`self.client.api_key = chosen_key` 后 `_query`；`_handle_api_error`（:1071-1183）按 str(e) 先字符串分类：
  - `429` → 睡眠 1s（最后一次不睡），**剔除当前 key**，随机再取一个，返回 `(False, new_key, ...)` 进入下一轮；key 用尽直接 `raise`；
  - `context length` → 弹记录 + 更新 payload，retry；
  - `The model is not a VLM` → `_fallback_to_text_only_and_retry`（只删图片重试，`image_fallback_used` 防止重复删）；
  - 图片内容审核错误（`is_content_moderated_upload_error`，字符串模式匹配）→ 同删图重试；
  - 无效附件 → 同删图；
  - `Function calling is not enabled` 或 tool/function+support → **`payloads.pop("tools")` 并 `func_tool=None`** 重试，并提示用户 WebUI 可关闭工具；
  - `is_connection_error` → 记录 proxy 信息后 re-raise。
- `_prepare_chat_payload`：assistant 消息对 DeepSeek v4 / MiMo 推理模型**回填空 `reasoning_content`**（:1041-1057，厂商协议要求的特殊兼容）；Gemini 的 tool response 纯文本包成 JSON `{"result": content}`（:1059-1069）。
- azure 切换：`api_version` 存在时切 `AsyncAzureOpenAI`（:372-381）。
- 卸载 `_remove_image_from_context`（:1339-1356）：删光图片后，原纯图片消息替换为 `{"type":"text","text":"[图片]"}` 占位。
- `get_current_key`/`get_keys`/`set_key`（:1358-1365）。

### 4.3 其他协议要点

- **Anthropic**（anthropic_source.py）：`_PROMPT_CACHE_CONTROL = {"type":"ephemeral"}`（:38）；`_init_api_key` 取 key 列表第一个（:105-111）；`_prepare_payload`（:160）把 OpenAI 消息转 Anthropic，thinking 块签名回传（:144-158, :549-552）；prompt caching 即 `last_block["cache_control"]`（:490-492）；timeout 默认 120（:94）。
- **Gemini**（gemini_source.py）：`google.genai` SDK 强 httpx 后端（:92-116）；CATEGORY_MAPPING/THRESHOLD_MAPPING 安全设置（:47-59）；`_handle_api_error` 429 或 "API key not valid" → 换 key（: 131-158）；timeout 默认 180（:72）。

## 5. 请求路由与会话绑定

### 5.1 get_using_provider 精确分支（manager.py:218-281）

```text
umo 命中 provider_perf_<type>（inst_map 反查，无则回退全局）
  ├─ 无 umo 时：
  │    chat      -> config.provider_settings.default_provider_id -> [0]
  │    stt/tts   -> settings.enable=false 则 return None
  │               -> settings.provider_id -> 对应列表第一个
  │    -> 其他 raise ValueError("Unknown provider type")
末尾：provider 为空但 provider_id 有值 -> warning（可能是 id 已改）
```

### 5.2 会话级/事件级/命令级切换

- 会话偏好：`set_provider`（manager.py:146-172）写 `provider_perf_chat_completion`（umo scope），`session_put` → `sp.session_put`（SQLite preferences）。管理员可 `/provider` 切换（builtin_stars/builtin_commands/commands/provider.py:231-246）。
- 事件级 model 覆盖：`req.model = event.get_extra("selected_model")`（astr_main_agent.py:1411-1412）→ `ProviderRequest.model` → 各适配器 `model or self.get_model()`。
- WebChat/API 请求可直接 `event.get_extra("selected_provider")`（`_select_provider`，astr_main_agent.py:229-258）。
- 会话组批量：`batch_update_service`（session_management_service.py:438-494，`sp.session_get`/`session_put` 逐会话读写）。

### 5.3 专用模型绑定

| 用途 | 配置键 | 位置 |
|---|---|---|
| 图像描述 | `default_image_caption_provider_id` | default.py:107 |
| 上下文压缩 | `llm_compress_provider_id` | default.py:138；astr_main_agent.py:1290-1303 |
| 知识库 embedding/rerank | kb 记录内 | kb_helper |
| agent runner（dify/coze/dashscope/deerflow）| 各自独立 id | default.py:154-157 |

### 5.4 模型元数据（LLM_METADATAS）

`astrbot/core/utils/llm_metadata.py:30-66` 从 `https://models.dev/api.json` 拉取 `LLMMetadata`（context window/模态/tool_call 能力），传给 WebUI 展示与上下文裁剪（`max_context_tokens` 运行时注入 astr_main_agent.py:1632-1642）。它是"事实字段来源"而不是"路由键"。

## 6. 错误处理、重试与 Key 轮换

两层重试的完整拼图：

**传输层**（provider/sources/request_retry.py）基于 tenacity：默认 5 次、指数退避 0.2s-30s、可重试判定 `_is_retryable_provider_request_error`（连接错误 / APIConnectionError / APITimeoutError / 408,409,429,500,502,503,504,529 或 5xx）、429 可由 `retry_rate_limits=False` 关闭。`provider_settings.request_max_retries` 页面可调（default.py:106）→ text_chat 形参 `request_max_retries`。

**适配器内层**（OpenAI）max_retries=10 的错误分类循环（见 4.2），能识别 429/context/非 VLM/审核/工具不可用。两者叠加意味着一个 429 极端情况下最多可能尝试十几次。

**Key 轮换边界**：`key` 数组在适配器构造时解析进 `self.api_keys`；429/无效时移除；**多 key 只是错误驱动的本地轮换 handleState，不跨实例/渠道共享**。Anthropic 只取 `key[0]`，不改 key（:105-111）。

**fallback 语义**：参见 5.3，只覆盖图片模态退化 + 空输出/err 回复；`_iter_llm_responses_with_fallback`（tool_loop_agent_runner.py:533-634）候选 `[provider, *fallback_providers]`，主 provider 空输出（`EMPTY_OUTPUT_RETRY_ATTEMPTS=3` 指数退避）轮到下一个，普通错误抛给上层重试。

## 7. 配置持久化、热更新与密 param 处理

### 7.1 读写链路

- 启动：`astrbot/core/__init__.py:33` `AstrBotConfig()`；缺项 `check_config_integrity` 递归补默认（astrbot_config.py:173-230）；`save_config`（: 232-323）原子写（临时文件 + fsync + os.replace + revision 去重提交）。
- 新配置端：`AstrBotConfigManager`（astrbot_config_mgr.py:31-309）`confs["default"]` + 多会话 `abconf_<uuid>.json`，`get_conf(umo)` 经 `UmopConfigRouter`；档案映射 `abconf_mapping` 存 SharedPreferences global 键（:54-66），启动时 `initialize()` 异步加载（:49-52，core_lifecycle.py:188），`create_conf`/`delete_conf`/`update_conf_info` 已全部异步化并加 `_abconf_lock` 串行（:191-301，#9582/#9584）。
- 热更新：Dashboard REST（`astrbot/dashboard/api/providers.py` + `config_service.py`）→ ProviderManager 的 create/update/delete。
- `get_provider_schema`（config_service.py:1361-1393）合并 `CONFIG_METADATA_2` 模板 + `provider_cls_map[type].default_config_tmpl` → WebUI 动态表单。

### 7.2 敏感信息处理（关键事实 + 设计边界）

- `key` 以数组存 `cmd_config.json` **明文**，无加密；`save_config` 不脱敏。
- `_resolve_env_key_list` 只在 `load_provider` 且类型为 chat_completion 时执行；key 为空字符串则发空 key，导致请求必然 401——具体处不报错，直到请求时暴露。
- Dashboard `list_providers`（config_service.py:1628-1666）把完整 key **返回给前端**（只有日志截断前 12 字符，如 openai_source.py:1086）。
- 配置变更日志对 token/secret 字段掩码（config_service.py:333-338），且仅沙箱/computer 环境生效——**普通本地部署不脱敏**。

## 8. WebUI（Dashboard）渠道配置面

- `dashboard/src/views/ProviderPage.vue`（920 行）按 provider 类型 tab 分组（v-tabs + provider-config 表单），选择器消费 `provider-cls-map` 与 schema 模板。
- 后端有 ProviderSource 与 ProviderConfig 两套 schema（config_service.py + schemas.py:465/482），支持"source 级管理 + 模型实例级管理"两个粒度。
- Dashboard 还有工具页（tools_service.py）展示内置/插件/MCP 工具状态（`origin="builtin"` + readonly），消费 `get_builtin_tool_config_statuses`（详见 Agent 工具笔记）。

## 9. 能力边界与横向比较要点

### 已实现

- 四类协议（OpenAI / OpenAI-Responses / Anthropic / Gemini）+ 大量 OpenAI-Compatible 模板；`api_base` 自定即可接入任意兼容上游；
- 五类能力（chat/STT/TTS/embedding/rerank）统一抽象 + 42 适配器；
- 单渠道多 Key 错误驱动轮换；
- 多层重试（transport tenacity + 适配器内层分类降级：弹历史/删图/去 tools/换 key）；
- 限定场景 fallback（图片模态 / 空输出 / err role）；
- 会话级 provider/model 偏好、事件级覆盖、专用模型绑定；
- 配置原子写、缺项自愈、`$ENV` 键引用、热更新。

### 未实现或不存在的机制

- **无渠道池/权重/健康评分**；`provider_pool`/`persona_pool` 无消费者（全仓 grep）；
- **无密钥级负载均衡**：429 剔除换 key，不会并发切 key；
- **fallback 不覆盖普通 API 错误**；
- **明文落盘 + API 返回完整 key**；
- **大媒体入站 base64 内存化**，无流式上传；
- **agent_runner 渠道完全旁路**（`provider_type=agent_runner` 直接 return），第三方 runner 配置消费在另一路径。

## 10. 关键文件索引

| 文件 | 用途 |
|---|---|
| `astrbot/core/provider/manager.py` | 渠道管理中枢（加载/热更新/路由/CRUD） |
| `astrbot/core/provider/register.py` | 注册装饰器与全局容器 |
| `astrbot/core/provider/entities.py`（兼容壳 `entites.py`） | 数据模型与统一请求/响应 |
| `astrbot/core/provider/provider.py` | 5 类抽象基类 + 通用行为 |
| `astrbot/core/provider/func_tool_manager.py` | 工具/MCP 管理（见 Agent 工具笔记） |
| `astrbot/core/provider/sources/openai_source.py` | OpenAI 协议 + 错误分类重试 + key 轮换 |
| `astrbot/core/provider/sources/anthropic_source.py` | Anthropic 协议 + prompt caching |
| `astrbot/core/provider/sources/gemini_source.py` | Google GenAI 协议 |
| `astrbot/core/provider/sources/openai_responses_source.py` | Responses 协议转换 |
| `astrbot/core/provider/sources/request_retry.py` | tenacity 重试封装 |
| `astrbot/core/config/default.py` | 默认配置与 WebUI 模板 |
| `astrbot/core/config/astrbot_config.py` | 配置原子读写 |
| `astrbot/core/astrbot_config_mgr.py` | 多配置（会话级）管理 |
| `astrbot/core/utils/llm_metadata.py` | models.dev 模型元数据缓存 |
| `astrbot/core/utils/migra_helper.py` | provider→source 结构迁移 |
| `astrbot/dashboard/api/providers.py`、`services/config_service.py` | Dashboard CRUD 后端 |
| `dashboard/src/views/ProviderPage.vue` | WebUI 渠道配置面 |

## 11. 未验证事项

1. 未启动真实 LLM 调用；各厂商字符串 match 降级启发式未被线上验证。
2. `provider_pool`/`persona_pool` 无消费者基于全仓 grep；若存在动态拼接 key 的隐式引用可能漏检。
3. minio TTS/SST 各适配器内部的厂商参数细节未逐行展开（本文聚焦框架层）。
4. `dynamic_import_provider` 覆盖面与 42 注册数基于 grep，个别适配器（如 `azure_tts` 的大厂参数）未读全。