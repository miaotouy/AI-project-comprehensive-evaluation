# Manifold Desktop 对话导出与分享调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-14
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：静态源码调查；读取前端侧栏导出按钮、home 导入按钮、bridge 消息分发、C++ 端 Markdown/JSON 导出与导入 handler、SessionManager 存储、chat 消息持久化链路，并用 git 历史与全仓搜索交叉验证；未运行应用
>
> 调查范围：待查清单项（Markdown 导出入口与内容口径、JSON handler 存在性与挂接、输出范围与编码、格式往返、其他交付物）；未覆盖 MCP 工具调用回环、Compare 模式与插件的内部实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Manifold Desktop（WinUI 3 C++ 后端 + WebView2 无框架前端）当前快照属于 `E1 数据交换`：只有一个已接 UI 的交付物——侧栏每个会话项悬浮显示的 "MD" 按钮，整会话导出为 `.md`；另有一个实现完整但从未挂接 UI 的 JSON 导出 handler（`EXPORT_SESSION`），以及已接 UI 的 JSON 导入（首页 "Import Session" 按钮）。全部文件写操作发生在 C++ 后端（IFileSaveDialog/IFileOpenDialog + std::ofstream），前端只发消息。

静态调查发现一个关键数据源断点：`frontend/services/session-store.js`（唯一定义会话消息 schema 并执行 SAVE_SESSION 的模块）从未被任何模块 import，chat-tab 流式渲染的消息也不会写回磁盘。当前快照下，除"导入产生的会话"外，会话 JSON 文件中不会出现消息正文，MD 导出实际只会输出标题/模型/日期头部和空消息区。此为基于调用链的静态推断，需运行验证。

## 系统边界与完整主链

```text
侧栏会话项 hover 显示 MD 按钮 (side-panel.js:128-137)
  -> bridge.send('EXPORT_MARKDOWN', {id})
  -> OnWebMessage 分发 (MainWindow.xaml.cpp:430)
  -> HandleExportMarkdown (MainWindow.xaml.cpp:679-722)
  -> SessionManager::LoadSession(id)  // %LOCALAPPDATA%\Manifold\sessions\<id>.json
  -> 拼 md 字符串 -> IFileSaveDialog -> std::ofstream 写 .md
```

JSON 导入主链：

```text
首页 "Import Session" 按钮 (home-tab.js:88)
  -> bridge.send('IMPORT_SESSION')
  -> HandleImportSession (MainWindow.xaml.cpp:648-677)
  -> IFileOpenDialog(*.json) -> nlohmann::json::parse -> SaveSession(id, data)
  -> PostMessageToWeb("SESSION_IMPORTED")  // 无前端监听
```

会话事实源为 `%LOCALAPPDATA%\Manifold\sessions\<id>.json` 单文件存储（`Manifold.Core/SessionManager.cpp:11-51`），无数据库与 schema 迁移；schema 与整库备份不属于本类目，仅记录导出/导入对它的读取。

## 1. 入口、用户目标与导出源

- **Markdown 导出**：唯一入口是侧栏会话列表项上的 "MD" 小按钮，初始 `opacity: 0`，鼠标进入该行才显示（`frontend/components/side-panel.js:128-141`）。入口按"会话项"逐个提供，无批量操作、无命令行、无快捷键。导出源为单个整会话（`LoadSession(id)`），目标为个人存档/文本交换。
- **JSON 导出**：`EXPORT_SESSION` 已注册进 bridge 分发器（`MainWindow.xaml.cpp:428`），handler 完整（`MainWindow.xaml.cpp:619-646`），但在前端全部源码中搜索 `EXPORT_SESSION` 无任何发送方；git 历史中 `-S "EXPORT_SESSION" -- frontend` 亦无匹配（代码自 6057749 初始上传起，前端从未发送过该消息）。结论：源码中确实存在但从未接 UI，非"本次未找到调用"的模糊情况——是历史与现状一致的无 UI 状态。
- **JSON 导入**：首页 Quick Actions 的 "Import Session" 按钮（`frontend/components/home-tab.js:88`），无会话选择、单文件导入。

## 2. 范围选择、内容口径与字段过滤

- 无消息级选择、无连续范围、无分支概念、无批量导出；粒度固定为整会话。会话文件本身是扁平 `messages` 数组（`frontend/services/session-store.js:34-46` 定义的 `{role, text, parts, timestamp}` 结构），不存在分支树。
- **Markdown 口径**（`MainWindow.xaml.cpp:686-698`）：`# title` + `**Provider:**/ **Model:**/ **Date:**(updatedAt)` 头部行 + `---`；每条消息按角色映射为 `### User` / `### Assistant`，其余角色（含 system）一律 `### System`，正文取 `msg.value("content", msg.value("text", ""))`，消息间以 `---` 分隔。
- **字段过滤**：只输出正文文本字段。reasoning、工具调用、附件（parts）、system prompt 均无结构化导出路径——工具调用只有以文本形式写进 content 才会出现；`parts` 字段从未被任何导出/导入逻辑读取。system prompt 属 SettingsManager 全局设置，不进入会话 JSON，因此不进入导出。
- 比较模式（Compare tab）的对话不产生会话文件、不进入导出。

## 3. 附件、资源与离线封装

- 附件链路本次未找到：`OPEN_FILE_DIALOG`/`FILE_ATTACHED` 在 C++ 侧有实现（`MainWindow.xaml.cpp:559-617`），但前端无任何发送方或接收方，属死代码。会话消息中即使存在 `parts` 字段，MD/JSON 导出也不读取。
- 交付物为纯文本文件，无图片、无资源引用，天然离线可读；无打包、无内联。

## 4. 格式、schema 与往返能力

- **Markdown**：手写拼接的普通文本，无 schema 版本、无元数据；导出后无任何导入路径（全仓未找到 Markdown 导入），不可往返。
- **JSON**：导出即会话文件原样 `data.dump(2)` 缩进输出（`MainWindow.xaml.cpp:639`），无包装、无版本字段；导入为 parse 后原样 `SaveSession`（`MainWindow.xaml.cpp:665-669`），未知字段原样保留。因此"导出文件→再导入"对同 schema 文件可往返（往返语义 = 整对象回存），但缺少版本标识，未来 schema 演化无法自动判别。导入时无 `id` 字段则生成 `imported-<unix时间>` 作为 id（`:667`），此时源会话身份不保留。
- 消息 `parts`、时间戳等字段往返时原样保留（导入是整对象存储），但没有任何读取/展示路径使用它们。

## 5. 分享稿编辑、编排与预览

不适用：导出前没有分享稿编辑表面、内容开关、预览或编排。MD 按钮点击后直接弹保存对话框写文件，无任何中间状态。

## 6. 图片、HTML、PDF 与富内容生成

本次未找到：全仓搜索 `toPng`/`toBlob`/`html2canvas`/`screenshot`/`PDF`/`Share`/`gist` 只命中前端 Compare 的 "shared messages" UI 命名与 vendor 库内部，无任何对话转图片、HTML、PDF 的捕获或生成代码（`frontend/vendor/` 仅有 marked.js 与 highlight.js，无截图库）。富内容保真不适用——导出的是源文本，聊天现场的 Markdown 渲染（marked + hljs，`frontend/components/message-renderer.js:80-105`）与导出端完全隔离。

## 7. 生成历史、版本与持久化

不适用：重新导出即重新弹出保存对话框覆盖目标文件，无版本概念、无历史记录、无比较或恢复路径；分享稿只存在于磁盘文件。

## 8. 分享载体、访问控制与撤销

不适用：唯一载体是本地文件（保存对话框选定位置），无远端分享、无链接、无快照对象、无访问控制语义。剪贴板相关代码（`COPY_TO_CLIPBOARD`，`MainWindow.xaml.cpp:724-744`）仅被终端页调用（`frontend/components/terminal-tab.js:191`），用于复制终端输出；代码块复制按钮走 `navigator.clipboard`（`frontend/components/message-renderer.js:25`）。二者均为普通复制，不属于对话导出/分享工作流，按指南排除。

## 9. 隐私、安全与内容治理

- 导出内容即会话正文原样拼接，无脱敏、无密钥扫描；API key 存 Windows Credential Manager（`Manifold.Core/CredentialManager`），不进入会话 JSON。
- Markdown 为纯文本交付物，无 HTML 脚本执行面；会话正文作为标题/正文原样写入，未做转义（`.md` 文件无执行风险，但含恶意 Markdown 的会话内容会被原样带出）。
- 文件名默认固定为 `chat-export.md`/`session-export.json`（`MainWindow.xaml.cpp:631,707`），标题不参与命名，因此不存在标题非法字符进文件名的路径；用户可在保存对话框中自行修改。
- JSON 导入对解析失败静默丢弃（`parse(content, nullptr, false)` 后 `is_discarded()` 即 return，`:665-666`），无提示、无内容校验。

## 10. 性能、失败恢复与测试

- 导出在 C++ 线程上同步拼串与写文件；无分段、无长度限制处理（长会话只受 std::string 能力约束，静态推断）。无取消、无重试、无临时文件。
- 失败路径全部静默：`LoadSession` 返回 null 时直接 return（`:683`），文件打开失败无提示。无自动化测试覆盖导出/导入（全仓未发现测试工程）。

## 11. 设计取舍与已确认边界

- 导出/导入全部由 C++ 后端执行文件对话框与 I/O，前端零文件能力，这是 WebView2 架构下的自然边界；但 UI 入口、handler 注册与数据格式之间的一致性较差：`EXPORT_SESSION` 无 UI、`OPEN_FILE_DIALOG` 无前端调用、`SESSION_IMPORTED` 无前端监听（导入后侧栏列表不会自动刷新，`side-panel.js:12-15` 只监听 SESSIONS_LOADED/SEARCH_RESULTS/SESSION_SAVED/SESSION_DELETED）。
- 当前快照的会话持久化链路未闭合（详见未验证事项第 1 条），导出能力因此处于"管线完整、上游缺源"的状态；README 与 `docs/architecture.md:60` 声称的"session export/import、markdown export"与代码存在不一致：文档描述的能力部分无 UI（export）、部分依赖未被引用的模块。
- Markdown 是"整会话扁平文本"口径，与 NextChat 的逐条选择、AIO Hub 的分支树结构化导出形成不同路线；JSON 是"事实源原样拷贝"口径，往返能力依赖同一 schema 文件，没有版本化格式。

## 12. 未验证事项

1. **消息持久化断点（静态推断）**：`session-store.js` 未被任何模块 import（当前快照与 git 历史一致），chat-tab 渲染的流式消息从不调用 SAVE_SESSION，C++ 端 CHAT_DONE 只回 token 统计（`MainWindow.xaml.cpp:824-832`）。据此推断当前快照下会话 JSON 不会包含消息正文，MD/JSON 导出对普通聊天会话只有头部；需运行应用实际聊天后检查 `%LOCALAPPDATA%\Manifold\sessions\` 与导出文件确认。
2. **编码细节（静态推断）**：`std::ofstream` 文本模式在 MSVC 下将 LF 转为 CRLF、且不写 BOM，JSON/MD 文件应为无 BOM UTF-8 + CRLF；未运行验证。
3. **导入后 UI 行为**：`SESSION_IMPORTED` 无监听者，导入完成后侧栏是否可见导入会话取决于其他刷新路径，需运行验证。
4. **保存对话框行为**：默认文件名、扩展名过滤与覆盖确认的视觉效果未运行验证。

## 13. 关键源码索引

- `frontend/components/side-panel.js`（MD 导出按钮，128-141）
- `frontend/components/home-tab.js`（Import Session 按钮，88）
- `frontend/services/session-store.js`（会话消息 schema 定义，当前为未引用模块）
- `MainWindow.xaml.cpp`（分发器 419-454；HandleExportMarkdown 679-722；HandleExportSession 619-646；HandleImportSession 648-677）
- `Manifold.Core/SessionManager.cpp`（会话文件存储与读写，11-51）
- `docs/architecture.md`（会话管理能力声称，57-62）
