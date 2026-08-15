# SillyTavern 独特功能调查笔记

> 调查对象：`E:\works\git\SillyTavern`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：只读盘点根目录（README 无功能清单）、`public/scripts/extensions/` 扩展注册表、`default/content/` 产品资产、`public/scripts/` 核心模块与服务端端点；未修改仓库源码
>
> 调查范围：角色卡、World Info、swipe、正则、STscript 之外的独特能力候选——内部扩展体系、格式化模板/预设体系、本地向量存储、表达式系统、连接配置、作者注释、角色库管理与声称存在的 QR 生成；以仓库实际为准反向盘点
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 根 README 只有一句话（README.md:1-13），无功能清单；产品表面主要从 `public/scripts/extensions/`（14 个内置扩展 + manifest 注册表）与 `default/content/`（预设/背景/工作流资产）反向盘点。已有类目笔记对角色卡、World Info、swipe、正则、STscript、群聊、工具调用、渲染链覆盖很深，本次盘点的增量候选集中在**提示词工程工作台**与**扩展生态**两个方向：

| 候选 | 证据状态 | 一句话结论 |
|---|---|---|
| 格式化模板/预设体系（六类预设 + 角色名绑定自动选择 + 主导入导出） | `主链确认`（静态证据） | 切换聊天即按角色/群名自动选预设；六类模板（instruct/context/sysprompt/textcompletion/reasoning/start-reply-with）统一管理器与主导入导出 |
| 本地向量存储（Vector Storage 扩展） | `主链确认`（静态证据） | 每次生成前拦截器按相关性检索历史消息与附件数据银行，把命中的旧消息重排注入提示；嵌入支持远程 Extras/本地 WebLLM/koboldcpp |
| 内部扩展体系（manifest + 事件总线 + 安装流程） | `归并已有类目` | 机制（manifest 加载/依赖校验/install 流程/generate_interceptor）已在 Agent 工具笔记维度 10 覆盖；本笔记补充扩展产品目录盘点 |
| 表达式系统（Character Expressions） | `入口确认` | 情绪分类（LLM 或 classify 模块）→ 角色表情 sprite 切换，含自定义表情与流式更新；依赖 Extras API 或本地 LLM |
| 连接配置（Connection Profiles） | `入口确认` | 把 api/model/proxy/secret 等 slash 命令序列录成配置文件，切换聊天时回放；单文件 JSON 持久化 |
| 作者注释（Author's Note） | `入口确认`/`归并已有类目` | floating-prompt 注入机制（depth/position/role/interval + 元数据持久化）；属于“上下文 DSL 与提示词工程”自然聚类，已并入已有类目描述 |
| 角色库管理与批量编辑 | `归并已有类目` | 角色卡存储/导入/缓存已由 Agent 角色笔记覆盖；bulk-edit.js 批量编辑为增量入口 |
| QR 生成 | `声明不符`（本次未找到） | 全仓检索 `qrcode|QRCode|generateQR` 零命中，见未验证事项说明 |

结论：SillyTavern 超出角色生态的独特能力是**以“提示构建 = 模板编排”为核心的提示词工程工作台**（六类模板 + 角色绑定 + 主导入导出 + 向量重排注入 + 表达式/连接配置等扩展面），这与 VCP 系（TVS）、AIO Hub（宏管道）一起构成“上下文 DSL 与提示词工程”自然聚类的样本。

## 系统边界

- 前端为原生 JS + jQuery 命令式流水线（`public/scripts/`），服务端为 Node（`src/endpoints/`）持久化聊天/角色/预设文件；扩展在浏览器侧以 `import()` 动态加载。
- 与既有笔记分工：角色卡格式（[Agent角色笔记](../Agent角色/SillyTavern-Agent角色配置调查笔记.md)）、渲染链（[消息渲染器笔记](../消息渲染器/SillyTavern-消息渲染调查笔记.md)）、生成与上下文拼装（[对话请求与上下文笔记](../对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md)）、工具调用与扩展机制（[Agent工具笔记](../Agent工具/SillyTavern-Agent工具调查笔记.md)）。

## 介绍声明与候选盘点

README 无功能清单（README.md:1-13）。按任务要求从三个来源反向盘点：

1. **扩展注册表**：`public/scripts/extensions/` 14 个内置扩展，覆盖附件、记忆、正则、绘图、翻译、TTS、表情、向量检索等方向（完整目录见能力三扩展目录表）；第三方扩展经 Git 安装到 `third-party/`（机制已在 Agent 工具笔记覆盖）。
2. **产品资产**：`default/content/`——按用途分组：
   - `presets/`：六类预设目录（context、instruct、samplers、system、regex、quick responses、textgen、reasoning），其中 context 含 20+ 上下文模板（Adventure/ChatML/Default/Dots1 等）；
   - `backgrounds/`：20+ 场景图；
   - `user.css`：自定义样式；
   - `comfy workflow`：Char_Avatar/Default 两个 ComfyUI 工作流。
3. **核心模块**：`public/scripts/` 中预设管理、作者注释、角色数据与批量编辑、连接配置、表情、向量检索等模块构成产品表面（各模块详见下文能力描述）。

## 已确认的独特能力

### 能力一：格式化模板/预设体系（`主链确认`，静态证据）

**用户目标**：把“提示长什么样”（上下文模板/指令模板/系统提示/采样参数/推理格式化）做成可命名、可导出、可随角色自动切换的资产——提示词工程的产品化。

**主链**：切换聊天时，系统监听 `CHAT_CHANGED` 事件取当前角色名或群名，在预设库中精确匹配（`public/scripts/preset-manager.js:985` 事件绑定，`:385` 匹配），命中即应用该预设（`:49-76`）；生成时由上下文拼装链消费（拼装细节在对话请求与上下文笔记）。

**事实对象**：六类模板由 `PresetManager.masterSections` 统一描述（`preset-manager.js:117-207`）：
- instruct：指令模板（输入/输出序列等）；
- context：主模板（`story_string`）；
- sysprompt：系统提示（name/content）；
- preset：文本补全采样参数；
- reasoning：推理格式（prefix/suffix/separator）；
- srw：Start Reply With 回复前缀。

每类有 schema 探测函数（`isPossiblyInstructData` 等，`:209-236`）。保存到服务端 `/api/presets/save`（`:477`），按 apiId 分目录持久化。

**用户结果**：“Save Preset As” 提示 “Use a character/group name to bind preset to a specific chat”（`:445`）——预设名与角色名一致即自动绑定；`performMasterImport`（`:244-300`）对导入文件做六类 schema 自动探测并逐节确认导入（master import 弹窗），实现整套提示工程配置的单一文件迁移。

**持续性**：服务端预设文件（`src/endpoints/presets.js` 同族端点）；不同后端（OpenAI/textgen/kobold/novel/instruct/context/sysprompt/reasoning）各自一套预设名单（`getPresetList`，`:522-580`）。

**外部依赖**：无（纯前端 + 本机服务端文件）。

**独特性判断**：这是“提示词工程工作台”而非单一功能：模板分类体系 + 角色名绑定 + 模糊/精确自动选择 + 主导入导出的组合，在本样本中只有 VCP 系 TVS 与 AIO Hub 宏管道接近（聚类的比较问题：编译对象分别是模板文件/DSL 文本/宏文本）。标签：`上下文语言`。

### 能力二：本地向量存储与历史重排（Vector Storage 扩展）（`主链确认`，静态证据）

**用户目标**：长聊天中按语义召回相关旧消息并重新注入（而不是只按顺序截断）；附件文件（Data Bank）与 World Info 也可向量化检索——浏览器侧的本地 RAG。

**主链**：扩展 manifest 声明生成前拦截器（`public/scripts/extensions/vectors/manifest.json`），每次生成前拦截器调用重排函数（`index.js:776` 实现）：清空旧的扩展提示（聊天与数据银行双 tag）→ 按设置处理附件文件与 World Info → 聊天消息数不足保护阈值则跳过 → 取查询文本 → 做嵌入相似度检索（`queryCollection`，`:1151`）→ 对命中消息按相关性顺序重排，从原 chat 数组摘出并格式化为单块文本 → 注入到指定 depth/position。其余步骤的入口行号见文末索引。

**事实对象**：向量 collection 按 chatId 与文件 hash 组织（`insertVectorItems`/`deleteVectorItems`，`:1051,1127`）；附件按分块参数入库、检索后注入（入口行号见文末索引）；消息 hash 用 `getStringHash(substituteParams(message.mes))`（`:829`）保持宏展开后的内容一致。

**执行域**：全部在浏览器前端；嵌入来源三选一——远程 Extras API embeddings 模块、浏览器内 WebLLM（`webllm.js`，`createWebLlmEmbeddings`，`:1435`）、koboldcpp（`:1454`）。

**持续性**：向量库持久化（扩展设置 + 本地向量存储）；聊天切换后 `onChatEvent` 防抖同步（`:893`）。

**外部依赖**：Extras API 为可选项；WebLLM 为完全本地选项。

**独特性判断**：把“历史消息按语义重排进提示”做成生成前拦截器，且对聊天/附件/世界书三类来源统一向量化——这是普通上下文截断之外的独特上下文编排能力，可作为“上下文 DSL 与提示词工程”聚类与 VCP ContextFolding（数组元数据+折叠替换）横向比较的样本。

### 能力三：内部扩展体系与扩展产品目录（`归并已有类目` + 产品盘点）

机制面已由 [Agent 工具笔记](../Agent工具/SillyTavern-Agent工具调查笔记.md) 维度 10 覆盖（manifest.json 拉取/`requires`/`dependencies`/`minimum_client_version` 校验、`import()` 动态加载、`generate_interceptor` 全局拦截器、Git 安装信任流、服务端 plugins 加载）。本笔记补产品目录盘点：

| 内置扩展 | 作用（按 manifest display_name 与入口确认） | 证据状态 |
|---|---|---|
| connection-manager | 连接配置：把连接所需的 slash 命令序列（端点、预设、模型、代理、停止串、推理模板、密钥等）录成 profile 并在切换聊天时回放（`connection-manager/index.js` `CC_COMMANDS` 列表） | `入口确认` |
| expressions | 表情系统：LLM 情绪分类（`DEFAULT_LLM_PROMPT` 分类提示，`expressions/index.js`）或 classify 模块 → 角色表情 sprite 切换，自定义表情与流式更新 | `入口确认` |
| vectors | 见能力二 | `主链确认` |
| memory | 世界书驱动记忆（World Info 体系内） | 归并（世界书已有覆盖） |
| quick-reply | 自动化脚本（事件触发 STscript） | 已有覆盖（对话请求与上下文笔记 §8、Agent 工具笔记 §11.3） |
| regex / stable-diffusion / translate / tts / caption / token-counter / gallery / assets / attachments | 正则、出图、翻译、TTS、看图、计数、媒体库 | 分属已有类目或通用扩展，未专项调查 |

**表达式中链**（`入口确认`）：`expressions/index.js` 监听消息渲染事件 → 从最后一条消息文本分类情绪（2 秒轮询，流式 10 秒）→ 按 `extension_settings.expressionOverrides` 与角色卡表达式集匹配 → 切换 `#avatar` 表情图。依赖 classify 模块或 LLM 分类提示；静态代码确认入口与状态，未运行验证。

**连接配置主链**（`入口确认`）：`connection-manager/index.js` 录制当前连接状态为一组 slash 命令值（`DEFAULT_SETTINGS.profiles`）→ `selectedProfile` 持久化 → 切换聊天时按 profile 回放命令（含 `secret-id` 切换）。单文件 JSON 设置持久化。

### 能力四：作者注释（Author's Note）（`入口确认`/`归并已有类目`）

`public/scripts/authors-note.js` 为独立的 floating-prompt 模块（`MODULE_NAME = '2_floating_prompt'`，刻意排在 memory 之后）：提示文本 + 注入参数（间隔、深度、位置、角色）+ `/note` slash 命令读写；文本存聊天元数据 `chat_metadata`（note_prompt 等字段，`:25-33`），随聊天文件持久化。注入位置支持 replace/before/after（`chara_note_position`，`:41-45`）。该机制已并入“上下文 DSL 与提示词工程”聚类的描述（Agent 角色笔记 §10.3 提及可覆盖 `post_history_instructions`）；作为独立候选只到 `入口确认`，与预设体系/向量注入共同构成提示工程工作台。

## 已归并到现有类目的能力

- **角色卡/字符管理**：角色卡格式、PNG/JSON/CharX/BYAF 导入、存储与缓存已由 Agent 角色笔记覆盖；`char-data.js`/`bulk-edit.js`（批量编辑覆盖层）为管理增量入口，不构成新类目。
- **World Info**：Agent 角色笔记 §4 覆盖条目结构；记忆扩展在 World Info 体系内。
- **swipe / 群聊 / 书签分支**：会话与消息管理、对话请求与上下文笔记已覆盖。
- **STscript / 正则 / Quick Reply**：Agent 工具笔记维度 11、对话请求与上下文笔记 §8 已覆盖。

## 声明不符、外部依赖与暂缓项

- **QR 生成**：任务提示中列为候选，但全仓检索（以 qrcode、QRCode、qr-code、generateQR 等关键词覆盖 `public/scripts/**/*.js` 与 `src/**/*.js`）零命中；`data/` 与 `default/` 亦无相关资产。结论：本次未找到该能力，按指南写清检查范围，不写成项目级绝对结论。若指“通过第三方扩展提供”，则属于外部扩展生态，不在本仓库。
- **表达式/向量/连接配置的运行时行为**：依赖 Extras API、WebLLM、classify 模块或 LLM 分类调用，静态代码只确认到入口与状态；视觉效果与性能未运行验证。
- **第三方扩展生态**（Git 安装的 `third-party/*`）能力不在本仓库盘点范围，机制面见 Agent 工具笔记。

## 对特色贡献统计的影响

- 建议新增主贡献候选：**提示词工程工作台（六类模板 + 角色名绑定 + 主导入导出）**（标签：`上下文语言`）；**向量历史重排注入**（标签：`上下文语言`、`记忆演化`边界）可作为辅助贡献。
- 与“上下文 DSL 与提示词工程”自然聚类（AIO Hub、VCP 系、SillyTavern）对齐：比较维度为模板文件/DSL/宏/向量注入的编译与消费对象。
- 表达式系统与连接配置为 `入口确认`，暂不进入特色统计。

## 未验证事项

- 预设角色名绑定在真实会话中的触发（静态确认 CHAT_CHANGED 事件绑定；`findPreset` 为精确匹配，Fuse 模糊匹配用于导入场景 `:949`）。
- 向量存储的检索质量与 WebLLM 本地嵌入的可用性（未运行）。
- 表达式分类的实际情绪映射与自定义表情流程。
- 连接配置 profile 回放与当前连接状态的冲突语义。
- bulk-edit 批量编辑的完整 UI 工作流。

## 关键源码索引

- 预设体系：`public/scripts/preset-manager.js`（autoSelectPreset 49-76、masterSections 117-207、findPreset 385、performMasterImport 244-300、CHAT_CHANGED 绑定 985）。
- 向量存储：`public/scripts/extensions/vectors/manifest.json`（generate_interceptor）、`index.js`（rearrangeChat 776-859、queryCollection 1151、insertVectorItems 1051、附件分块 727/检索注入 678、WebLLM 嵌入 1435）。
- 扩展体系：`public/scripts/extensions.js`（manifest 加载 533-622、runGenerationInterceptors 2015）。
- 表达式：`public/scripts/extensions/expressions/index.js`（分类提示、UPDATE_INTERVAL）。
- 连接配置：`public/scripts/extensions/connection-manager/index.js`（CC_COMMANDS、DEFAULT_SETTINGS）。
- 作者注释：`public/scripts/authors-note.js`（metadata_keys 25-33、注入位置 41-45）。
- 产品资产：`default/content/presets/`、`default/content/backgrounds/`、`default/content/`（comfy workflow、user.css）。
