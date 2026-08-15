# SillyTavern Agent / 角色配置调查笔记

> 调查对象：`E:\works\git\SillyTavern`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：只读核对 TavernCardValidator、character-card-parser、characters 端点；未修改被调查仓库源码
>
> 调查范围：角色卡格式（V1/V2/V3）、字段语义、World Info、扩展机制与导入方式
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 1. 结论摘要

SillyTavern 的"角色"是**角色卡（Character Card）**，一个标准的 JSON 数据结构，可嵌入 PNG 元数据或以独立 JSON 文件保存。角色卡遵循社区制定的 Tavern Card 规范，目前主流版本为 **V2**（`spec_version: '2.0'`），V3 规范也已支持。

角色卡的关键特点：

1. 提示词分成多个语义字段（描述、人格、场景、系统提示、历史后指令等），不是单一文本；
2. `system_prompt` 可覆盖应用层的全局系统提示；`post_history_instructions` 注入到历史消息末尾；
3. `character_book`（内嵌世界书）让角色可携带按关键词触发的背景知识；
4. `extensions` 提供开放扩展点，第三方工具可在此存储额外数据（如 depth_prompt、talkativeness）；
5. 不存在模型参数字段——温度、最大 tokens 等参数完全由 SillyTavern 全局或 Preset 系统控制，不写入角色卡。

## 2. 角色卡格式

### 2.1 版本演进

| 版本 | 标识 | 状态 |
| --- | --- | --- |
| V1 | 无 `spec` 字段 | 向后兼容，字段较少，用于旧角色卡导入 |
| V2 | `spec: 'chara_card_v2'`, `spec_version: '2.0'` | 主流标准，必选字段列表严格 |
| V3 | `spec: 'chara_card_v3'`, `spec_version: '3.x'` | 新增规范，`TavernCardValidator` 已支持 |

V1 使用旧式字段名（如 `char_name`、`char_persona`），导入时由 `character-card-parser.js` 自动映射到 V2 字段，完整映射见 2.4 表。

### 2.2 V2 角色卡（data 层）必填字段

```
spec:          'chara_card_v2'
spec_version:  '2.0'
data:
  name:                      string    // 角色名称
  description:               string    // 角色描述/人格简介（传统称 persona）
  personality:               string    // 个性特征摘要（短文本，注入提示词特定位置）
  scenario:                  string    // 当前场景设定
  first_mes:                 string    // 默认开场白（首条 AI 消息）
  mes_example:               string    // 示例对话（<START> ... 格式）
  creator_notes:             string    // 给用户的说明，不注入模型
  system_prompt:             string    // 覆盖全局系统提示（空字符串 = 不覆盖）
  post_history_instructions: string    // 注入在历史末尾（"作者备注"替代品）
  alternate_greetings:       string[]  // 备选开场白列表
  tags:                      string[]  // 标签，用于分类和搜索
  creator:                   string    // 作者名
  character_version:         string    // 版本字符串
  extensions:                object    // 任意扩展数据（见下）
  character_book?:           CharacterBook  // 内嵌世界书（可选）
```

### 2.3 提示词注入位置

SillyTavern 的提示词构建器将各字段注入到不同位置，可在 Advanced Formatting 中调整顺序：

| 字段 | 默认注入位置 |
| --- | --- |
| `system_prompt` | 最开头（替换全局 system prompt） |
| `description` | Character 模块位置（中段） |
| `personality` | 人格模块位置 |
| `scenario` | 场景模块位置 |
| `mes_example` | 示例对话块，用 `<START>` 分隔 |
| `post_history_instructions` | 历史末尾（可替代 Author's Note） |

### 2.4 V1 → V2 字段映射

| V1 字段 | V2 字段 |
| --- | --- |
| `char_name` | `data.name` |
| `char_persona` | `data.description` |
| `char_greeting` | `data.first_mes` |
| `example_dialogue` | `data.mes_example` |
| `world_scenario` | `data.scenario` |

## 3. Extensions 扩展字段

`data.extensions` 是一个任意对象，SillyTavern 自身和第三方工具可以在此存储额外数据。**已知字段：**

| 字段路径 | 类型 | 作用 |
| --- | --- | --- |
| `extensions.talkativeness` | `number` (0–1) | 主动发言频率 |
| `extensions.fav` | `boolean` | 是否标星（收藏） |
| `extensions.world` | `string` | 关联的外部世界书文件名（不内嵌） |
| `extensions.depth_prompt.prompt` | `string` | 以深度方式注入的额外提示词 |
| `extensions.depth_prompt.depth` | `number` | 距历史末尾的深度（消息条数） |
| `extensions.depth_prompt.role` | `string` | 注入的角色（`user`/`assistant`/`system`） |

`extensions` 不限于上述字段，任意工具都可以添加自定义键，深合并时不会覆盖已有键。

## 4. 内嵌世界书（Character Book）

`data.character_book` 与 SillyTavern 的 World Info 系统共享相同结构：

```
character_book:
  name?:       string
  description?: string
  entries:     Entry[]    // 世界书条目数组
  extensions:  object
```

每个 Entry 包含：
- `keys`：触发关键词数组；
- `secondary_keys`：次级触发词（需同时匹配）；
- `content`：注入内容；
- `constant`：是否始终激活（不依赖关键词）；
- `selective`：是否需要次级词才触发；
- `order`：注入顺序；
- `position`：注入位置（`before_char`/`after_char`/`author_note`/`at_depth`）；
- `depth`：`at_depth` 时距历史末尾的深度；
- `case_sensitive`：关键词大小写是否敏感；
- `enabled`：是否启用；
- `extensions`：条目级扩展数据，可包含 `match_persona_description` 等匹配类开关。

世界书支持递归扫描（一个条目的 content 包含另一个条目的触发词，自动激活）。

## 5. 别名与快速回复

角色卡本身不包含 Regex Scripts 或 Quick Reply 规则，这些属于 SillyTavern 的 Persona/Extension 层。但导入 AIO Hub 时，`regex_scripts` 可以映射为 AIO Hub 的 `regexConfig` 字段（参见 AIO Hub 调查笔记的 § 9 导入说明）。

## 6. 文件格式与存储

| 格式 | 说明 |
| --- | --- |
| PNG | 角色图片 + tEXt chunk 嵌入 JSON 元数据（字段名 `chara`，base64 编码）；可带图像 |
| JSON | 纯 JSON 文件，不含图片；用于无图标角色或批量共享 |
| CharX | 新格式（ZIP 包），由 `CharXParser` 处理，可携带多媒体资产 |
| BYAF | 另一种社区扩展格式，由 `ByafParser` 处理 |

角色卡文件存储在用户数据目录的 `characters/` 子目录下，文件名为 `{sanitized_name}.png` 或 `{sanitized_name}.json`。内存缓存（`MemoryLimitedMap`，默认 100MB）和磁盘缓存（`DiskCache`）双层加速读取。

## 7. 运行时 Persona（非角色卡）

SillyTavern 还有一个 **User Persona** 系统，独立于角色卡：
- 定义用户角色的名称和描述，注入到提示词中作为对话对象信息；
- 同一角色卡可与不同 User Persona 配合使用；
- 不存储在角色卡里，由应用层全局或单会话设置。

## 8. 开场白生命周期与历史快照语义

开场白（`first_mes` + `alternate_greetings`）采用"创建时实例化 + tainted 固化"的语义：

1. **创建会话**：`getChatResult`（`script.js:7625-7648`）在 chat 为空时调 `getFirstMessage()`（`script.js:7651-7683`）。`first_mes` 作为首条消息，`alternate_greetings` 全部转成 swipes 及其 `swipe_info`（send_date 相同、gen_* 为 void 0）。这些内容经宏展开后由 `saveChatConditional` 落盘。
2. **修改角色卡后的重建**：`shouldRegenerateMessage`（`script.js:9844-9861`）要求 `!chat_metadata.tainted` 且 chat 为空或仅一条首条，满足时用 `getFirstMessage()` 整体替换 chat。`tainted` 在 Generate（`script.js:4288`）等多处被置 true，因此**首次生成后开场白即固化**，不再跟随角色卡后续修改。此后每次生成只对 `chat[0].mes` 做 `substituteParams` 宏展开（`script.js:4430-4432`）。
3. **快照落盘**：首条消息对象（mes + swipes + swipe_info）经 `saveChat`（`script.js:7336`）→ `/api/chats/save`（`src/endpoints/chats.js:470`）写入 JSONL。没有“重新选择 greeting”UI：备选以 swipe 呈现，overswipe 的 `PRISTINE_GREETING` 只是循环回 swipe 0（`script.js:9163-9181`），不会重新拉取角色卡。

## 9. 每次生成的配置读取与请求参数快照

- 每次发送、续写、swipe 或 regenerate 都会重新读取角色卡当前配置：`Generate`（`script.js:4231`）每次调 `getCharacterCardFields()` 读取 live `characters[this_chid]`，`depth_prompt` 同样取自当前卡（`script.js:4401-4411, 4424-4426`）。
- 每条消息或每个 swipe 只保存 `extra.api` 与 `extra.model`（由 `getGeneratingApi`/`getGeneratingModel` 写入，`script.js:6980/6991`）。
- `swipe_info` 结构为 `{send_date, gen_started, gen_finished, extra: structuredClone}`（`script.js:6734-6749`）。
- **未找到**温度/采样参数/预设名快照（全仓 grep `extra.temp|extra.preset|generation_parameters` 零命中）——与 AIO Hub 的 `metadata.requestParameters` 相比，这里只快照 api/model。
- **swipe 与 regenerate 的关系**：两者都复用发送链，但保存语义相反：
  - swipe 越过末尾（`OVERSWIPE_BEHAVIOR.REGENERATE`，`script.js:10350-10357`）走 `Generate('swipe')`，`saveReply`（`script.js:6612-6637`）在 swipes 数组**追加**新版，旧回复保留；
  - Ctrl+Enter 触发 `Generate('regenerate')`（`script.js:11578`），先把最后一条助手消息从 chat 删除（`script.js:4340-4353`），`saveReply` 走非 swipe 分支（`script.js:6682-6725`）**新建消息、旧回复被丢弃**（覆盖语义）；
  - swipe 时提示装配先 `coreChat.pop()` 剔除被重生成的消息（`script.js:4438-4440`）。

## 10. 模型与 Preset 系统

角色卡不携带模型参数。SillyTavern 的推理参数由以下层次管理：

1. **Preset**（预设）：temperature、top_p 等采样参数，每个 Preset 以 JSON 文件存储，与角色卡分离；
2. **Context Template**：控制 `[INST]`、`<s>` 等 prompt 格式的模板，根据模型类型选择；
3. **Author's Note / Depth**：在 Advanced Formatting 中独立配置，可覆盖 `post_history_instructions`；
4. **System Prompt Override**：角色卡的 `data.system_prompt` 若非空，会覆盖 Preset 中的系统提示词。

因此，角色卡只有一处能影响推理参数：通过非空 `system_prompt` 改变发给模型的系统内容，但不能设置 temperature 或 token 上限。

## 11. 内置角色示例

SillyTavern 自身不内置角色卡（源码中无预置 `characters/` 目录）；内容来自社区共享站点（如 [chub.ai](https://chub.ai)、[character.ai](https://character.ai) 导出、Discord 频道等）。

SillyTavern 提供内置 Default Character 作为测试（文件名 `default_character`），其字段均为示例值：
- `name`: `Seraphina`
- `description`: 简短描述助手形象
- `first_mes`: 标准欢迎语
- `system_prompt`/`post_history_instructions`：空字符串（不覆盖）

## 12. 导入与兼容性

| 来源 | 方式 |
| --- | --- |
| PNG 角色卡 | 直接拖入或通过 Import 按钮 |
| JSON 角色卡 | 同上 |
| CharX 包 | `CharXParser` 处理，资产持久化到 `characters/{name}/` |
| BYAF | `ByafParser` 处理 |
| AIO Hub YAML/JSON 预设 | 需手工转换（`presetMessages` → `data.description/mes_example`，世界书 → `character_book`） |
| V1 旧格式 | 自动映射，通过 `character-card-parser.js` 升级到 V2 |

## 13. 主要源码依据

- `SillyTavern/src/validator/TavernCardValidator.js`：V1/V2/V3 验证规则和必填字段列表。
- `SillyTavern/src/character-card-parser.js`：V1 → V2 映射、V2 字段写入、`depth_prompt`/`alternate_greetings` 处理。
- `SillyTavern/src/endpoints/characters.js`：角色卡读写 API、PNG tEXt 嵌入/解析、V2 扩展字段合并。
- `SillyTavern/src/endpoints/worldinfo.js`：世界书条目结构参考。
- `SillyTavern/src/charx.js`：CharX 格式解析与资产持久化。
- `SillyTavern/src/byaf.js`：BYAF 格式解析。

## 14. 调查边界

本篇关注角色卡配置格式，不涉及 Extension API（扩展工具调用、`/tools-register`）、Regex Scripts 处理机制和 Preset 推理参数体系的具体结构；工具调用安全边界参见 [SillyTavern-Agent工具调查笔记.md](../Agent工具/SillyTavern-Agent工具调查笔记.md)。
