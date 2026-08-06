# Manifold Desktop Agent / 角色配置调查笔记

> 调查对象：`E:\works\git\Manifold-Desktop`
>
> 调查更新日期：2026-08-06
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

设置面板把 `systemPrompt` 写入 `%LOCALAPPDATA%\Manifold\settings.json`（`SettingsManager.h:23-51`、`SettingsManager.cpp:77-85`）。发送时，前端从全局 settings 读取该值；后端再映射到各协议（`frontend/app.js:113-122`、`MainWindow.xaml.cpp:757-775`）：

- OpenAI / OpenAICompat：在消息首部插入 `role: system`；
- Anthropic：写入请求顶层 `system`；
- Gemini：写入 `systemInstruction`。

Compare 页也使用同一条全局 system prompt（`MainWindow.xaml.cpp:1068-1083`）。会话文件不保存发送时使用的 system prompt 或 temperature，因此重新打开历史会话无法恢复当时的配置。

## 提示词库

`PromptManager` 在 `%LOCALAPPDATA%\Manifold\prompts\<id>.json` 中保存前端传来的 JSON，提供列表、覆盖保存和删除（`PromptManager.cpp:23-57`）。前端约定的主要字段是 `id/title/content/isSystemPrompt/createdAt`。

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
