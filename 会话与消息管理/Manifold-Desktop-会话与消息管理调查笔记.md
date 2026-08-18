# Manifold Desktop 会话与消息管理调查笔记

> 调查对象：`https://github.com/gregorik/Manifold-Desktop`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：直接阅读源码并对照当前 HEAD 逐项核对符号与行号：C++ 存储层（`Manifold.Core/SessionManager.cpp`、`MainWindow.xaml.cpp` 桥 handler）与前端组件（`chat-tab.js`、`side-panel.js`、`home-tab.js`、`search-overlay.js`、`session-store.js`），并对桥消息名与函数调用点做全仓库搜索
>
> 调查范围：会话与消息的数据模型、事实源与持久化、生命周期、搜索、导入导出、外部对象绑定与保留语义；请求执行链、Provider 调用与取消进入对话请求与上下文类目，界面工作流进入 Chat UI 类目
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Manifold Desktop 的会话数据层由两套互不接通的实现组成：内存中的"聊天标签 + 组件局部消息数组"，以及磁盘上的会话文件（位于 `%LOCALAPPDATA%\Manifold\sessions\<id>.json`，由 C++ 存储层 `SessionManager` 管理）。存储层提供完整的增删改查与全文搜索，但正常聊天流程没有接入保存——本类目确认的缺口：

1. 新对话不持久化：打开标签不创建任何磁盘对象，关闭标签后内容丢失。
2. assistant 流式回复只更新流式文本与 DOM，不回写消息数组；第二次发送的上下文只有用户消息。
3. 侧栏重命名只发送单字段标题对象，后端按整份 JSON 覆盖原文件，会清除已有消息。
4. 前端 `session-store.js` 是未接入的独立模块（全仓库无 import），其写路径与正常聊天主链无关。

## 系统边界与数据主链

```text
openChatTab（app.js:138-147，标签 id 'chat-N'）
  -> chat-tab 组件局部 messages[]（内存事实源，addUserMessage chat-tab.js:119-126）
  -> 磁盘写入：仅 SAVE_SESSION 被调用时（重命名 side-panel.js:98、导入 MainWindow.xaml.cpp:668）
  -> 打开既有会话：LOAD_SESSION -> SESSION_DATA -> 装入 messages[] 渲染（chat-tab.js:101-114）
  -> 会话列表：LIST_SESSIONS -> SESSIONS_LOADED（侧栏 side-panel.js:12,18、Home home-tab.js:28）
  -> 搜索：SEARCH_SESSIONS -> SessionManager 逐文件子串扫描（SessionManager.cpp:97-131）
```

边界：`CHAT_SEND` 之后 Provider 调用、流式广播与取消属于对话请求与上下文；标签页、侧栏与搜索浮层的界面工作流属于 Chat UI；消息 Markdown 渲染属于消息渲染器（`../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md`）。

## 1. 会话、消息与分支数据模型

- **会话单位**：界面"聊天标签"与磁盘会话是两种互不相同的对象，标签不是持久化身份。
  - 聊天标签由 `openChatTab()` 生成递增 id（`frontend/app.js:139`，形如 `chat-N`）；只有从侧栏、Home 或搜索打开时，标签才持有磁盘会话的 `sessionId` 并发送 `LOAD_SESSION`（`chat-tab.js:101-114`）。
  - 磁盘会话是 `sessions/<id>.json` 文件，id 即文件名 stem（`SessionManager.cpp:24-27`）。新对话标签不产生磁盘对象，也没有生成磁盘 id 的路径（`session-store.js` 的 `generateId()` 无调用点）。
- **消息模型**：`chat-tab.js:119-126` 构造 `{ role: 'user', content: text }` 加入组件局部 `messages[]`，是普通线性数组；assistant 流式文本只更新 `streamingText` 与 DOM（`chat-tab.js:27-59`），不回写数组。
- C++ 侧 `ChatMessage` 另有 `parts`、`toolCall`、`toolResult` 扩展字段（`Manifold.Core/Providers/ProviderTypes.h:110-116`），但前端只发送 `role`/`content`，本仓库没有产生这些字段的路径。
- **分支/thread**：未找到消息树、分支、thread 或 checkpoints 相关实现；检查范围覆盖 `chat-tab.js`、`SessionManager.cpp/h`、`MainWindow.xaml.cpp` 会话 handler 与前端全部桥消息名。

## 2. 事实源、索引与持久化

- `SessionManager` 提供整文件保存、加载、删除、列表与全文搜索五种操作，全部实现集中在 `SessionManager.cpp`，方法名与行号如下：
  ```text
  SaveSession :29-36 / LoadSession :38-51 / DeleteSession :53-59 / ListSessions :61-95 / SearchSessions :97-131
  ```
- 磁盘文件的写入口只有三处，均与正常聊天无关：侧栏重命名（`side-panel.js:98`）、Home 页导入（`MainWindow.xaml.cpp:668`）、以及未被任何模块 import 的 `session-store.js`（其 `save()` 在 `:58-62`）。
- 因此内存 `messages[]` 是实际事实源；磁盘是另一套未被主链接通的实现。会话文件 schema（`session-store.js:20-27`）含 id、title、model、messages、createdAt、updatedAt 字段（无版本号），而列表读取只使用 title/model/createdAt/updatedAt（`SessionManager.cpp:77-81`），未知字段静默忽略：
  ```text
  会话文件字段：id / title / model / messages[] / createdAt / updatedAt
  列表读取字段：title / model / createdAt / updatedAt
  ```
- 角色命名不一致：未接入的会话仓库按 `"model"` 角色读取（`session-store.js:52`），聊天主链与渲染器则统一使用 `"assistant"`（写入见 `chat-tab.js:122`，后端 `MainWindow.xaml.cpp:780` 直传；渲染分支 `message-renderer.js:15-17`）。

## 3. 创建、切换、归档、删除与恢复

- **创建**：标签打开即"会话"，无持久化层面的创建动作；新对话关闭标签后内容丢失。
- **切换**：标签切换保留组件局部 `messages[]`（UI 工作流见 Chat UI 笔记）。
- **删除**：侧栏 × 按钮经确认框后发送 `DELETE_SESSION`（`side-panel.js:117-127`），后端删除对应文件（`MainWindow.xaml.cpp:536-541`）。
- **归档、置顶、清空、恢复**：未找到归档/置顶/清空空会话实现；恢复路径只有"重新打开磁盘会话"（LOAD_SESSION），内存标签无恢复。
- 应用退出只保存窗口几何到 `window-state.json`（`MainWindow.xaml.cpp:343-400`），与会话内容无关。

## 4. 编辑、重试、续写、回退与分支语义

未找到消息级编辑、删除、回退或分支的数据操作（检查范围：`chat-tab.js`、`message-renderer.js`、`MainWindow.xaml.cpp` 会话与聊天 handler）。assistant 内容不进入 `messages[]`，使续写/回退在数据层天然缺失。错误行的 Retry 按钮只删除错误提示、不重发请求（`chat-tab.js:93-95`），其界面工作流见 Chat UI 笔记。

## 5. 列表、分页、搜索与定位

- `ListSessions` 按 `updatedAt` 降序排序（`SessionManager.cpp:88-92`）；无分页参数，侧栏全量渲染，Home 页截取前 12 条（渲染位置见 `side-panel.js:64-67`、`home-tab.js:100`）。
- `SearchSessions` 对每个文件的整份 JSON dump 做不区分大小写子串搜索，无索引、无结果上限；命中片段截取匹配点前后共约 140 字符（`SessionManager.cpp:102-128`）。
- 未发现命中定位或会话内全文搜索接口；前端搜索浮层有 300ms 防抖与键盘导航（`search-overlay.js:24-58`），入口与定位工作流见 Chat UI 笔记。

## 6. 缓存、一致性、多窗口与并发写入

- 本快照正常聊天没有持久化写路径，因此不存在落盘节流、多窗口或跨端合并问题；文件写操作（重命名/导入）在 UI 线程串行处理，无锁与并发竞争点。
- 内存侧一致性风险：流式与结束广播（`CHAT_CHUNK` 等）不含会话标识（事件链细节见对话请求与上下文笔记），一个请求可能污染多个已打开标签的局部消息区。
- 多窗口不存在：本快照为单 WebView2 窗口（`MainWindow.xaml.cpp:197-236` 只创建一份 WebView），未发现第二窗口或分离窗口机制。

## 7. 迁移、导入导出与保留策略

- **JSON 导入**：文件内容解析后按其中的 `id` 字段直接保存，id 缺省时生成 `imported-<时间戳>`。保存对 schema 与 id 的路径成分均无校验，文件路径由会话目录、id 与 `.json` 后缀直接拼出（`SessionManager.cpp:24-27`），存在路径穿越风险（静态推断，未运行验证）。导入入口在 Home 页，保存逻辑见 `MainWindow.xaml.cpp:648-677`、`home-tab.js:88`。
- **JSON 导出**：后端导出 handler 存在（`MainWindow.xaml.cpp:619-646`），但全仓库搜索 `EXPORT_SESSION` 只命中 C++ 分发表与 handler 本身，未找到前端调用点，即无 UI 入口。
- **Markdown 导出**：按消息角色拼接标题和正文，不修改内容（`MainWindow.xaml.cpp:679-722`）；入口为侧栏会话项悬停显示的 MD 按钮（`side-panel.js:129-137`）。
- **保留策略**：未发现 schema 版本号、迁移代码、备份恢复或过期回收（检查范围：`SessionManager.cpp/h`、导入导出 handler、`SettingsManager` 中与本类目无关的设置 schema 除外）。

## 8. Agent、模型、知识库与附件绑定

- 请求对象携带渠道、模型、系统提示、采样温度与工具等绑定字段（`frontend/services/provider-api.js:4-13`），但本类目未发现这些绑定在会话级如何保存：没有会话文件写入主链，绑定随内存请求对象存在。会话文件 schema 里的 `model` 字段（`session-store.js:22`）只在未接入模块中使用。
- 附件、记忆或知识库在 Chat 主链上没有注入点；后端有附件文件对话框与 `FILE_ATTACHED` 广播（`MainWindow.xaml.cpp:559-617`），但前端无监听方（grep 无结果），属于未接线的半截实现。
- 工具绑定：MCP 工具在请求构造时全局注入（`MainWindow.xaml.cpp:786-789`），不落在会话或消息级（执行语义见对话请求与上下文笔记）。

## 9. 设计取舍与已确认边界

- **双实现未接通**：`session-store.js`（前端仓库）与 `SessionManager.cpp`（C++ 存储）各自实现了会话写路径，正常聊天主链均不调用。
- **重命名破坏数据**：侧栏重命名以整份 JSON 覆盖保存只有标题的对象（`side-panel.js:98` → `MainWindow.xaml.cpp:528-534`），对已有文件是破坏性操作。
- **无持久化即无恢复**：崩溃、退出后只能依赖磁盘上被导入/重命名碰巧写出的文件。
- 本类目只回答数据语义；执行层问题（全局广播、单线程、参数丢失）见对话请求与上下文笔记。

## 10. 未验证事项

- 多标签串流、路径穿越与导入恶意会话的运行结果未做动态验证（本笔记基于静态源码和调用点搜索）。
- 重命名覆盖行为未运行复现。

## 11. 关键源码索引

| 职责 | 文件 |
| --- | --- |
| Chat 局部状态与流式 UI | `frontend/components/chat-tab.js` |
| 未接入的会话前端仓库 | `frontend/services/session-store.js` |
| 会话侧栏（重命名/删除/导出） | `frontend/components/side-panel.js` |
| 会话文件存储 | `Manifold.Core/SessionManager.cpp` |
| 会话与导入导出 handler | `MainWindow.xaml.cpp:508-722` |
