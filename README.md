# AI 项目调查笔记

这里整理对 AI 客户端、Agent 工作台、聊天前端、服务端与相关运行时的实现调查。笔记以可见源码、项目文档、提交记录和有限的运行验证为依据，重点回答项目如何实现、能力边界在哪里，以及同类项目之间有哪些可比较的设计差异。

这些内容用于实现学习、技术选型和架构参考，不是代码审查、整改清单或项目质量排名。每篇笔记对应的代码快照、调查范围和未验证事项，以文首元数据与正文说明为准。

## 从哪里开始

按项目了解全貌时，从[已调查能力汇总](已调查能力汇总/)进入。每个项目一篇汇总，集中说明产品形态、已经确认的主要能力、证据边界，并链接到各主题的详细调查。

按能力比较项目时，进入下方对应主题，先阅读目录中的“横向对比”。横向文档只比较各单项目笔记共同覆盖的维度，未调查、无法确认和确认不支持是三种不同状态。

追查某项结论时，打开相应的单项目调查笔记。正文会在关键结论附近给出源码路径、符号名或行号；目录中的“调查指南”定义该主题的检查范围和证据口径。

若只想快速建立 Chat 全貌，可先看 [Chat](Chat/)；该目录提供端到端概览，并把会话数据、请求执行、交互界面、消息渲染和导出分享串联起来。

## 已收录项目与笔记矩阵


<details>
<summary><b>已收录项目清单（共 22 个）</b></summary>

- [AIO-Hub](已调查能力汇总/AIO-Hub-已调查能力汇总.md) — https://github.com/miaotouy/aio-hub
- [AstrBot](已调查能力汇总/AstrBot-已调查能力汇总.md) — https://github.com/AstrBotDevs/AstrBot
- [Chatbox](已调查能力汇总/Chatbox-已调查能力汇总.md) — https://github.com/chatboxai/chatbox
- [Cherry-Studio](已调查能力汇总/Cherry-Studio-已调查能力汇总.md) — https://github.com/CherryHQ/cherry-studio
- [DeepChat](已调查能力汇总/DeepChat-已调查能力汇总.md) — https://github.com/ThinkInAIXYZ/deepchat
- [DeepSeek-Harness](已调查能力汇总/DeepSeek-Harness-已调查能力汇总.md) — https://github.com/deepseek-ai/deepseek-harness
- [Dify](已调查能力汇总/Dify-已调查能力汇总.md) — https://github.com/langgenius/dify
- [Hermes-Agent](已调查能力汇总/Hermes-Agent-已调查能力汇总.md) — https://github.com/NousResearch/hermes-agent
- [Jan](已调查能力汇总/Jan-已调查能力汇总.md) — https://github.com/janhq/jan
- [LobeHub](已调查能力汇总/LobeHub-已调查能力汇总.md) — https://github.com/lobehub/lobehub
- [Manifold-Desktop](已调查能力汇总/Manifold-Desktop-已调查能力汇总.md) — https://github.com/gregorik/Manifold-Desktop
- [NextChat](已调查能力汇总/NextChat-已调查能力汇总.md) — https://github.com/ChatGPTNextWeb/NextChat
- [Open-WebUI](已调查能力汇总/Open-WebUI-已调查能力汇总.md) — https://github.com/open-webui/open-webui
- [OpenClaw](仓库分布/OpenClaw-仓库分布调查笔记.md) — https://github.com/openclaw/openclaw
- [OpenCode](已调查能力汇总/OpenCode-已调查能力汇总.md) — https://github.com/anomalyco/opencode
- [OpenOcta](仓库分布/OpenOcta-仓库分布调查笔记.md) — https://github.com/openocta/openocta
- [Pi](已调查能力汇总/Pi-已调查能力汇总.md) — https://github.com/earendil-works/pi
- [Risuai](已调查能力汇总/Risuai-已调查能力汇总.md) — https://github.com/kwaroran/Risuai
- [SillyTavern](已调查能力汇总/SillyTavern-已调查能力汇总.md) — https://github.com/SillyTavern/SillyTavern
- [VCPChat](已调查能力汇总/VCPChat-已调查能力汇总.md) — https://github.com/lioensky/VCPChat
- [VCPMobile](已调查能力汇总/VCPMobile-已调查能力汇总.md) — https://github.com/MRiecy/VCPMobile
- [VCPToolBox](已调查能力汇总/VCPToolBox-已调查能力汇总.md) — https://github.com/lioensky/VCPToolBox

</details>

<details>
<summary><b>调查主题笔记矩阵（点击 ✅ 可直达对应调查笔记）</b></summary>

标记说明：`✅` 已调查且存在该方向能力；`N/A` 已调查但该方向不适用；`—` 尚未调查。

| 项目 | 能力汇总 | 仓库分布 | 产品基因与结构 | 消息与会话管理 | 请求与上下文 | Chat UI 体验 | 渲染器 | 导出与分享 | 渠道管理 | Agent 角色 | Agent 工具 | 外部协作体 | RAG与编排 | 生成运行时 | 媒体创作 | UI基础设施 | 独特功能 |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| AIO-Hub | [✅](已调查能力汇总/AIO-Hub-已调查能力汇总.md) | [✅](仓库分布/AIO-Hub-仓库分布调查笔记.md) | [✅](产品结构与设计基因/AIO-Hub-产品结构与设计基因调查笔记.md) | [✅](会话与消息管理/AIO-Hub-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/AIO-Hub-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/AIO-Hub-ChatUI调查笔记.md) | [✅](消息渲染器/AIO-Hub-消息渲染器调查笔记.md) | [✅](对话导出与分享/AIO-Hub-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/AIO-Hub-LLM渠道管理调查笔记.md) | [✅](Agent角色/AIO-Hub-Agent角色配置调查笔记.md) | [✅](Agent工具/AIO-Hub-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/AIO-Hub-外部执行体与应用协作调查笔记.md) | [✅](检索增强与认知编排/AIO-Hub-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/AIO-Hub-生成式输出与运行时调查笔记.md) | [✅](媒体创作/AIO-Hub-媒体创作调查笔记.md) | [✅](应用界面基础设施/AIO-Hub-应用界面基础设施调查笔记.md) | [✅](独特功能/AIO-Hub-独特功能调查笔记.md) |
| AstrBot | [✅](已调查能力汇总/AstrBot-已调查能力汇总.md) | [✅](仓库分布/AstrBot-仓库分布调查笔记.md) | — | [✅](会话与消息管理/AstrBot-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/AstrBot-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/AstrBot-ChatUI调查笔记.md) | [✅](消息渲染器/AstrBot-消息渲染器调查笔记.md) | [✅](对话导出与分享/AstrBot-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/AstrBot-LLM渠道管理调查笔记.md) | [✅](Agent角色/AstrBot-Agent角色配置调查笔记.md) | [✅](Agent工具/AstrBot-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/AstrBot-外部执行体与应用协作调查笔记.md) | [✅](检索增强与认知编排/AstrBot-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/AstrBot-生成式输出与运行时调查笔记.md) | N/A | [✅](应用界面基础设施/AstrBot-应用界面基础设施调查笔记.md) | [✅](独特功能/AstrBot-独特功能调查笔记.md) |
| Chatbox | [✅](已调查能力汇总/Chatbox-已调查能力汇总.md) | [✅](仓库分布/Chatbox-仓库分布调查笔记.md) | — | [✅](会话与消息管理/Chatbox-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/Chatbox-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/Chatbox-ChatUI调查笔记.md) | [✅](消息渲染器/Chatbox-消息渲染调查笔记.md) | [✅](对话导出与分享/Chatbox-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/Chatbox-LLM渠道管理调查笔记.md) | [✅](Agent角色/Chatbox-Agent角色配置调查笔记.md) | [✅](Agent工具/Chatbox-Agent工具调查笔记.md) | N/A | [✅](检索增强与认知编排/Chatbox-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/Chatbox-生成式输出与运行时调查笔记.md) | [✅](媒体创作/Chatbox-媒体创作调查笔记.md) | [✅](应用界面基础设施/Chatbox-应用界面基础设施调查笔记.md) | [✅](独特功能/Chatbox-独特功能调查笔记.md) |
| Cherry-Studio | [✅](已调查能力汇总/Cherry-Studio-已调查能力汇总.md) | [✅](仓库分布/Cherry-Studio-仓库分布调查笔记.md) | — | [✅](会话与消息管理/Cherry-Studio-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/Cherry-Studio-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/Cherry-Studio-ChatUI调查笔记.md) | [✅](消息渲染器/Cherry-Studio-消息渲染调查笔记.md) | [✅](对话导出与分享/Cherry-Studio-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/Cherry-Studio-LLM渠道管理调查笔记.md) | [✅](Agent角色/Cherry-Studio-Agent角色配置调查笔记.md) | [✅](Agent工具/Cherry-Studio-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/Cherry-Studio-外部执行体与应用协作调查笔记.md) | [✅](检索增强与认知编排/Cherry-Studio-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/Cherry-Studio-生成式输出与运行时调查笔记.md) | [✅](媒体创作/Cherry-Studio-媒体创作调查笔记.md) | [✅](应用界面基础设施/Cherry-Studio-应用界面基础设施调查笔记.md) | [✅](独特功能/Cherry-Studio-独特功能调查笔记.md) |
| DeepChat | [✅](已调查能力汇总/DeepChat-已调查能力汇总.md) | [✅](仓库分布/DeepChat-仓库分布调查笔记.md) | — | [✅](会话与消息管理/DeepChat-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/DeepChat-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/DeepChat-ChatUI调查笔记.md) | [✅](消息渲染器/DeepChat-消息渲染器调查笔记.md) | [✅](对话导出与分享/DeepChat-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/DeepChat-LLM渠道管理调查笔记.md) | [✅](Agent角色/DeepChat-Agent角色配置调查笔记.md) | [✅](Agent工具/DeepChat-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/DeepChat-外部执行体与应用协作调查笔记.md) | [✅](检索增强与认知编排/DeepChat-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/DeepChat-生成式输出与运行时调查笔记.md) | N/A | [✅](应用界面基础设施/DeepChat-应用界面基础设施调查笔记.md) | [✅](独特功能/DeepChat-独特功能调查笔记.md) |
| DeepSeek-Harness | [✅](已调查能力汇总/DeepSeek-Harness-已调查能力汇总.md) | [✅](仓库分布/DeepSeek-Harness-仓库分布调查笔记.md) | — | [✅](会话与消息管理/DeepSeek-Harness-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/DeepSeek-Harness-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/DeepSeek-Harness-ChatUI调查笔记.md) | [✅](消息渲染器/DeepSeek-Harness-消息渲染器调查笔记.md) | [✅](对话导出与分享/DeepSeek-Harness-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/DeepSeek-Harness-LLM渠道管理调查笔记.md) | [✅](Agent角色/DeepSeek-Harness-Agent角色调查笔记.md) | [✅](Agent工具/DeepSeek-Harness-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/DeepSeek-Harness-外部执行体与应用协作调查笔记.md) | N/A | [✅](生成式输出与运行时/DeepSeek-Harness-生成式输出与运行时调查笔记.md) | N/A | [✅](应用界面基础设施/DeepSeek-Harness-应用界面基础设施调查笔记.md) | [✅](独特功能/DeepSeek-Harness-独特功能调查笔记.md) |
| Dify | [✅](已调查能力汇总/Dify-已调查能力汇总.md) | [✅](仓库分布/Dify-仓库分布调查笔记.md) | [✅](产品结构与设计基因/Dify-产品结构与设计基因调查笔记.md) | [✅](会话与消息管理/Dify-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/Dify-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/Dify-ChatUI调查笔记.md) | [✅](消息渲染器/Dify-消息渲染器调查笔记.md) | [✅](对话导出与分享/Dify-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/Dify-LLM渠道管理调查笔记.md) | [✅](Agent角色/Dify-Agent角色配置调查笔记.md) | [✅](Agent工具/Dify-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/Dify-外部执行体与应用协作调查笔记.md) | [✅](检索增强与认知编排/Dify-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/Dify-生成式输出与运行时调查笔记.md) | N/A | [✅](应用界面基础设施/Dify-应用界面基础设施调查笔记.md) | [✅](独特功能/Dify-独特功能调查笔记.md) |
| Hermes-Agent | [✅](已调查能力汇总/Hermes-Agent-已调查能力汇总.md) | [✅](仓库分布/Hermes-Agent-仓库分布调查笔记.md) | — | [✅](会话与消息管理/Hermes-Agent-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/Hermes-Agent-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/Hermes-Agent-ChatUI调查笔记.md) | [✅](消息渲染器/Hermes-Agent-消息渲染器调查笔记.md) | [✅](对话导出与分享/Hermes-Agent-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/Hermes-Agent-LLM渠道管理调查笔记.md) | [✅](Agent角色/Hermes-Agent-Agent角色配置调查笔记.md) | [✅](Agent工具/Hermes-Agent-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/Hermes-Agent-外部执行体与应用协作调查笔记.md) | [✅](检索增强与认知编排/Hermes-Agent-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/Hermes-Agent-生成式输出与运行时调查笔记.md) | N/A | [✅](应用界面基础设施/Hermes-Agent-应用界面基础设施调查笔记.md) | [✅](独特功能/Hermes-Agent-独特功能调查笔记.md) |
| Jan | [✅](已调查能力汇总/Jan-已调查能力汇总.md) | [✅](仓库分布/Jan-仓库分布调查笔记.md) | — | [✅](会话与消息管理/Jan-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/Jan-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/Jan-ChatUI调查笔记.md) | [✅](消息渲染器/Jan-消息渲染器调查笔记.md) | N/A | [✅](LLM渠道管理/Jan-LLM渠道管理调查笔记.md) | [✅](Agent角色/Jan-Agent角色配置调查笔记.md) | [✅](Agent工具/Jan-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/Jan-外部执行体与应用协作调查笔记.md) | [✅](检索增强与认知编排/Jan-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/Jan-生成式输出与运行时调查笔记.md) | N/A | [✅](应用界面基础设施/Jan-应用界面基础设施调查笔记.md) | [✅](独特功能/Jan-独特功能调查笔记.md) |
| LobeHub | [✅](已调查能力汇总/LobeHub-已调查能力汇总.md) | [✅](仓库分布/LobeHub-仓库分布调查笔记.md) | — | [✅](会话与消息管理/LobeHub-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/LobeHub-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/LobeHub-ChatUI调查笔记.md) | [✅](消息渲染器/LobeHub-消息渲染调查笔记.md) | [✅](对话导出与分享/LobeHub-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/LobeHub-LLM渠道管理调查笔记.md) | [✅](Agent角色/LobeHub-Agent角色配置调查笔记.md) | [✅](Agent工具/LobeHub-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/LobeHub-外部执行体与应用协作调查笔记.md) | [✅](检索增强与认知编排/LobeHub-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/LobeHub-生成式输出与运行时调查笔记.md) | [✅](媒体创作/LobeHub-媒体创作调查笔记.md) | [✅](应用界面基础设施/LobeHub-应用界面基础设施调查笔记.md) | [✅](独特功能/LobeHub-独特功能调查笔记.md) |
| Manifold-Desktop | [✅](已调查能力汇总/Manifold-Desktop-已调查能力汇总.md) | [✅](仓库分布/Manifold-Desktop-仓库分布调查笔记.md) | — | [✅](会话与消息管理/Manifold-Desktop-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/Manifold-Desktop-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/Manifold-Desktop-ChatUI调查笔记.md) | [✅](消息渲染器/Manifold-Desktop-消息渲染调查笔记.md) | [✅](对话导出与分享/Manifold-Desktop-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/Manifold-Desktop-LLM渠道管理调查笔记.md) | [✅](Agent角色/Manifold-Desktop-Agent角色配置调查笔记.md) | [✅](Agent工具/Manifold-Desktop-Agent工具调查笔记.md) | N/A | N/A | [✅](生成式输出与运行时/Manifold-Desktop-生成式输出与运行时调查笔记.md) | N/A | [✅](应用界面基础设施/Manifold-Desktop-应用界面基础设施调查笔记.md) | [✅](独特功能/Manifold-Desktop-独特功能与项目状态调查笔记.md) |
| NextChat | [✅](已调查能力汇总/NextChat-已调查能力汇总.md) | [✅](仓库分布/NextChat-仓库分布调查笔记.md) | — | [✅](会话与消息管理/NextChat-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/NextChat-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/NextChat-ChatUI调查笔记.md) | [✅](消息渲染器/NextChat-消息渲染器调查笔记.md) | [✅](对话导出与分享/NextChat-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/NextChat-LLM渠道管理调查笔记.md) | [✅](Agent角色/NextChat-Agent角色配置调查笔记.md) | [✅](Agent工具/NextChat-Agent工具调查笔记.md) | N/A | N/A | [✅](生成式输出与运行时/NextChat-生成式输出与运行时调查笔记.md) | [✅](媒体创作/NextChat-媒体创作调查笔记.md) | [✅](应用界面基础设施/NextChat-应用界面基础设施调查笔记.md) | [✅](独特功能/NextChat-独特功能调查笔记.md) |
| Open-WebUI | [✅](已调查能力汇总/Open-WebUI-已调查能力汇总.md) | [✅](仓库分布/Open-WebUI-仓库分布调查笔记.md) | — | [✅](会话与消息管理/Open-WebUI-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/Open-WebUI-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/Open-WebUI-ChatUI调查笔记.md) | [✅](消息渲染器/Open-WebUI-消息渲染器调查笔记.md) | [✅](对话导出与分享/Open-WebUI-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/Open-WebUI-LLM渠道管理调查笔记.md) | [✅](Agent角色/Open-WebUI-Agent角色配置调查笔记.md) | [✅](Agent工具/Open-WebUI-Agent工具调查笔记.md) | — | [✅](检索增强与认知编排/Open-WebUI-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/Open-WebUI-生成式输出与运行时调查笔记.md) | N/A | [✅](应用界面基础设施/Open-WebUI-应用界面基础设施调查笔记.md) | [✅](独特功能/Open-WebUI-独特功能调查笔记.md) |
| OpenClaw | — | [✅](仓库分布/OpenClaw-仓库分布调查笔记.md) | — | — | — | — | — | — | — | — | — | — | — | — | — | — | — |
| OpenCode | [✅](已调查能力汇总/OpenCode-已调查能力汇总.md) | [✅](仓库分布/OpenCode-仓库分布调查笔记.md) | — | [✅](会话与消息管理/OpenCode-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/OpenCode-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/OpenCode-ChatUI调查笔记.md) | [✅](消息渲染器/OpenCode-消息渲染调查笔记.md) | [✅](对话导出与分享/OpenCode-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/OpenCode-LLM渠道管理调查笔记.md) | [✅](Agent角色/OpenCode-Agent角色配置调查笔记.md) | [✅](Agent工具/OpenCode-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/OpenCode-外部执行体与应用协作调查笔记.md) | N/A | [✅](生成式输出与运行时/OpenCode-生成式输出与运行时调查笔记.md) | N/A | [✅](应用界面基础设施/OpenCode-应用界面基础设施调查笔记.md) | [✅](独特功能/OpenCode-独特功能调查笔记.md) |
| OpenOcta | — | [✅](仓库分布/OpenOcta-仓库分布调查笔记.md) | — | — | — | — | — | — | — | — | — | — | — | — | — | — | — |
| Pi | [✅](已调查能力汇总/Pi-已调查能力汇总.md) | [✅](仓库分布/Pi-仓库分布调查笔记.md) | — | [✅](会话与消息管理/Pi-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/Pi-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/Pi-ChatUI调查笔记.md) | [✅](消息渲染器/Pi-消息渲染器调查笔记.md) | [✅](对话导出与分享/Pi-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/Pi-LLM渠道管理调查笔记.md) | [✅](Agent角色/Pi-Agent角色配置调查笔记.md) | [✅](Agent工具/Pi-Agent工具调查笔记.md) | N/A | N/A | [✅](生成式输出与运行时/Pi-生成式输出与运行时调查笔记.md) | N/A | [✅](应用界面基础设施/Pi-应用界面基础设施调查笔记.md) | [✅](独特功能/Pi-独特功能调查笔记.md) |
| Risuai | [✅](已调查能力汇总/Risuai-已调查能力汇总.md) | [✅](仓库分布/Risuai-仓库分布调查笔记.md) | — | [✅](会话与消息管理/Risuai-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/Risuai-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/Risuai-ChatUI调查笔记.md) | [✅](消息渲染器/Risuai-消息渲染调查笔记.md) | [✅](对话导出与分享/Risuai-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/Risuai-LLM渠道管理调查笔记.md) | [✅](Agent角色/Risuai-Agent角色配置调查笔记.md) | [✅](Agent工具/Risuai-Agent工具调查笔记.md) | N/A | [✅](检索增强与认知编排/Risuai-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/Risuai-生成式输出与运行时调查笔记.md) | [✅](媒体创作/Risuai-媒体创作调查笔记.md) | [✅](应用界面基础设施/Risuai-应用界面基础设施调查笔记.md) | [✅](独特功能/Risuai-独特功能调查笔记.md) |
| SillyTavern | [✅](已调查能力汇总/SillyTavern-已调查能力汇总.md) | [✅](仓库分布/SillyTavern-仓库分布调查笔记.md) | — | [✅](会话与消息管理/SillyTavern-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/SillyTavern-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/SillyTavern-ChatUI调查笔记.md) | [✅](消息渲染器/SillyTavern-消息渲染调查笔记.md) | [✅](对话导出与分享/SillyTavern-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/SillyTavern-LLM渠道管理调查笔记.md) | [✅](Agent角色/SillyTavern-Agent角色配置调查笔记.md) | [✅](Agent工具/SillyTavern-Agent工具调查笔记.md) | N/A | [✅](检索增强与认知编排/SillyTavern-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/SillyTavern-生成式输出与运行时调查笔记.md) | [✅](媒体创作/SillyTavern-媒体创作调查笔记.md) | [✅](应用界面基础设施/SillyTavern-应用界面基础设施调查笔记.md) | [✅](独特功能/SillyTavern-独特功能调查笔记.md) |
| VCPChat | [✅](已调查能力汇总/VCPChat-已调查能力汇总.md) | [✅](仓库分布/VCPChat-仓库分布调查笔记.md) | — | [✅](会话与消息管理/VCPChat-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/VCPChat-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/VCPChat-ChatUI调查笔记.md) | [✅](消息渲染器/VCPChat-消息渲染器调查笔记.md) | [✅](对话导出与分享/VCPChat-对话导出与分享调查笔记.md) | [✅](LLM渠道管理/VCPChat-LLM渠道管理调查笔记.md) | [✅](Agent角色/VCPChat-Agent角色配置调查笔记.md) | [✅](Agent工具/VCPChat-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/VCPChat-外部执行体与应用协作调查笔记.md) | [✅](检索增强与认知编排/VCPChat-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/VCPChat-生成式输出与运行时调查笔记.md) | [✅](媒体创作/VCPChat-媒体创作调查笔记.md) | [✅](应用界面基础设施/VCPChat-应用界面基础设施调查笔记.md) | [✅](独特功能/VCPChat-独特功能调查笔记.md) |
| VCPMobile | [✅](已调查能力汇总/VCPMobile-已调查能力汇总.md) | [✅](仓库分布/VCPMobile-仓库分布调查笔记.md) | [✅](产品结构与设计基因/VCPMobile-产品结构与设计基因调查笔记.md) | [✅](会话与消息管理/VCPMobile-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/VCPMobile-对话请求与上下文调查笔记.md) | [✅](Chat%20UI/VCPMobile-ChatUI调查笔记.md) | [✅](消息渲染器/VCPMobile-消息渲染器调查笔记.md) | N/A | [✅](LLM渠道管理/VCPMobile-LLM渠道管理调查笔记.md) | [✅](Agent角色/VCPMobile-Agent角色配置调查笔记.md) | [✅](Agent工具/VCPMobile-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/VCPMobile-外部执行体与应用协作调查笔记.md) | [✅](检索增强与认知编排/VCPMobile-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/VCPMobile-生成式输出与运行时调查笔记.md) | N/A | [✅](应用界面基础设施/VCPMobile-应用界面基础设施调查笔记.md) | [✅](独特功能/VCPMobile-独特功能调查笔记.md) |
| VCPToolBox | [✅](已调查能力汇总/VCPToolBox-已调查能力汇总.md) | [✅](仓库分布/VCPToolBox-仓库分布调查笔记.md) | [✅](产品结构与设计基因/VCPToolBox-产品结构与设计基因调查笔记.md) | [✅](会话与消息管理/VCPToolBox-会话与消息管理调查笔记.md) | [✅](对话请求与上下文/VCPToolBox-对话请求与上下文调查笔记.md) | N/A | N/A | N/A | [✅](LLM渠道管理/VCPToolBox-LLM渠道管理调查笔记.md) | [✅](Agent角色/VCPToolBox-Agent角色配置调查笔记.md) | [✅](Agent工具/VCPToolBox-Agent工具调查笔记.md) | [✅](外部执行体与应用协作/VCPToolBox-外部执行体与应用协作调查笔记.md) | [✅](检索增强与认知编排/VCPToolBox-检索增强与认知编排调查笔记.md) | [✅](生成式输出与运行时/VCPToolBox-生成式输出与运行时调查笔记.md) | [✅](媒体创作/VCPToolBox-媒体创作调查笔记.md) | [✅](应用界面基础设施/VCPToolBox-应用界面基础设施调查笔记.md) | [✅](独特功能/VCPToolBox-独特功能调查笔记.md) |

</details>



## 调查目录

| 方向 | 主要回答的问题 |
| --- | --- |
| [已调查能力汇总](已调查能力汇总/) | 某个项目已经调查过什么，目前可以确认到什么程度 |
| [Chat](Chat/) | 项目的聊天能力由哪些子系统组成，完整链路和专项入口在哪里 |
| [仓库分布](仓库分布/) | 代码、测试、文档、平台适配和配套资产如何分布 |
| [产品结构与设计基因](产品结构与设计基因/) | 产品边界如何形成，能力如何组织和扩展，哪些机制长期影响整体设计 |
| [会话与消息管理](会话与消息管理/) | 会话、消息和分支如何建模、持久化、查询与恢复 |
| [对话请求与上下文](对话请求与上下文/) | 一次输入如何完成上下文拼装、模型调用、流式消费、取消和最终回写 |
| [Chat UI](<Chat UI/>) | 用户如何在聊天工作台中发现、触发、观察和恢复各项操作 |
| [消息渲染器](消息渲染器/) | 消息状态和流式事件如何变成 Markdown、工具卡、附件等可见内容 |
| [对话导出与分享](对话导出与分享/) | 对话如何被抽取、加工并交付为文件、图片、剪贴板内容或分享链接 |
| [LLM 渠道管理](LLM渠道管理/) | Provider、Endpoint、模型目录、凭据、协议适配和运行时路由如何工作 |
| [Agent 角色](Agent角色/) | 角色配置如何存储、绑定会话并进入最终上下文 |
| [Agent 工具](Agent工具/) | 工具如何注册、注入、校验、审批、执行并把结果回注模型循环 |
| [主动 Agent 与后台任务](主动Agent与后台任务/) | 哪些运行可脱离当前用户回合触发，以及它们如何调度、执行、交付、取消和恢复 |
| [外部执行体与应用协作](外部执行体与应用协作/) | 产品如何发现、启动和观察外部 Agent，或连接具有独立身份的业务应用 |
| [检索增强与认知编排](检索增强与认知编排/) | 知识、记忆和思维资产如何摄取、检索、重排并进入上下文 |
| [生成式输出与运行时](生成式输出与运行时/) | 模型输出如何获得独立对象身份，成为可交互、可编辑或可执行的内容 |
| [媒体创作](媒体创作/) | 图片、视频、音频等媒体如何生成、管理、编排与复用 |
| [应用界面基础设施](应用界面基础设施/) | 跨页面复用的布局、主题、反馈、适配和交互基础设施如何约束产品体验 |
| [独特功能](独特功能/) | 哪些跨越通用类目或少数项目独有的完整工作流形成了产品辨识度 |

## 根目录专题

- [AI 客户端项目评分](AI客户端项目评分.md)：给出可复算的分项、场景权重、证据覆盖率和风险标签；不把单一总分解释为绝对质量排名。
- [AI 客户端特色功能贡献统计](AI客户端特色功能贡献统计.md)：从特色能力角度汇总不同项目提供的实现样本。
- [候选分类方向调查](候选分类方向调查.md)：评估自然聚类是否具备独立成类条件，并记录与现有主题的边界和后续顺序。
- [极致 RP 向 AI 客户端构想](极致RP向AI客户端构想.md)：基于现有调查形成的产品构想，与源码调查笔记分开阅读。

## 文件约定

- `调查指南.md` 定义一个类目的适用范围、必查问题和证据标准。新建或实质更新单项目笔记前，应先阅读所在目录的指南。
- `<项目>-<类目>调查笔记.md` 记录单个项目在一个主题下的实现、主链、边界和源码依据。
- `<类目>横向对比.md` 基于已有单项目笔记做统一维度比较，不替代详细调查。
- `<项目>-已调查能力汇总.md` 从各类目来源中整理项目画像，不在汇总阶段新增源码结论。
- `待查清单.md` 保存尚未完成或证据不足的调查对象，不代表能力缺失。

## 如何理解证据

笔记尽量明确区分三类内容：当前代码快照中已复查的实现事实、基于实现结构形成的推断、尚未运行或尚未覆盖的事项。实现事实来自可追踪的入口、状态与调用关系；未运行验证不表示这些实现路径不可信，而是视觉效果、平台行为、性能、安全性和生产可靠性需要在目标环境中分别观察。

“本次未找到”只说明当前检查范围和搜索结果；只有证据足以覆盖项目边界时，才会写成确认不支持。文档、注释与当前可执行路径不一致时，两者会同时记录，并以调查快照中的实现为行为依据。

## 维护笔记

1. 先阅读目标目录的 `调查指南.md`，确定类目边界和必查问题。
2. 固定项目、分支与完整 commit SHA，说明调查方式、覆盖范围和明确排除项。
3. 至少走通一条从入口、状态、执行到输出或持久化的完整主链，并就近标注关键源码依据。
4. 新增单项目笔记后，检查同类横向对比的对象列表；实质更新来源笔记后，检查对应的已调查能力汇总。
5. 交付前复核事实、推断和未验证事项是否分开，正文是否在解释机制而不是堆叠源码符号。

完整的写作、元数据、证据密度和验收要求见 [AGENTS.md](AGENTS.md)。
