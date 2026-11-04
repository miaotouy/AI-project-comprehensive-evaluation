# OpenCode 对话导出与分享调查笔记

> 调查对象：`https://github.com/anomalyco/opencode`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`7864a941527ad54e415d5875c98e038c5fc25697`（分支：`dev`）
>
> 调查方式：静态调查会话转移服务、导出/导入端点、CLI 与 App 入口、消息模型与脱敏实现；未运行导出导入
>
> 调查范围：会话 JSON 导出、导入、脱敏规则、附件与媒体的处理、往返语义；远端分享链接、PR 续作等历史能力按当前快照核对后说明
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

当前快照只保留一条主链：**结构化 JSON 导出 + 导入重建**。导出对象是一个 JSON 文档，包含会话信息与消息数组，消息使用当前的消息模型（用户、助手、系统、合成、技能、shell、压缩等类型及其内容项），不经过渲染投影。导入不是逐表覆盖，而是把文档当作事件源重放：先发布会话创建事件，再按序写入消息并推进序列号；如果目标实例已存在同 id 会话则直接报冲突。

分享与 PR 续作两条旧链已不在当前代码中：CLI 命令表里没有 share/unshare 与 pr 命令，服务端没有分享模块，会话表只保留遗留的分享地址列。导出文件也不含 Artifact 与工具输出落盘的内容。

能力分型：属于 `E1 数据交换`（JSON 导出、可往返导入）；`E4 链接分享` 在当前快照未找到。

## 系统边界与完整主链

```text
导出
  CLI: opencode session export [--sanitize] [sessionID]
  App: 会话命令 -> GET /api/experimental/session/:sessionID/export
  -> SessionTransfer.export：取会话信息 + 全部消息（升序）
  -> 过滤未收口消息（助手未完成、shell/压缩仍在运行）
  -> 可选脱敏
  -> 输出 {info, messages}

导入
  CLI: opencode session import <file|url> [--directory]
  -> 客户端解析 JSON，POST /api/experimental/session/import
  -> SessionTransfer.import：
       校验会话 id 冲突、校验父会话存在
       解析目标项目与位置
       发布会话创建事件，再写入消息行并保留序列
       内联媒体按需切分进 blob 表
  -> 返回导入后的会话信息
```

## 1. 入口与用户目标

| 入口 | 位置 | 目标 |
|---|---|---|
| `opencode session export` | `packages/cli/src/commands/handlers/session/export.ts` | 导出单个会话为 JSON；无会话 id 且为交互终端时列表选择 |
| `opencode session import` | `packages/cli/src/commands/handlers/session/import.ts` | 从文件或 URL 导入会话 |
| App 导出 | `packages/app/src/session/commands/export.ts` | 拉取导出数据并下载为文件 |
| HTTP 端点 | `/api/experimental/session/:sessionID/export`、`/api/experimental/session/import` | 服务端实现 |

导出范围是整会话：CLI 一次取全部消息并按时间升序；App 端按游标分页拉取（每页 200）后拼成同一形状。没有单条消息、范围、选区或分支子集的选择。

## 2. 内容口径与字段

- **会话信息**：id、父会话、项目与位置、标题、Agent、模型、权限、开销与时间信息等（`packages/schema/src/session.ts` 的会话信息结构）。
- **消息**：使用当前消息模型的完整结构（`packages/schema/src/session-message.ts`），包括用户消息的文本、文件、Agent、技能引用，助手消息的内容项（文本、推理、工具）与终止原因，shell 消息的命令与输出，压缩消息的摘要与状态。
- **过滤规则**：导出与导入都只处理"已收口"消息——助手消息需有完成时间，shell 与压缩消息需处于非运行态（`transfer.ts:202`）；进行中的内容不会进入档案。
- **不含对象**：Artifact、工具输出的落盘文件、待办（属于会话事件而非消息）、blob 实体的原始字节（媒体由消息内联数据承载）。

## 3. 脱敏规则

`--sanitize` 由 CLI 透传到服务端，脱敏在服务端执行（`packages/core/src/session/transfer.ts:217` 起）。策略是整体替换而不是逐字段掩码：

- 非空字符串替换为 `[redacted:kind:id]` 形式的占位串，空串保留；非空对象替换为 `{redacted: kind:id}` 占位对象。
- **会话层**：标题、元数据、工作目录（目录处理成占位目录）、回退记录中的文件路径与补丁。
- **用户消息**：文本、文件的数据与来源（来源重置为内联）、文件名与描述、提及文本、Agent 名、技能名与技能文本。
- **助手消息**：文本、推理正文与原生块、工具输入、工具结果内容（文本与文件引用）、工具元数据。
- **其他类型**：合成消息文本与描述、系统消息文本、技能消息文本、shell 命令与输出、压缩摘要与原生块。
- **未覆盖**：消息 id、会话 id、时间、用量与开销、模型与 Agent 标识、权限规则集、工具名与状态、附件之外的资源引用形式。

脱敏是尽力而为：占位串保留了 `kind` 与 id，仍能看出结构与部分标识；导入端不做反向还原。

## 4. 附件、媒体与离线封装

- 消息中的媒体有两种承载：内联数据与 blob 引用。导入时会拆分内联媒体，仅当目标实例启用 blob 存储时把内联数据写入 blob 表并记录引用；文档携带的 blob 引用不会被信任，避免导入方凭引用读取原本不持有的内容（`transfer.ts:96-110` 的注释与切分逻辑）。
- 导出不下载、不打包外部文件；工具引用到的文件与 Artifact 不在文档内。
- 因此档案可离线打开的范围限于 JSON 本身，图片等媒体能否显示取决于导入实例是否启用了 blob 存储。

## 5. 格式、往返与冲突

- 格式是无版本头的 JSON，字段结构由 `packages/schema/src/session-transfer.ts` 定义：`info` 与 `messages`。schema 随消息模型演进。
- 导入保留原会话 id、消息 id 与消息内容；会话父引用保留，但父会话不会随文档导入。
- 冲突策略是拒绝：目标实例已存在同 id 会话时报导入冲突；父会话不存在时报找不到。导入不是合并或覆盖。
- 位置重写：会话被放到当前实例解析出的项目与目录下，slug 重新生成，标题、Agent、模型、权限、开销与时间信息来自文档。
- 消息写入保留原顺序，并预留序列位置，后续事件从导入后的序列继续。
- 旧版本导出的文档由服务端校验层兼容，校验发生在导入时而非导出时。

## 6. 分享与 PR 续作的当前状态

- **分享**：CLI 命令表中没有 share/unshare，服务端没有分享服务模块；会话表保留 `share_url` 列用于读取旧数据，当前代码路径不写入该列。
- **PR 续作**：CLI 命令表中没有 `pr` 命令，导入端也不再解析分享链接；从 PR 描述自动续作的链路本次未找到。
- 与分享相关的历史行为（实时同步、撤销、分享配置）在当前快照不可用，因此本笔记不再描述其语义。

## 7. 性能、失败与恢复

- 导出为一次性读取整会话，大会话会占用较多内存与带宽；App 端分页拉取降低单次响应体大小。
- 导入在一个事务内完成消息写入与序列预留，失败不会留下半截会话。
- CLI 非交互环境下导出必须显式给会话 id，否则直接报错，避免脚本挂起。
- 本次未找到导出/导入的端到端测试覆盖说明；边界行为需运行验证。

## 8. 设计取舍与已确认边界

- **只做数据交换**：导出物是结构化原文，没有 Markdown/HTML/PDF/截图等交付物，也没有分享稿编辑器或预览工作台。
- **服务端脱敏**：脱敏集中在转移服务，CLI 只是开关；Web 端导出未暴露脱敏开关。
- **导入按事件重放**：没有逐表覆盖路径，因此导入后的事件序列与投影保持一致，代价是必须跳过进行中消息。
- **拒绝重复 id**：跨实例迁移需要先删除或换 id，没有自动重命名策略。
- **分享与 PR 续作属历史能力**：当前快照未实现，不能按旧笔记推断仍可用。

## 9. 未验证事项

1. CLI 导出交互选择、输出流与导入完整往返（含媒体、旧版本文档）。
2. 大会话导出的内存与耗时表现。
3. App 端下载导出在桌面与浏览器下的保存行为。
4. 导入到不同项目结构与子目录时的位置重写效果。

## 10. 关键源码索引

- `packages/core/src/session/transfer.ts`：导出、脱敏、导入与媒体切分
- `packages/schema/src/session-transfer.ts`：档案结构
- `packages/schema/src/session-message.ts`：消息模型
- `packages/protocol/src/groups/session.ts`：导出/导入端点
- `packages/server/src/handlers/session.ts`：端点实现
- `packages/cli/src/commands/handlers/session/{export,import}.ts`：CLI 入口
- `packages/app/src/session/commands/export.ts`：App 导出
