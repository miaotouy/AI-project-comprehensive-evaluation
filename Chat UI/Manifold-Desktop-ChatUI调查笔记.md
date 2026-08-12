# Manifold Desktop Chat UI 调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：直接阅读前端组件源码（`app.js`、`chat-tab.js`、`input-bar.js`、`side-panel.js`、`search-overlay.js`、`tab-bar.js`、`settings-panel.js` 等）核对控件、状态与事件绑定；视觉效果、焦点顺序、键盘可用性与响应式行为属于静态代码无法确认的项，未运行验证
>
> 调查范围：标签工作台结构、会话导航、Composer 与草稿、发送前配置、流式反馈与控制、消息操作、多标签并存、UI 状态所有权与关键路径键盘可用性；会话数据语义与请求执行分别进入会话与消息管理、对话请求与上下文类目；通用组件（Toast/Modal/主题/动画）仅记录与聊天主链的交点
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Manifold Desktop 的 Chat 界面是一套较薄的"标签页内存状态"实现：应用提供 home/chat/compare/terminal 多标签（`index.html:18-26` 布局），聊天内容与流式状态全部放在 `chat-tab` 组件局部（`messages[]`、`streamingText`），没有全局 UI store。与聊天主链直接相关的界面事实：

- 新对话不持久化，关闭标签后内容丢失，界面没有对应的保存或恢复路径（数据语义见会话与消息管理笔记）。
- 流式期间每个 chunk 无条件滚到底部，用户无法稳定停留在历史位置（`chat-tab.js:58`）。
- 错误行 Retry 按钮只删除错误提示，不重发请求（`chat-tab.js:93-95`）。
- 一个请求可能更新多个已打开标签，界面没有"哪条在运行"的标记（执行语义见对话请求与上下文笔记）。
- 输入栏是全局单例，标签切换会重建 DOM，未发送的草稿随之丢失（静态推断，见第 3 节）。

## 工作台边界与用户主链

```text
打开应用（Home 页 / 多标签工作台）
  -> openChatTab 新建标签 / 侧栏或 Home 选择会话（LOAD_SESSION 恢复磁盘会话）
  -> input-bar 输入（Enter 发送）-> CHAT_SEND
  -> 流式反馈（chunk 追加、滚底、cost badge）
  -> 错误提示（Retry 无效）
  -> Cancel 停止 / 关闭标签（流式中有确认）
```

边界：消息内容与 Markdown 渲染、流式 DOM 生命周期、HTML 安全边界属于消息渲染器（`../消息渲染器/Manifold-Desktop-消息渲染调查笔记.md`）；会话文件如何保存与加载属于会话与消息管理；`CHAT_SEND` 之后的执行链属于对话请求与上下文。

## 1. 页面结构、导航与多窗口

- 布局为固定四区：`#tab-bar`、`#main-area`（内含 `#side-panel` 与 `#tab-content`）、`#input-bar`、`#toast-container`（`index.html:18-26`）。
- `tab-bar.js` 渲染标签条：`role=tablist`/`aria-selected`、每个标签的关闭按钮、末尾 "+" 新建按钮（`:48-81`）。标签类型由 `app.js` 决定：Home 常驻不可关（`:33-44`），chat/terminal/compare 由 `openChatTab/openTerminalTab/openCompareTab` 创建（`:138-174`）。
- 本快照为单 WebView2 窗口（`MainWindow.xaml.cpp:197-236`），未发现多窗口或分离窗口机制（检查范围：前端与 MainWindow 源码，无第二窗口创建点）。
- 侧栏折叠：`side-panel.js:23-25` 导出 `toggle()` 但全仓库无调用点，未发现折叠入口。

## 2. 会话列表、搜索与现场恢复

- **侧栏**（`side-panel.js`）：搜索输入（`:43-47`）、New Chat/Terminal 按钮（`:54-55`）、会话列表（`:74-147`）。列表项支持双击标题重命名（`:84-105`，发送 `SAVE_SESSION {title}`，数据语义见会话与消息管理笔记）、悬停显示的删除（×，带确认，`:117-127`）与 MD 导出（`:129-137`）。无置顶、归档、分组或拖放。
- **Home 页**：Recent Sessions 网格最多 12 条（`home-tab.js:100`）、Import Session 按钮（`:88`）。
- **搜索浮层**（`search-overlay.js`，Ctrl+F 打开）：300ms 防抖（`:24-32`）、↑↓/Enter/Esc 键盘导航（`:34-58`）、结果点击后关闭浮层并 `openChatTab(item.sessionId)` 定位（`:76-79`）。底层是后端逐文件子串扫描（会话与消息管理笔记第 5 节），无会话内搜索。
- **现场恢复**：磁盘会话可从侧栏/Home/搜索重新打开并渲染（`chat-tab.js:101-114`）；内存标签关闭后无恢复路径。

## 3. Composer、草稿、附件与快捷输入

- **输入区**：单一全局 `input-bar`（`app.js:26` 创建一次），textarea 自动增高（`input-bar.js:79,186-191`）、Enter 发送 / Shift+Enter 换行（`:73-78`）、字符数/4 的 `~tokens` 估算（`:84-87`）。Home 与 terminal 标签下输入栏不渲染（`:41-42`）。
- **草稿**：不持久化；发送后清空（`:173`）。标签切换时 `setTabType()` 无条件调用 `render()` 重建 DOM（`:32-42`），未发送的文本随重建丢失——此为静态推断（render 清空 innerHTML 后无草稿恢复逻辑）。
- **提示词库**：输入栏 📋 按钮经 `LIST_PROMPTS` 弹出下拉（`input-bar.js:109-154`）；标记为 system 的提示词替换全局系统提示，其余插入文本（`:133-143`）。
- **附件**：无附件 UI 入口（后端附件链路未接线，见对话请求与上下文笔记第 9 节）。

## 4. Agent、模型、工具与发送前配置

- 发送前配置全部为全局设置，无会话级或分支级作用域：
  - Provider/模型下拉在输入栏内（`input-bar.js:52-63`），Provider 切换触发 `LIST_MODELS`（`:55-57`），模型按设置值预选（`:233-235`）；
  - 温度滑杆（0–2）、系统提示、流式开关在设置面板 General 节（`settings-panel.js:138-152`，绑定 `:167-197`）；
- 两处已确认的"配置不生效"：设置面板的 `streamResponses` 开关在发送路径无读取点；前端发送的 `temperature` 值后端不消费（均见对话请求与上下文笔记第 4 节，源码确认）。

## 5. 发送、排队、流式反馈与停止

- **发送**：发送按钮（`input-bar.js:92-97`）→ `doSend` → `app.js:86-123` 加入 `messages[]` 并发送 `CHAT_SEND`；发送后按钮禁用、Cancel 显示（`setStreaming`，`input-bar.js:22-30`）。
- **流式反馈**：chunk 追加 `streamingText` 并重设 `innerHTML`（`chat-tab.js:42-45`）；首个文本 chunk 的 innerHTML 赋值会移除流式指示器（`:37-44`）；完成时挂 cost badge（`:61-85`）。
- **滚动**：每个 chunk 无条件滚到底（`chat-tab.js:58`），无"停留在历史位置"的开关。
- **排队与停止**：无界面级排队指示；停止入口是输入栏 Cancel（`input-bar.js:100-106`）→ `providerApi.cancelChat()`（`app.js:126-129`），停止语义是后端单线程 stop+join（对话请求与上下文笔记第 7 节）。无每标签停止按钮。
- **关闭确认**：× 按钮关闭标签时若 `appStreaming` 为真则弹确认（`app.js:66-69`）；该标志是全局的，任一标签流式时关闭任意标签都会询问（源码确认）。Ctrl+W 直接关闭、不经过此确认（`:186-196`）——鼠标路径与键盘路径行为不一致。

## 6. 消息操作、分支与版本导航

- 唯一的消息级操作是错误行的 Retry 按钮，且只删除错误提示、不重发（`chat-tab.js:87-98`）。
- 未发现消息编辑、删除、复制、重生成、续写入口（检查范围：`chat-tab.js`、`message-renderer.js`——其中只有代码块的 Copy 按钮，`:20-31`，属于渲染器）；无分支或版本导航。

## 7. 多会话、多模型、群聊与后台生成

- 多标签共享同一条全局生成线程；`CHAT_CHUNK`/`CHAT_DONE` 广播没有会话标识（对话请求与上下文笔记第 5、8 节），界面没有运行标签标记，也无法从界面判断哪条仍在运行。
- compare 标签是独立的并排比较表面：共享用户消息 + 每列独立流式（`compare-tab.js:43-81`），发送走 `COMPARE_CHAT`（`app.js:91-105`），默认槽位硬编码（`app.js:163-166`）。
- 无群聊、子 Agent 或后台生成通知。

## 8. Chat UI 状态所有权与同步

- `messages[]`、`streamingText` 均为 `chat-tab` 组件局部状态（`chat-tab.js:19-22`），标签切换时随组件保留；标签登记在 `app.js` 的 `tabPanes` Map（`:18`）。
- 输入栏状态（provider/model 选择、streaming 标志）是模块级单例（`input-bar.js:4-12`），不随标签区分；草稿不保存。
- 应用级 `appStreaming` 布尔（`app.js:21`）只用于关闭确认与输入栏状态复位（`:132-135`）。
- 用量统计存 localStorage（`pricing.js:40-61`）；设置经 `settings-store.js` + 后端 `SAVE_SETTINGS`。
- 无跨窗口同步问题（单窗口）。

## 9. 键盘、焦点、响应式与关键路径可用性

静态代码可确认的键盘路径：

- 发送/换行：Enter / Shift+Enter（`input-bar.js:73-78`）。
- 全局快捷键：Ctrl+N 新聊天、Ctrl+T 新终端、Ctrl+W 关标签、Ctrl+, 设置、Ctrl+K 聚焦侧栏搜索、Ctrl+F 搜索浮层、Ctrl+1–9 切换标签（`app.js:177-218`）。
- 搜索浮层：↑↓/Enter/Esc（`search-overlay.js:34-58`）。
- 可访问名称：标签条 `role=tablist` + `aria-selected`（`tab-bar.js:51-57`）、textarea 与发送/取消按钮的 `aria-label`（`input-bar.js:71,95,103`）。

静态代码可确认的焦点缺口：chat-tab 实例没有 `focus` 方法，`app.js:54` 的 `entry.instance.focus?.()` 对聊天标签是空操作（对比 terminal 标签有实现，`terminal-tab.js:258`）——切换回聊天标签不会自动聚焦输入框（静态推断）。键盘可用性、焦点顺序、响应式与视觉反馈均未运行验证。

## 10. 设计取舍与已确认边界

- **内存状态 + 无持久化**：界面状态与文件存储两套系统未接通（会话与消息管理笔记第 2 节）。
- **全局广播无隔离**：多标签同听一个事件流，无运行标记（对话请求与上下文笔记第 5 节）。
- **阅读位置不可停留**：流式滚动强制到底。
- **错误恢复路径无效**：Retry 不重发。
- **输入栏重建**：全局单例 + 切换重建，草稿丢失。
- **键盘/鼠标路径不一致**：Ctrl+W 关闭绕过流式确认。
- 通用组件（Toast/Modal/主题/动画）不在本笔记范围；Toast 只用于全局脚本错误提示（`app.js:224-227`），与聊天主链无工作流交点。

## 11. 未验证事项

- 视觉效果、焦点顺序、键盘可用性与响应式行为需运行验证。
- 多标签串流下"一个请求更新多个标签"的可见行为未运行验证。
- 草稿随标签切换丢失、关闭确认触发范围等静态推断未做运行确认。

## 12. 关键源码索引

| 职责 | 文件 |
| --- | --- |
| 标签和发送编排 | `frontend/app.js` |
| Chat 局部状态与流式 UI | `frontend/components/chat-tab.js` |
| 输入区与发送前配置 | `frontend/components/input-bar.js` |
| 会话侧栏 | `frontend/components/side-panel.js` |
| 搜索浮层 | `frontend/components/search-overlay.js` |
| 标签条 | `frontend/components/tab-bar.js` |
