# Manifold Desktop Agent / 角色配置调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-11
>
> 代码快照：`3d7448fb2e6053056da6d6c126e08f90b94cda4f`（分支：`main`）
>
> 调查方式：只读核对设置模型、PromptManager、设置面板和输入栏；未修改目标仓库
>
> 调查范围：角色对象、系统提示词、提示词库及其发送路径
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论

Manifold Desktop 没有 Agent、Persona 或角色模板对象。与角色最接近的能力只有一条全局 `systemPrompt` 和一个文本提示词库。

| 能力 | 实现 | 粒度 |
| --- | --- | --- |
| 系统提示词 | `AppSettings.systemPrompt` | 全局单值 |
| 生成温度 | `AppSettings.temperature` | 全局单值 |
| 默认 Provider / 模型 | `activeProviderId`、`model` | 全局默认值 |
| 提示词库 | 每条提示词一个 JSON 文件 | 静态文本收藏 |

没有按会话保存的角色、系统提示词、模型参数或头像，也没有角色市场、变量模板和少样本示例管理。

## 系统提示词链路

设置面板把 `systemPrompt` 写入 `%LOCALAPPDATA%\Manifold\settings.json`（`SettingsManager.h:23-51`、`SettingsManager.cpp:77-85`）。发送时，前端从全局 settings 读取该值；后端再按协议映射（`MainWindow.xaml.cpp:757-775`）：

- OpenAI / OpenAICompat：在消息首部插入 `role: system`；
- Anthropic：写入请求顶层 `system`；
- Gemini：写入 `systemInstruction`。

Compare 页也使用同一条全局 system prompt（`MainWindow.xaml.cpp:1068-1083`）。会话文件不保存发送时使用的 system prompt 或 temperature，因此重新打开历史会话无法恢复当时的配置。

## 会话持久化的实际范围

进一步的导入检查确认聊天消息本身也不落盘。前端 `frontend/services/session-store.js` 是**无引用的死模块**：其中通过 `SAVE_SESSION` 写会话 JSON 的 `addMessage`/`updateModelMessage` 从未被调用，全前端没有任何对它的 import。

实际聊天消息只存在于 `frontend/components/chat-tab.js:22` 的内存数组（读取函数 `getMessages()`，:127-129）；唯一的 `SAVE_SESSION` 调用来自重命名会话，且只写 `{title}`（`side-panel.js:98`）。

会话 JSON 的结构定义在 `session-store.js:18-32`：`{id, title, model, messages, createdAt, updatedAt}`；后端也只读 `title/model/createdAt/updatedAt`（`Manifold.Core/SessionManager.cpp:76-82`），其中 `model` 只在创建会话时写默认值、发送时不更新（`app.js:86-123`）。

因此"重新打开历史会话无法恢复当时配置"在 Manifold Desktop 上比其它项目更彻底：发送时实时从全局 settings 取 `systemPrompt`/`temperature`（`app.js:116-122`）不回写会话，消息数组仅存活于当前窗口。

本快照没有 regenerate 功能：唯一的 "Retry" 按钮只移除错误元素、不重发（`chat-tab.js:92-95`），流式回答原地累积到单个元素。提示词库也没有开场白概念和分组/组级开关。

## 提示词库

`PromptManager` 在 `%LOCALAPPDATA%\Manifold\prompts\<id>.json` 中保存前端传来的 JSON，提供列表、覆盖保存和删除（`PromptManager.cpp:23-57`）。前端约定的主要字段是 id、标题、内容、是否作为系统提示词（`isSystemPrompt`）以及创建时间。

输入栏选择提示词时有两种行为（`input-bar.js:127-143`）：

- `isSystemPrompt=true`：用该内容覆盖全局 `systemPrompt`；
- 普通提示词：把内容追加到当前输入框。

提示词不绑定 Provider、模型或会话；列表没有排序、目录和编辑流程，标题与内容也没有业务校验。

## 关键文件

| 职责 | 文件 |
| --- | --- |
| 全局设置模型和持久化 | `Manifold.Core/SettingsManager.h`、`SettingsManager.cpp` |
| 提示词文件存储 | `Manifold.Core/PromptManager.cpp` |
| 设置与提示词 handler | `MainWindow.xaml.cpp:480-494, 1138-1156` |
| 设置面板 | `frontend/components/settings-panel.js` |
| 提示词选择 | `frontend/components/input-bar.js:109-153` |
| 发送装配 | `frontend/app.js:113-122`、`MainWindow.xaml.cpp:757-775` |

## 验证边界

本笔记只描述仓库现有的角色相关能力。代理服务器也接收 `systemPrompt`，但它没有接入桌面应用的正常发送路径；相关问题见 LLM 渠道管理调查笔记。
