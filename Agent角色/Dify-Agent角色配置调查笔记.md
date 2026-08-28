# Dify Agent 角色配置调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态核对 AppModelConfig、Prompt IDE、传统 Agent Chat、Agent v2 roster/snapshot 与请求 prompt transform；未运行模型、控制台或 Agent Runtime
>
> 调查范围：应用提示词配置与 Agent v2 的可复用 Agent 实体；不重复工具执行、会话持久化和最终上下文的完整实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 没有跨所有应用模式可选的“角色卡/Persona 库”。对基础 Chatbot 和文本生成应用，角色效果来自随 `AppModelConfig` 发布的 simple/advanced prompt、变量、模型参数、知识和功能配置；它是应用行为定义的一部分，不是终端用户在会话中切换的独立身份。传统 Agent Chat 则把 agent mode、策略和工具配置放进其应用模型配置。

Agent v2 是不同层级的实体：roster Agent 可拥有编辑草稿、build draft 与不可变 revision/snapshot，并可被工作流或 Agent App 运行绑定。它最接近可复用 Agent 角色，但其运行环境由独立 Dify Agent Runtime 承接，且当前还不能将其简化为传统 Chatbot 的“system prompt 模板”。因此本篇将“应用配置角色”和“版本化 Agent 实体”分开，不把 workspace 成员 role 或 API `role` 字段误记为角色配置。

## 总体生效链路

```text
基础应用：作者编辑 AppModelConfig 的 prompt / 变量 / 模型等
  -> 发布并切换 App 的 active config
  -> 公开聊天或 service API 按 App mode 读取配置
  -> SimplePromptTransform 或 advanced prompt transform 组合上下文
  -> 模型调用

Agent v2：作者编辑 roster Agent / draft
  -> publish 生成 revision 或 snapshot
  -> Agent App / workflow 将 owner、版本与配置绑定到 workspace
  -> Dify Agent Runtime 执行；API 保存 binding、会话和清理状态
```

基础应用 simple prompt 的实际转换见 `api/core/prompt/simple_prompt_transform.py`：它按模型类型决定以 system message 加入预提示词，或把预提示、上下文、历史和 query 按模型规则编成 completion 输入。该文件能确认 pre-prompt、变量、上下文、历史与 query 的转换关系，但最终上下文还受应用模式、检索、记忆和模型配置影响，完整顺序见[对话请求与上下文](../对话请求与上下文/Dify-对话请求与上下文调查笔记.md)。

## 1. 实体、存储与版本边界

`AppModelConfig` 是传统应用的配置快照，App 只持有当前 active config 指针。发布会新建配置并切换指针；Console debug 可传未发布覆盖配置，但生产调用读取 active config。它可包含 prompt 类型、simple/advanced prompt、变量、数据集、模型和功能设置。细节见 `api/controllers/console/app/model_config.py` 及[独特功能](../独特功能/Dify-独特功能调查笔记.md)的 Prompt IDE 卡。

Agent v2 的 roster、Agent Soul、草稿、build draft、snapshot/revision 是另一组对象。发布把可编辑配置转成不可变运行版本，已有版本可以回写为新的常规 draft；运行绑定会校验 tenant、owner、Agent、home snapshot 和 config version。这支持同一 Agent 被工作流引用并避免既有绑定自动漂移，但 Agent Runtime 的物理版本加载未运行确认。

## 2. 创建、选择与会话绑定

基础应用的角色式配置由应用作者在 Console 编辑，终端用户只能向已发布应用输入 query、变量和文件；公开聊天没有确认到通用 persona picker、会话级角色副本或从角色库导入的入口。调试调用可暂时用未发布配置，属于作者工作面而非用户会话选择。

Agent v2 提供 roster、配置、预览、版本、访问、日志和监控入口。Agent App 新会话为当前 generation 创建 binding；已有 Conversation 继续使用原 binding 所指的 immutable generation。此处的稳定性来自运行绑定而不是把完整 role 文本复制进每条 Message，消息/会话的精确落盘边界仍见[会话与消息管理](../会话与消息管理/Dify-会话与消息管理调查笔记.md)。

## 3. 提示字段、模型与能力挂接

基础 Prompt IDE 可编辑预提示词、变量、上下文数据集、外部数据、模型参数和部分文件/多媒体功能。simple prompt transform 先解析用户变量与特殊 context/query/history 占位，再根据 chat 或 completion 模型形成消息或字符串；因此“角色文本”并非独立字段，更不是不经模型适配直接传递的固定 system prompt。

传统 Agent 的工具、策略和模型引用属于其 app config；Agent v2 的 Soul/配置则在发布后成为版本化运行输入。模型凭据由租户 Provider 配置解析，工具可来自内置、API、插件、MCP 或兼容 workflow。角色配置能够声明这些资源，并不表示它们都能成功执行或自动获得逐调用批准，详见[Agent 工具](../Agent工具/Dify-Agent工具调查笔记.md)和[LLM渠道管理](../LLM渠道管理/Dify-LLM渠道管理调查笔记.md)。

其中包含媒体创作方向：传统 `agent-chat` 可以把 DALL-E、Stable Diffusion 或其他已安装的媒体工具编入工具列表（`README.md:108`）。仓库自带的“SVG Logo Design”推荐应用声明了 DALL-E 3 生成图片后再调用 Vectorizer 转为 SVG 的两步流程（`api/constants/recommended_apps.json:463`）。工具引擎会把 `IMAGE` / `IMAGE_LINK` 响应转为工具文件和消息输出（`api/core/tools/tool_engine.py:254-291`），因此 Agent 可以在一次会话内基于文字需求触发生成，并将结果交还给用户或后续节点。这个方向属于“Agent 驱动的媒体调用”，不是没有覆盖；模板所声明的跨工具传递与真实外部工具执行尚未运行验证。

但它尚不能据此归入本项目笔记的独立“媒体创作”主链：本次静态检查没有找到 Dify 自身为这类结果维护的媒体专用工作台、生成任务历史、可编辑版本/分支或跨会话资产复用闭环。Dify 负责的是工具选择、调用与结果回流；实际生成、编辑、异步任务和资产生命周期仍由 DALL-E、Stable Diffusion、Vectorizer 或其他插件/外部服务承接。两种表述分别说明编排能力与产品工作站能力，不能相互替代。

开场白、建议问题、输入变量和应用图标是发布应用的可见配置，不是可独立复用的角色资产。用户档案、世界书、角色头像库、会话级人格覆盖和角色卡格式导入在本次范围内未找到。

## 4. 导入导出、可见性与历史语义

应用 DSL 和 Agent DSL 可以迁移定义，但其目标是应用/Agent 配置，而非聊天角色卡互换。跨租户导出会清理 credential、secret、token、文件 ID 等敏感或源工作区数据；同工作区 copy 的 secret 规则不同，不能一概称作安全角色分享。未知字段的解析、兼容与实际生效仍需按 DSL 路径验证。

公开聊天可见的是应用名称、开场白、变量和对话输出，未确认其显示“实际 prompt、版本化 Agent、模型、工具授权和局部覆盖”的完整运行信息。历史语义也分两类：传统应用的后续调用通常读取当前 active config，Agent v2 已绑定会话固定到创建时 generation。两者均不能仅凭 UI 文案推断为完整可复现的 prompt 快照。

## 设计取舍与已确认边界

- Dify 以可发布应用定义作为传统“角色”的所有者，适合作者交付稳定应用，不以终端用户自由切换 Persona 为目标。
- Agent v2 增加了真正的版本化、可复用 Agent 对象，但它与传统 prompt IDE 是并存而非统一模型。
- 传统 Agent 已覆盖由工具调用驱动的图片生成/转换；未发现通用角色卡格式、用户自建 Persona 库、聊天中的角色快速切换或角色级别的媒体资产/世界书机制。

## 未验证事项

- 真实模型下 simple/advanced prompt、检索、记忆、文件和工具的最终顺序及 Provider 差异。
- AppModelConfig 版本浏览、回滚和多人编辑冲突的 UI/服务端语义。
- Agent v2 Runtime 的 workspace 创建、版本加载、工具环境、暂停恢复与物理清理。
- DSL 的实际往返、缺失依赖和敏感字段过滤效果，以及公开聊天显示的真实运行元数据。

## 关键源码索引

- `api/models/model.py`：App 与 AppModelConfig 的持久化模型。
- `api/controllers/console/app/model_config.py`：应用配置保存、发布与 active config 切换。
- `api/core/app/app_config/easy_ui_based_app/prompt_template/manager.py`：应用 prompt 模板配置转换。
- `api/core/prompt/simple_prompt_transform.py`：simple prompt、变量、上下文、历史和 query 的模型输入转换。
- `README.md:108`、`api/constants/recommended_apps.json:463`：媒体工具清单与 SVG Logo Design 的声明式编排样例。
- `api/core/tools/tool_engine.py:254-291`：图片及链接型工具结果转换为文件与消息输出。
- `web/features/agent-v2/`、`api/services/agent/composer_service.py`、`api/services/agent/workspace_service.py`：roster/draft/snapshot 与运行 binding。
