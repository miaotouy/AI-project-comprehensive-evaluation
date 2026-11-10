# AstrBot LLM 渠道管理调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`f926af99ec5f8bd85b64413f8bfad55da76ef73b`（分支：`master`）
>
> 调查方式：只读源码（provider 抽象层、实体、管理器、主要适配器、配置层、fallback 编排、Dashboard 后端、CLI、备份与桌面运行时）与仓库文档交叉梳理；未修改目标仓库
>
> 调查范围：Provider 数据模型与配置结构、注册机制与 45 个注册适配器、六类能力（对话、语音识别、语音合成、Embedding、Rerank、结构化决策）、协议适配与统一消息格式、请求路由与 Model 绑定、错误处理与两层重试、Key 轮换、fallback 语义、配置持久化与热更新、配置文件/CLI/TUI/Web/桌面端管理入口、备份导入导出与 Dashboard/WebUI 配置面
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 把"渠道管理"拆成**来源（provider_sources）＋模型实例（provider）**两级配置，中间由 `ProviderManager` 组装运行时实例。数据模型上，"一个 provider 配置项 = 一个能力实例"，同一来源的多模型通过 `provider_source_id` 合并配置。这与容器型客户端（一个 Provider 通道内多模型）不同，更像"每条渠道就是一个独立实例"。

六类能力子类（对话、语音识别、语音合成、Embedding、Rerank、结构化决策）统一抽象，`ProviderType` 枚举 6 种取值；同一适配器可被多个实例复用，OpenAI 类适配器就被 Groq、XAI、OpenRouter 等十几个渠道继承。新增的决策能力面向插件侧的结构化判断：`DecisionService.ask()` 把选择题、概率判断与打分题合并为一次请求，默认使用当前 decision 实例（`astrbot/core/provider/decision.py:25-60`；`astrbot/core/star/context.py:181`）。

核心事实链（详见各节）：

- **注册**：模块 import 时，注册装饰器把适配器类同时写进 `provider_registry` 与 `provider_cls_map` 两个全局容器，类型名重复直接抛 `ValueError`；模块 import 推迟到加载阶段，由管理器按 type 字符串 match 分派，导入失败记 critical 后跳过该渠道（`astrbot/core/provider/register.py:6-53`；`astrbot/core/provider/manager.py:456-636`）。
- **加载**：`load_provider` 依次合并 source 配置、解析 `$ENV` 键（仅 chat_completion 类型）、跳过已停用与 agent_runner 条目，校验类继承关系后实例化，最后写入 `inst_map` 和六类实例列表（`astrbot/core/provider/manager.py:712-885`）。
- **路由**：异步入口 `get_using_provider_async` 依次尝试 UMO 会话偏好、各类别默认 id 与实例列表首项；同步入口 `get_using_provider` 仅为兼容保留并已标 deprecated。Local Agent 的默认聊天模型取 `agent_runner.config.model.provider_id`，该值为空时回退实例列表第一个（`astrbot/core/provider/manager.py:318-365`；`astrbot/core/config/agent_runner.py:9-36`）。
- **重试存在两层**：传输层用 tenacity 做 5 次指数退避；OpenAI 适配器内层是 max_retries=10 的错误分类循环，429、上下文超长、非 VLM、工具不可用与图片审核分别对应一种降级动作，细节见 4.2。
- **Key 轮换由错误驱动**：`key` 数组随机取一个进请求，遇到 429 或无效凭据时剔除当前 key 再换下一个，没有定时轮换与健康检查（`astrbot/core/provider/sources/openai_source.py:1084-1103`；`astrbot/core/provider/sources/gemini_source.py:131-158`）。
- **fallback 只有两个消费者**：图片模态降级与空输出/err 回复降级。前者在图片请求需要备用视觉模型时由 `providers.select_image_provider` 选出；后者按 `[provider, *fallback_providers]` 的候选名单逐个尝试，主 provider 没有产出时轮到下一个。普通 5xx 与网络错误不进入 fallback，直接由重试层处理（`astr_main_agent/builder.py:151`；`astr_main_agent/providers.py:174`；`astr_main_agent/tool_loop_agent_runner.py:547-640`）。
- **渠道与请求标识**：Provider 请求默认带 `astrbot/<version>` 的 User-Agent，自定义 Header 可以覆盖它；新增的 MiraRouter OpenAI-compatible 适配器在此之上写入 `X-APP-CODE: astrbot`，SSYCloud 之外多了一个可直接接入的兼容渠道（`astrbot/core/provider/headers.py:1-24`；`sources/mirarouter_source.py:1-20`）。
- **配置持久化**：渠道配置统一落在 `data/cmd_config.json`，由 dict 子类 `AstrBotConfig` 承载；保存用临时文件、fsync、os.replace 加 revision 的原子写，启动时缺项自愈；热更新从 Dashboard API 转到 `ProviderManager` 的增删改方法。
- **管理入口**：WebUI 提供 source 与 provider 两级的查看、新增、编辑、启停、删除和连接测试，非聊天能力的卡片还支持复制；配置文件与备份机制支持整体查看、导入、导出；CLI 只管理少量通用键，本次未找到 provider 专用 CLI 或 TUI；桌面端在本仓库中只是托管同一后端的外部客户端，渠道管理界面未在本仓库确认。
- **未实现机制**：渠道池、权重与负载均衡均未实现，`provider_pool` 与 `persona_pool` 只声明在默认配置里，全仓 grep 无消费者；API Key 明文落盘，Dashboard 列表 API 向有权限前端返回完整 key。

## 总体调用链

```text
data/cmd_config.json（AstrBotConfig，dict 子类）
  ├─ provider_sources[]  键: api_key, api_base, timeout, proxy, custom_headers, key[] ...
  ├─ provider[]          键: id, provider_source_id, model, modalities, custom_extra_body, enable
  └─ agent_runner.config.model   provider_id / fallback_provider_ids / request_max_retries

ProviderManager.__init__（读取配置切片与六类实例列表，manager.py:37-99）
core_lifecycle: ProviderManager.initialize()（manager.py:366-455）
  ├─ 遍历 providers_config -> load_provider
  ├─ 读 curr_provider 全局偏好（sp.get_async, scope=global）设 curr_* 实例
  └─ 后台 asyncio 任务初始化 MCP 客户端（_init_mcp_clients_bg, :444-455）

load_provider（manager.py:712-885）
  -> get_merged_provider_config（合并 source，provider 覆盖 source，id 保留 provider id）
  -> enabled? -> dynamic_import_provider（match 语句导入类）
  -> provider_cls_map 校验 -> cls_type 校验
  -> 按 ProviderType 分支实例化 -> initialize() -> inst_map + 分类列表

请求时：
  get_using_provider_async(provider_type, umo)  （manager.py:342-365）
    1. sp.get("provider_perf_<type>", scope=umo) 命中即用
    2. chat 使用 Local Agent Runner 的 model.provider_id；stt/tts 使用各自 settings.provider_id
    3. 各类别实例列表第一个
    ；可被 event extra selected_provider 覆盖（`astr_main_agent/providers.py:select_chat_provider`）

AstrMessageEvent.request_llm() -> ProviderRequest(func_tool, extra_user_content_parts, ...)
Adapter.text_chat / text_chat_stream（内部 result_chain/tools_call_*）
  -> 每家适配器的 _prepare_chat_payload / error 分类循环 / request_max_retries
  -> LLMResponse（role/result_chain/reasoning/tools_call_*/raw_completion/usage）
```

## 1. Provider 数据模型与配置结构

### 1.1 实体层（`astrbot/core/provider/entities.py`）

工程内存在两个同名目录文件：`entities.py`（613 行，真身）与 `entites.py`（19 行 `from .entities import *` 兼容壳），后者是重命名迁史遗留。

| 实体 | 位置 | 要点 |
|---|---|---|
| `ProviderType` | entities.py:34-40 | 6 种能力：CHAT_COMPLETION / SPEECH_TO_TEXT / TEXT_TO_SPEECH / EMBEDDING / RERANK / DECISION |
| 决策问题与答案 | :43-138 | 选择题（选项映射）、概率判断与有序打分三类问题及对应答案；`DecisionState` 携带调用方上下文，`DecisionError` 表示供应商不可用或响应违约 |
| `ProviderMeta` | :141-154 | 实例元数据：id、model、type（适配器名）、provider_type |
| `ProviderMetaData` | :155-168 | 注册元数据追加 desc / cls_type / default_config_tmpl / display_name |
| `ToolCallsResult` | :169-193 | 工具调用信息 + 结果段，提供 `to_openai_messages` 双向转换 |
| `ProviderRequest` | :194-421 | 请求载体（详见 1.2） |
| `TokenUsage` | :422-453 | input_other / input_cached / output，重载 `+` `-` 便于增量累计 |
| `LLMResponse` | :454-608 | 统一响应（详见 1.3） |
| `RerankResult` | :609-613 | rerank 返回 index + relevance_score |

### 1.2 ProviderRequest

字段（entities.py:194-234）：

- **对话内容**：`prompt` 与 `system_prompt` 承载提示词，`conversation` 与 `contexts` 保存 OpenAI 格式的消息列表，`model` 允许按请求覆盖默认模型，另有已标注废弃的会话 id 字段；
- **多模态素材**：`image_urls`、`audio_urls` 传入媒体地址，`extra_user_content_parts` 在用户消息之后追加内容块，系统提醒与知识库结果走这条路径；
- **工具调用**：`func_tool` 携带 `ToolSet`，`tool_calls_result` 保存多轮工具结果，`append_tool_calls_result` 负责追加（:235-242）。

`_print_friendly_context()`（:243-290）：日志友好，checkpoint 跳过、图片/音频折叠为 `[+N images]`，避免 base64 刷日志（与消息组件 `__repr_args__` 同样的防日志污染思路）。

`assemble_context()`（:291-421）关键行为：

1. 先放用户原始发言；无文本有图片 → `[图片]` 占位；无文本无图有音频 → `[音频]` 占位；
2. `extra_user_content_parts` 用 `model_dump_for_context()` 追加；
3. 图片 / 音频都走 `MediaResolver(...).to_base64_data()` **先转 base64 再入请求**（音频默认 target wav，strict=True），失败 warning 并跳过；
4. 退化：只有单一文本块且无额外部分时返回简单字符串格式 `{"role":"user","content": text}` 保持向后兼容；否则返回多模态 content 数组。

### 1.3 LLMResponse

统一响应（entities.py:454-608）的字段：

```text
result_chain: MessageChain                最终渲染链
reasoning_content / reasoning_signature   推理内容与签名
tools_call_args/name/ids/extra_content    工具结果四个并行数组
raw_completion                            OpenAI/Anthropic/GenAI 原始对象
is_chunk / id / usage
```
- `completion_text` 属性：结果链存在时返回其纯文本（`get_plain_text()`），否则回退 `_completion_text`；setter 会清空链中全部 `Plain` 组件再在头部插入新 Plain（:544-560），保证“最后一次文本写入”是权威的。
- `to_openai_tool_calls_model`（:583-602）输出 pydantic `ToolCall` 模型；旧串行方法与一个拼写错误的别名 `to_openai_to_calls_model`（:603-608）均已打 deprecated，属双重过时痕迹。

### 1.4 配置结构与默认值

- 主配置文件 `data/cmd_config.json`（`AstrBotConfig` 是 dict 子类，`astrbot/core/config/astrbot_config.py:20,31`），明文 JSON。
- 默认值分两层：来源与模型实例在 `astrbot/core/config/default.py`，请求重试、fallback、Persona 与压缩等运行参数在 Agent Runner 配置档案中，其默认值由 `astrbot/core/config/agent_runner.py` 定义并嵌入 `default.py:207-210`。

| 配置项 | 默认值 | 位置 |
|---|---|---|
| `provider_sources` / `provider` | `[]` | default.py:136-137 |
| `provider_settings.default_image_caption_provider_id` | `""` | default.py:140 |
| `provider_settings.provider_pool` | `["*"]`（**无消费者**） | default.py:142 |
| `provider_settings.persona_pool` | `["*"]`（**无消费者**） | default.py:158 |
| `agent_runner.config.model.fallback_provider_ids` | `[]` | agent_runner.py:13 |
| `agent_runner.config.model.request_max_retries` | 5 | agent_runner.py:14 |
| `agent_runner.config.persona.persona_id` | `"default"` | agent_runner.py:17 |
| `agent_runner.config.compression.overflow_strategy` | `"llm_compress"` | agent_runner.py:24 |
| `agent_runner.config.compression.max_turns` | -1（不限制轮次） | agent_runner.py:22 |
| `agent_runner.config.compression.provider_id` | `""` | agent_runner.py:27 |

- 迁移后模型（`astrbot/core/utils/migra_helper.py:45-128` `_migra_provider_to_source_structure`）：provider 条目只剩 6 个字段，其余 key/api_base/timeout/proxy/custom_headers 全部归入 `provider_sources`。这是 v4.x 的重构，旧 key 全部迁到 source。

  迁移后 provider 条目字段：

  ```
  id、provider_source_id、model、modalities、custom_extra_body、enable
  ```

## 2. ProviderManager：加载、热更新与实例生命周期

### 2.1 结构

- **实例登记**：管理器用 `inst_map` 按 provider id 保存所有实例，同时按能力维护 chat、stt、tts、embedding、rerank、decision 六类实例列表。
- **变更通知**：两套机制并存，`set_provider_change_callback` 保留单回调以兼容旧调用方，`register_provider_change_hook` 支持多订阅；`_notify_provider_changed` 逐个通知，单个订阅者抛异常只记 warning。
- **全局默认实例**：`curr_provider_inst` 仍是全局默认实例字段；同步入口 `get_using_provider` 已标 deprecated，调用方应改用 `get_using_provider_async`。

上述结构定义、默认实例字段与同步/异步两个路由入口都集中在 `astrbot/core/provider/manager.py:60-341`。

### 2.2 load_provider 完整流程（manager.py:712-885）

1. 合并配置：`get_merged_provider_config` 在 provider 带 `provider_source_id` 时把 source 配置并入，provider 自己的字段优先，`id` 始终保留 provider 侧的值；
2. 解析环境变量：只有 chat_completion 类型会跑 `_resolve_env_key_list`，把 `$ENV` 或 `${ENV}` 前缀的 key 换成环境变量值，变量未设置时记 warning 并留空串；
3. 筛选条目：`enable=false` 的直接跳过；`provider_type=agent_runner` 的也跳过，agent runner 走独立体系，不归本管理器管；
4. 导入类：按 type 字符串调用 `dynamic_import_provider`，缺依赖导致导入失败时记 critical 并返回，该渠道静默不加载；
5. 校验类：`provider_cls_map` 里查不到对应类时记 error 并跳过；
6. 实例化：按 ProviderType 分支 match，先做 `issubclass` 校验，类实现了 `initialize()`（HasInitialize 协议）就 await 调用；
7. 记录默认实例：各能力分支顺带更新对应的 `curr_*_inst`，取命中默认配置的那个或列表第一个；
8. 登记：最后写入 `inst_map`。

以上步骤的实现位于 `astrbot/core/provider/manager.py:637-885`。

边界：embedding/rerank 没有 `_warn_about_unset_default` 之类的兜底首选项，靠调用方显式选择；实例化整段异常会 `raise`（热更新 API 能收到 500，可转 UI 错误）。

### 2.3 source 与实例的合并语义

`get_merged_provider_config`：`provider_source_id` 命中时用 source 字段填充 provider 缺失项，但始终保留 provider 自己的 `id`。因此"同一来源 + 多模型"在配置表里是 N 个 provider 条目共享一个 source 条目，运行时是 N 个独立实例。

### 2.4 terminate / reload / CRUD

- **删除单个实例**：`terminate_provider` 把实例从各类实例列表移除、清空对应的 `curr_*` 引用、调用实例自身的终止方法，并删除 `inst_map` 条目；
- **重载**：`reload` 在锁内先 terminate 再 load，并按配置里的 `config_ids` 反查 `inst_map` 清理已从配置删除的实例，让实例列表与配置保持一致，最后重选 `curr_*`；
- **删除**：`delete_provider(provider_id, provider_source_id)` 按 id 或按 provider_source_id 级联删除目标 provider 集合，先落盘再同步内存里的 `providers_config`，删除后 API 列表查询不再读到旧实例（#9568）；
- **更新与新增**：`update_provider` 在 id 重复冲突时报错，替换配置、写入文件后 reload；`create_provider` 追加配置、写入文件、加载实例，再同步内存列表；
- **整体终止**：`terminate` 先 cancel MCP 初始化的后台任务，再逐个终止实例，最后调用 `disable_mcp_server`。

上述生命周期与 CRUD 方法集中在 `astrbot/core/provider/manager.py:886-1073`。

`reload` 后若 chat 实例列表为空则当前实例置空；若仍有实例但当前实例为空，则自动选第一个并记 info 日志——"自动选第一"是刻意行为不是异常。

### 2.5 配置生命周期与管理入口

渠道配置的可管理对象分两级：`provider_sources[]` 保存共享的上游地址、凭据和协议参数，`provider[]` 保存具体模型实例及启停状态。配置文件直接表达这两级对象；WebUI 把聊天能力呈现为“source 列表加 source 下的模型实例”，其他能力类型直接展示 provider 卡片。删除 source 会连带删除其关联 provider，重命名 source 会迁移关联 provider 的来源引用，删除单个 provider 只影响该模型实例。这些动作由 Dashboard 配置服务的 source 增删方法与管理器的删除、更新方法协作完成（`astrbot/dashboard/services/config_service.py:1406-1724`；`astrbot/core/provider/manager.py:847-909`）。

#### 配置文件入口

**源码确认**：主配置文件是 `data/cmd_config.json`，来源数组与模型实例数组都是普通 JSON 数组；配置对象在启动时读取该文件并把缺失字段递归补成默认值，保存时走临时文件、fsync、重命名加 revision 去重的原子写（`astrbot/core/config/astrbot_config.py:31-323`）。**静态推断**：直接编辑配置文件即可完成渠道的查看、新增、编辑、启停和删除；复制只能由用户复制 JSON 条目再改写唯一 id；导入导出的载体是整体备份 ZIP 中的 `config/cmd_config.json`，渠道条目随全量配置一起进出，导出读取该文件原文，导入以 replace 模式覆盖现有配置并在覆盖前备份原文件（`astrbot/core/backup/exporter.py:160-167`；`astrbot/core/backup/importer.py:456-475`）。

配置文件的修改由下一次启动读取，或由运行中的 WebUI 保存流程触发热更新，文件层面没有连接测试动作。启停通过 provider 条目里的 `enable` 布尔值表达，配置文件不提供独立的启用与停用操作。默认配置只作为初始化基线：启动时以 `DEFAULT_CONFIG` 建立配置对象，再合并文件内容；source 与 provider 的字段合并发生在命中 `provider_source_id` 的运行时解析阶段（`astrbot/core/config/astrbot_config.py:46-113`；`astrbot/core/provider/manager.py:525-546`）。

#### CLI 与 TUI

CLI 源码里只有 `astrbot conf get/set` 这组常用配置命令。白名单覆盖时区、日志等级、Dashboard 端口、用户名、密码和回调地址，渠道来源、渠道实例与各类 provider 设置都不在其中；因此 CLI 只能查看和编辑少量系统配置，新增、复制、启停、删除、导入、导出与连接测试这些渠道操作都没有对应命令（`astrbot/cli/commands/cmd_conf.py:70-240`，仓库文档 `docs/zh/use/cli.md:87-112`）。写入时它直接落 `data/cmd_config.json`，用的是 CLI 自己的 JSON 写入函数，与配置层的原子写路径相互独立。

本次检查的 CLI 命令注册、依赖和源码目录中**未找到** Textual、prompt-toolkit、curses 等 TUI 框架或 provider 管理命令，TUI 对上述渠道操作的结论为**未找到**；本仓库快照中没有可复查入口。

#### Web / Dashboard

WebUI 是当前源码确认最完整的渠道管理入口。`/api/v1/providers/schema` 返回注册适配器模板、现有 provider/source 和模型元数据；source 端点支持列表、按 ID 查看、新增/更新、重命名时迁移关联 provider、删除，以及在 source 下列出和新增模型 provider。provider 端点支持列表、查看（可选 merged 配置）、新增、编辑、删除、启停和测试（`astrbot/dashboard/api/providers.py:90-183,251-365,383-414`）。这些接口要求 provider scope，旧的 `/api/config/provider*` 与 `/api/config/provider_sources*` 路径仍作为兼容别名存在；两条路径复用同一 `ProviderConfigService`，渠道生命周期只有一套。

聊天能力的新建流程与已有渠道不同：页面先从适配器模板创建 source，source 只在保存时写入服务端；保存后可以调用 source 的模型列表接口，或手动输入模型，再为每个模型创建一个独立 provider，默认 ID 是 `<source_id>/<model>`，默认启用并依据模型元数据填入 modalities、上下文长度和 reasoning（`dashboard/src/composables/useProviderSources.ts:447-472,498-577,580-640`）。已有聊天 source 可以编辑共享字段、删除 source、拉取模型；已有模型 provider 可以编辑、启停、测试和删除，但当前聊天 source 工作台没有复制 provider 的独立按钮。删除 source 会级联删除其下模型，删除模型只删除该模型实例。source 新建的未保存项可在前端状态中直接移除，不会请求后端；已保存项才调用删除 API。

非聊天能力（STT、TTS、Embedding、Rerank，以及页面列出的 Agent Runner）按 provider 卡片管理。页面提供新建、已有项编辑、复制、启停、删除和单项连接测试；复制由前端深拷贝已有配置、生成不冲突的 `<id>_copy`（必要时追加序号），并将副本设置为停用后调用普通 create 接口（`dashboard/src/views/ProviderPage.vue:147-206,485-612`）。因此“复制”不是后端独立能力，已有渠道和新建渠道最终都进入相同的 create/update/delete/reload 链路，但已有项能测试、启停和删除，新建项在保存前只有表单状态，不能测试或启停。

连接测试的边界很明确：WebUI 只对已加载进 `ProviderManager.inst_map` 的 provider 发起测试；基类默认发送 `REPLY PONG ONLY`，具体适配器可覆盖探测请求。未启用的非聊天卡片在前端阻止测试，Agent Runner 页面提示转到“配置文件”页测试，该页面的测试对象是整份配置档案（`astrbot/dashboard/services/config_service.py:1751-1770`；`astrbot/dashboard/src/views/ProviderPage.vue:639-708`；`astrbot/core/provider/provider.py:207-211`）。测试结果只返回本次 available/unavailable 状态和错误，不作为持久化健康评分。

WebUI 的“配置文件”页是另一层配置入口：它可以查看、编辑和保存系统配置及多份 `abconf_<uuid>.json` 配置档案，也能新建、复制、重命名和删除档案；保存档案时可以通过右侧聊天抽屉测试该档案。该页面的复制是整个配置档案复制，不是单个 provider 复制（`dashboard/src/views/ConfigPage.vue:112-167,486-556,672-890`；`astrbot/dashboard/api/config_profiles.py:85-167`）。源码确认配置档案与 provider 管理 API 是并列入口；本次未进一步验证一个非默认档案中的 provider 是否会独立初始化成另一组运行时 provider 实例，避免把档案 CRUD 直接等同于渠道实例隔离。

WebUI 还提供系统级备份入口，可查看备份列表、异步导出、上传或分片上传 ZIP、预检查、下载、重命名、删除和确认导入。导入明确是覆盖式 replace，会清空并覆盖现有数据；它是全局备份恢复，不支持只导入某一个 provider/source，也没有渠道级脱敏导出（`astrbot/dashboard/api/backups.py:106-154,274-357,373-425`；`astrbot/dashboard/services/backup_service.py:271-305,510-561`）。本次在 provider 页面未找到独立的 provider 导入/导出按钮。

#### 桌面端

源码和仓库文档直接确认，桌面端客户端位于独立仓库 `AstrBotDevs/AstrBot-desktop`，本仓库的 `desktop_runtime.py` 只负责识别桌面托管后端、会话密钥和重启提示；它没有另一套 provider CRUD（`astrbot/core/desktop_runtime.py:5-60`；`docs/zh/deploy/astrbot/desktop.md:1-9`）。因此本仓库能确认的桌面端行为是：桌面客户端托管同一个后端，渠道管理能力是否完整暴露取决于外部桌面仓库对 WebUI/API 的封装；桌面端查看、新增、编辑、复制、启停、删除、导入、导出和连接测试的逐项覆盖在本次调查中均为**未验证**；仓库文档中“桌面端提供图形化配置”的说明停留在入口层，逐项行为需在外部桌面仓库核对。

按配置对象归纳，WebUI 对已有 provider 的可操作范围是查看、编辑、启停、删除、测试，非聊天类型另有复制；聊天类型已有 source 还可拉取模型，已有 source 下模型可编辑、启停、删除，但不能在当前页面复制。新建渠道在模板或表单提交前只能编辑本地草稿；source 保存后才可拉取模型，provider 保存并加载成功后才可启停、删除或测试。配置文件和整体备份可以复制或搬运完整 JSON，但不会自动生成新的 provider ID，也没有渠道级连接测试或选择性导入。

## 3. 注册机制

### 3.1 注册装饰器语义（register.py）

- **注册入口**：装饰器 `register_provider_adapter` 接收类型名、描述、能力类型、配置模板和显示名，把适配器类注册进全局容器。
- **冲突处理**：同名类型重复注册直接抛 `ValueError`，重复在注册阶段就被拦住。
- **模板补默认值**：模板缺少 `type` 时填当前类型名，缺少 `enable` 时填 False，缺少 `id` 时同样填类型名。
- **id 占位**：入表时 `ProviderMetaData.id` 先写成 `"default"`，实例化阶段由加载流程覆盖为真实 id。

注册逻辑集中在 `astrbot/core/provider/register.py:14-48`。

### 3.2 已注册适配器全清单（全仓静态检索确认 45 个注册点）

- **Chat（16）**：

  ```
  openai_chat_completion、openai_responses、anthropic_chat_completion、googlegenai_chat_completion、
  groq / longcat / xai / aihubmix / openrouter / zhipu / xiaomi / kimi_code / mirarouter / ssycloud 的 chat_completion
  （另有 minimax_token_plan、xiaomi_token_plan 两个计费/套餐适配也按 chat_completion 注册）
  ```

- **STT（5）**：

  ```
  openai_whisper_api、openai_whisper_selfhost、sensevoice_stt_selfhost、mimo_stt_api、xinference_stt
  ```

- **TTS（13）**：

  ```
  azure_tts、dashscope_tts、edge_tts、elevenlabs_tts_api、fishaudio_tts_api、gemini_tts、genie_tts、
  gsv_tts_selfhost、gsvi_tts_api、mimo_tts_api、minimax_tts_api、openai_tts_api、volcengine_tts
  ```

- **Embedding（5）**：

  ```
  openai_embedding、gemini_embedding、nvidia_embedding、ollama_embedding、dashscope_embedding
  ```

- **Rerank（5）**：

  ```
  vllm_rerank、xinference_rerank、bailian_rerank、nvidia_rerank、tei_rerank
  ```

- **Decision（1）**：`system_one_decision`——System One / Jev 兼容的结构化决策适配器，经 httpx 调用固定决策端点（`astrbot/core/provider/sources/system_one_decision_source.py:42-60`）。

`astrbot/api/provider/` 目录仍是空的 `__init__.py`（旧清理遗留），全部实现都在 `core/provider/`。

## 4. 协议适配与统一消息格式

### 4.1 抽象基类与统一行为（provider.py）

六类能力现在共用 `AbstractProvider`（:33-74）作为根抽象，各能力子类分别实现。`Provider` 基类中几个"提供默认但语义重要"的实现：

- **流式接口**：基类 `text_chat_stream` 直接 `raise NotImplementedError`，流式能力需要各适配器自己实现；
- **上下文裁剪**：`pop_record` 从 contexts 头部弹出 2 条非 system 记录（`poped==2` 时 break），供上下文超长时重试前一并缩小历史；
- **消息归一**：`_ensure_message_to_dicts` 过滤 checkpoint 消息，把剩余内容统一成 dict；
- **连接测试**：`test()` 默认超时 45 秒，发送 `prompt="REPLY PONG ONLY"` 探测文本；STT 适配器改用 `samples/stt_health_check.wav` 探测，TTS 则生成 `get_audio("hi")` 并校验文件大小非 0。

这四项默认实现位于 `astrbot/core/provider/provider.py:144-233`。

TTS 基类 `support_stream()` 默认 False；`get_audio_stream`（:265-307）默认实现是"攒整段 → 一次性 get_audio → 读文件 → 队列送 (text, bytes)"，真正的边生成边送需要子类重写。

Embedding 基类提供批量接口 `get_embeddings_batch`（:353 起）：默认批次 16、信号量限制 3、重试 3 次，并发收集结果（`asyncio.gather(return_exceptions=True)`）并指数退避重试，单批最终失败会抛出"第 N 批失败"。

`DecisionProvider`（:446-484）只声明一次多问题作答的接口，具体请求格式与端点由适配器决定；`system_one_decision` 用固定 HTTP 端点和并发上限实现。

### 4.2 OpenAI 适配器（openai_source.py，57KB）

外层选择与错误分类是本项目渠道管理的最核心代码：

- **重试循环**：`text_chat` 与 `text_chat_stream` 在单次请求里最多重试 10 次，每轮先随机取一个可用 key 装进 client 再发请求，错误分类集中在 `_handle_api_error`，按错误字符串分流（`astrbot/core/provider/sources/openai_source.py:1008-1383`）：
  - **429 限流**：睡眠 1 秒（最后一轮不睡），剔除当前 key 后随机换一个，返回失败标记与新 key 进入下一轮；key 用尽直接抛出。
  - **上下文超长**（`context length`）：弹出部分历史记录并更新 payload 后重试。
  - **模型不支持视觉**（`The model is not a VLM`）：走 `_fallback_to_text_only_and_retry`，只删图片重试，`image_fallback_used` 保证只删一次。
  - **图片内容审核错误**：由 `is_content_moderated_upload_error` 做字符串模式匹配，命中后同样删图重试。
  - **无效附件**：同样删图重试。
  - **工具不可用**（`Function calling is not enabled` 或 tool/function+support）：从 payload 移除 tools 并把 `func_tool` 置空后重试，同时提示用户可在 WebUI 关闭工具。
  - **连接错误**：记录 proxy 信息后重新抛出。
- **协议兼容**：`_prepare_chat_payload` 与 `_finally_convert_payload` 负责消息整形——对 DeepSeek v4、MiMo 这类推理模型，assistant 消息要回填空的 `reasoning_content`，这是厂商协议要求的特殊兼容；Gemini 的 tool response 纯文本会被包成 JSON `{"result": content}`。
- **azure 分支**：配置里存在 `api_version` 时，客户端在构造阶段切到 `AsyncAzureOpenAI`。
- **图片移除**：`_remove_image_from_context` 删光图片后，把原纯图片消息替换为 `{"type":"text","text":"[图片]"}` 占位。
- **key 维护**：`get_current_key`、`get_keys`、`set_key` 三个方法负责读写当前生效的 key 集合。

### 4.3 其他协议要点

- **Anthropic**（`astrbot/core/provider/sources/anthropic_source.py:40-599`）：`_prepare_payload` 把 OpenAI 格式消息转成 Anthropic 格式，thinking 块连同签名一起回传；prompt caching 用 `{"type":"ephemeral"}` 的 cache_control 标记，作用在消息末块上；key 初始化只取列表第一个，默认超时 120 秒。
- **Gemini**（`astrbot/core/provider/sources/gemini_source.py:49-180`）：走 `google.genai` SDK，超时由显式 `HttpOptions` 与 httpx 客户端控制，默认 180 秒；安全设置由类别与阈值两张映射表决定；错误处理在 429 或“API key not valid”时换 key。

## 5. 请求路由与会话绑定

### 5.1 get_using_provider_async 精确分支（manager.py:342-365）

```text
先读 umo scope 的 provider_perf_<type> 偏好，命中且实例存在即用
  ├─ 无强制偏好时（_resolve_using_provider :244-315）：
  │    chat      -> Local runner 的 agent_runner.config.model.provider_id -> [0]
  │    stt/tts   -> settings.provider_id，settings.enable=false 或无 id 则 return None
  │    decision  -> curr_decision_provider_inst -> decision 列表第一个
  │    -> 其他 raise ValueError("Unknown provider type")
末尾：provider 为空但偏好 id 有值 -> warning（可能是 id 已改）
```

配置档案（`acm.get_conf(umo)`）参与解析：chat 分支从该档案的 `agent_runner.config.model.provider_id` 取默认模型，stt/tts 读取同一档案的 `provider_*_settings`。

### 5.2 会话级/事件级/命令级切换

- **会话偏好**：`set_provider` 把选择写入 umo scope 的 `provider_perf_chat_completion`，经 SharedPreferences 的会话读写落到 SQLite；管理员用 `/provider` 命令切换（`astrbot/core/provider/manager.py:160-239`；`builtin_stars/builtin_commands/commands/provider.py:231-246`）。
- **事件级 model 覆盖**：请求构建时从事件 extra 取 `selected_model` 赋给 `ProviderRequest.model`，各适配器再用 `model or self.get_model()` 决定实际模型（`astr_main_agent/request.py:267`）。
- **WebChat/API 临时选渠道**：这类请求直接从事件 extra 读 `selected_provider`（`astr_main_agent/providers.py:43`）。
- **会话组批量**：`batch_update_service` 用 `sp.session_get`/`sp.session_put` 逐会话读写，实现整组会话的统一变更（`session_management_service.py:438-494`）。

### 5.3 专用模型绑定

| 用途 | 配置键 | 位置 |
|---|---|---|
| 图像描述 | `provider_settings.default_image_caption_provider_id` | default.py:140 |
| 上下文压缩 | `agent_runner.config.compression.provider_id` | agent_runner.py:27；`pipeline/process_stage/.../internal.py` |
| 知识库 embedding/rerank | kb 记录内 | kb_helper |
| 结构化决策 | `curr_provider_decision` 全局偏好，回退 decision 实例列表 | manager.py:300-305、:393-442 |
| agent runner（dify/coze/dashscope/deerflow）| 各自独立 id | agent_runner.py:37-81 |

### 5.4 模型元数据（LLM_METADATAS）

`astrbot/core/utils/llm_metadata.py:30-66` 从 `https://models.dev/api.json` 拉取 `LLMMetadata`（context window/模态/tool_call 能力），传给 WebUI 展示与上下文裁剪（`max_context_tokens` 在请求构建时注入）。它是"事实字段来源"而不是"路由键"。

## 6. 错误处理、重试与 Key 轮换

两层重试的完整拼图：

**传输层**（provider/sources/request_retry.py）基于 tenacity：默认 5 次、指数退避 0.2s-30s、可重试判定 `_is_retryable_provider_request_error` 覆盖连接错误 / APIConnectionError / APITimeoutError 与下列状态码，429 可由 `retry_rate_limits=False` 关闭：

```
408, 409, 429, 500, 502, 503, 504, 529 或 5xx
```

`agent_runner.config.model.request_max_retries` 页面可调（agent_runner.py:14）→ text_chat 形参 `request_max_retries`。

**适配器内层**（OpenAI）max_retries=10 的错误分类循环（见 4.2），能识别 429/context/非 VLM/审核/工具不可用。两者叠加意味着一个 429 极端情况下最多可能尝试十几次。

**Key 轮换边界**：`key` 数组在适配器构造时解析为 `self.api_keys`，429 或无效时被剔除——多 key 只是错误驱动的本地轮换，不跨实例/渠道共享。Anthropic 只取 `key[0]` 且不轮换（:105-111）。

**fallback 语义**：参见 5.3，只覆盖图片模态退化 + 空输出/err 回复；`_iter_llm_responses_with_fallback`（tool_loop_agent_runner.py:547-640）候选 `[provider, *fallback_providers]`，主 provider 空输出（`EMPTY_OUTPUT_RETRY_ATTEMPTS=3` 指数退避）轮到下一个，普通错误抛给上层重试。

## 7. 配置持久化、热更新与密 param 处理

### 7.1 读写链路

- 启动与保存：`astrbot/core/__init__.py:32` 构造 `AstrBotConfig`，`check_config_integrity` 递归补齐缺失项，`save_config` 及其异步版本用临时文件、fsync、os.replace 加 revision 去重完成原子写（`astrbot/core/config/astrbot_config.py:192-293`）。
- 多配置档案：`AstrBotConfigManager` 维护默认配置与多份 `abconf_<uuid>.json` 会话配置，按会话 umo 路由到对应档案；档案映射以 global 键存放在 SharedPreferences，启动时异步加载（`astrbot/core/astrbot_config_mgr.py:32-300`，装配点在 `core_lifecycle.py:190`）。
- 配置 CRUD：create/delete/update 全部异步，并用 `_abconf_lock` 串行化（#9582/#9584）。
- 热更新：Dashboard REST 接口（`astrbot/dashboard/api/providers.py`、`services/config_service.py`）调用 ProviderManager 的 create/update/delete 方法。
- 表单模板：`get_provider_schema` 把 `CONFIG_METADATA_2` 模板与 `provider_cls_map` 里该适配器的 `default_config_tmpl` 合并，产出 WebUI 的动态表单（`astrbot/dashboard/services/config_service.py:1570` 起）。

### 7.2 敏感信息处理（关键事实 + 设计边界）

- `key` 以数组存 `cmd_config.json` **明文**，无加密；`save_config` 不脱敏。
- `_resolve_env_key_list` 只在 `load_provider` 且类型为 chat_completion 时执行；key 为空字符串则发空 key，请求必然 401，但加载时不会报错，直到请求时才暴露。
- Dashboard `list_providers`（config_service.py:1842-1884）把完整 key **返回给前端**（只有日志截断前 12 字符，如 openai_source.py 的 key 日志）。
- 配置变更日志对 token/secret 字段掩码（`dashboard/services/config_service.py` 的日志掩码逻辑），且仅沙箱/computer 环境生效——**普通本地部署不脱敏**。

## 8. WebUI（Dashboard）渠道配置面

- `dashboard/src/views/ProviderPage.vue`（920 行）按 provider 类型 tab 分组（v-tabs + provider-config 表单），选择器消费 `provider-cls-map` 与 schema 模板。
- 后端有 ProviderSource 与 ProviderConfig 两套 schema（config_service.py + schemas.py:465/482），支持"source 级管理 + 模型实例级管理"两个粒度。
- Dashboard 还有工具页（tools_service.py）展示内置/插件/MCP 工具状态（`origin="builtin"` + readonly），消费 `get_builtin_tool_config_statuses`（详见 Agent 工具笔记）。

## 9. 能力边界与横向比较要点

### 已实现

- 四类协议（OpenAI / OpenAI-Responses / Anthropic / Gemini）+ 大量 OpenAI-Compatible 模板；`api_base` 自定即可接入任意兼容上游；
- 六类能力（chat/STT/TTS/embedding/rerank/decision）统一抽象 + 45 适配器；
- 单渠道多 Key 错误驱动轮换；
- 多层重试（transport tenacity + 适配器内层分类降级：弹历史/删图/去 tools/换 key）；
- 限定场景 fallback（图片模态 / 空输出 / err role）；
- 会话级 provider/model 偏好、事件级覆盖、专用模型绑定；
- 结构化决策能力：插件经 `context.decision.ask()` 对选择题、概率判断与打分题批量取值，默认可切到自建的 decision 渠道；
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
| `astrbot/core/provider/provider.py` | 6 类抽象基类 + 通用行为 |
| `astrbot/core/provider/decision.py`、`sources/system_one_decision_source.py` | 结构化决策服务与 System One 适配器 |
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
| `dashboard/src/composables/useProviderSources.ts`、`dashboard/src/components/provider/ProviderModelsPanel.vue` | 聊天 source 与模型实例的 WebUI 生命周期 |
| `astrbot/cli/commands/cmd_conf.py` | CLI 常用配置白名单与直接 JSON 写入 |
| `astrbot/dashboard/api/backups.py`、`services/backup_service.py` | 全局备份的查看、导入、导出与文件管理 |
| `astrbot/core/backup/exporter.py`、`importer.py` | `cmd_config.json` 在备份 ZIP 中的导出与覆盖式导入 |
| `dashboard/src/views/ConfigPage.vue`、`astrbot/dashboard/api/config_profiles.py` | 多配置档案的查看、复制、编辑、删除与保存测试入口 |
| `astrbot/core/desktop_runtime.py`、`docs/zh/deploy/astrbot/desktop.md` | 桌面托管边界；桌面客户端位于外部仓库 |

## 11. 未验证事项

1. 未启动真实 LLM 调用；各厂商字符串 match 降级启发式未被线上验证。
2. `provider_pool`/`persona_pool` 无消费者基于全仓 grep；若存在动态拼接 key 的隐式引用可能漏检。
3. minio TTS/SST 各适配器内部的厂商参数细节未逐行展开（本文聚焦框架层）。
4. `dynamic_import_provider` 覆盖面与 45 个注册点基于静态检索，个别适配器（如 `azure_tts` 的厂商参数）未读全。
5. 未运行 CLI、WebUI、备份导入导出或配置热更新的端到端流程；新增、编辑、启停、删除和测试的保存成功、生效时机及异常提示主要依据静态事件绑定和后端调用链。
6. TUI 在本仓库中未找到；外部桌面仓库 `AstrBotDevs/AstrBot-desktop` 未拉取，桌面端逐项渠道操作覆盖、桌面端是否完整复用 WebUI 以及桌面端备份行为均未验证。
7. 未验证非默认 `abconf_<uuid>.json` 配置档案中的 provider 是否独立初始化运行时实例，也未验证备份导入后 ProviderManager 是否无需重启即可恢复全部 provider 状态。
8. 未运行验证配置文件手工复制 provider 条目时的 schema 校验、ID 冲突、source 引用完整性和跨版本迁移结果；“可表达”结论是静态推断。
