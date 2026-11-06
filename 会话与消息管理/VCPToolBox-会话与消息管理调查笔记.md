# VCPToolBox 会话与消息管理调查笔记

> 调查对象：`https://github.com/lioensky/VCPToolBox`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`018cd7fae1bbcf6a993bc45dcdd0914f909ca3bf`（分支：`main`）
>
> 调查方式：只读核对聊天请求与响应结算、OneRing 触发和 SQLite 写入、VCPTavern 时间记录；其他请求缓存与审计存储沿用既有源码调查
>
> 调查范围：客户端会话所有权、服务端消息持久化、OneRing 回合状态与恢复边界；未运行数据库或外部模型
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 的通用聊天接口由调用方提交完整消息数组，客户端继续持有会话导航、草稿、分支和最终显示状态。服务端同时存在可选的持久化消息路径：OneRing 被系统提示词触发后，按 Agent 保存 SQLite 消息和回合状态，用于跨前端时间线、历史去重、重试更新以及按配置补充上下文。因此“服务端所有历史都随重启丢失”与当前实现不符。

OneRing 的数据组织以 Agent 和前端来源为中心，不能直接等同于客户端的 Session/Thread 树。通用聊天会话 CRUD、列表与分支接口在已读聊天入口中未找到；插件内部消息表和重试更新则已确认存在。

## 系统边界与数据主链

```text
外部前端持有会话与历史 -> 每次请求提交 messages
  -> ChatCompletionHandler 请求内编排
  -> OneRing 在连续顶层 system 前缀发现触发器
     -> 同步或异步记录提交历史、建立 pending 回合
     -> 按配置去重、补充上下文和来源时间标记
  -> 上游模型与工具循环 -> SSE/JSON 返回客户端
  -> 上游整轮有效且 HTTP finish：写入 AI 正文、完成当前回合
     中断/错误：标记当前 pending 回合 aborted
  -> 客户端保存展示历史；OneRing SQLite 保留插件历史
```

主 OneRing 热开关默认开启，但请求仍须携带触发器；未触发时主流程返回原数组。独立的 OneRingMemo 占位符收尾仍可运行，不能把主流程未触发解释为整个插件绝无作用（`Plugin/OneRing/OneRing.js:955-1015`）。

## 1. 事实源与持久化盘点

| 存储 | 内容 | 权威性与保留边界 |
|---|---|---|
| 客户端历史（外部前端） | 会话索引、消息详情、草稿、分支 | 客户端工作台事实源，聊天接口按请求接收数组 |
| OneRing SQLite | 每 Agent 一个数据库，消息正文、角色、来源和时间；另有回合请求摘要、状态与响应消息关联 | 插件持久化历史，可用于上下文补充与重试匹配；具备独立消息 ID，非仅审计镜像 |
| `finalContextStore`（内存） | 首次上游请求前最多 5 组滑窗快照 | 调试快照，服务重启即失 |
| ChatLog（可选文件） | 请求和响应审计文件，默认关闭 | 调试用途，不承担客户端会话索引 |
| VCPTavern `access_logs.json` | 预设与会话键的最后访问时间 | 用于会话时间变量，只有时间戳 |
| `tool-call-records.sqlite3` | 工具调用记录 | 插件调用台账 |

OneRing 数据库位于插件 data 目录，以 Agent 名命名，采用 WAL。消息表与回合表分别承载正文和请求状态；启动时检查回合表列并按需补列，已有 schema 演进逻辑（`Plugin/OneRing/OneRingDB.js:10-60`）。消息插入后按配置保留最近记录；数据库层默认 100 条，非正数表示不限量，实际插件调用传入自身配置的上限（同文件 `:63-96`）。

内存态还包括在途请求注册表、响应回放缓存，以及 VCPTavern/VCPClawMail 的会话 Map。响应回放按客户端 IP 与消息 ID 去重，它与 OneRing 的磁盘历史是不同机制（`modules/chatCompletionHandler.js:56-124`）。

## 2. 回合生命周期、编辑与一致性

- **历史记录时机**：OneRing 预处理阶段即可记录请求携带的历史。Only 模式可通过事件循环异步安排记录；普通记录路径在预处理过程中执行。因此，响应失败不意味着本轮此前的所有数据库操作整体回滚（`Plugin/OneRing/OneRing.js:1047-1092,2236-2262`）。
- **回合状态**：请求回合表记录 pending、completed 或 aborted，并关联响应消息 ID 与正文哈希。完成时更新回合；中断更新仅作用于 pending，保留旧 completed 回合与旧回复（`Plugin/OneRing/OneRingDB.js:118-179`）。
- **回复提交**：统一结算器同时等待上游有效结果和 HTTP finish，随后异步提交 OneRing 回复并推进 VCPTavern 访问记录。连接关闭、abort 或失败只触发一次失败结算；客户端收到完成响应并不等于磁盘提交已同步成功（`modules/handlers/interactionCompletion.js:3-60`）。
- **编辑与重试**：OneRing 有按 Agent 和消息 ID 原地更新正文的 SQL，并可把新回复写回匹配的旧响应，再完成当前回合。这是插件级历史修订，已读链路中没有客户端式兄弟分支指针（`Plugin/OneRing/OneRingDB.js:99-115`；`Plugin/OneRing/OneRing.js:3184-3230`）。
- **会话操作**：通用聊天入口中未找到会话创建、归档、列表分页或草稿 CRUD。OneRing 的 Agent/来源粒度与客户端会话边界并不相同；本次未逐项复核插件管理 API 的搜索、导入导出与所有删除操作。

## 3. 设计取舍与恢复边界

客户端继续提交自身历史，服务端插件可另外维护长期消息时间线。两份历史需要通过来源、时间和请求摘要匹配；OneRing 可去重、更新和补充数组，但不会替客户端恢复其导航、草稿或分支 UI。

服务重启后内存快照、在途请求与回放缓存消失；OneRing SQLite、已启用的 ChatLog 和 VCPTavern 时间文件仍可存在。磁盘文件的存续与完整重放一个客户端会话具有不同含义。

## 4. 未验证事项

- 未运行真实上游或打开运行数据库，未验证并发请求、重试匹配和断电时序。
- 未逐项审查 OneRing 所有去重策略、客户端时间戳契约、管理 API 与导入导出路径。
- 通用会话操作的缺失结论限于已读聊天请求入口；不扩展为所有插件均无独立会话存储。

## 5. 关键源码索引

- [OneRing 预处理与持久化](../../VCPToolBox/Plugin/OneRing/OneRing.js)：触发入口 955-1015；记录模式 1047-1092；异步记录 2236 起；回复写入 3077-3230。
- [OneRing 数据库](../../VCPToolBox/Plugin/OneRing/OneRingDB.js)：10-60 初始化与补列；63-115 消息保留与更新；118-179 回合状态。
- [交互结算器](../../VCPToolBox/modules/handlers/interactionCompletion.js)：3-60 完成与失败的结算条件。
- [聊天请求处理器](../../VCPToolBox/modules/chatCompletionHandler.js)：首次上游前冻结 OneRing 元数据，并构造交互结算器。
