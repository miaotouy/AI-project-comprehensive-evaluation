# AstrBot 独特功能调查笔记

> 调查对象：`E:\works\git\AstrBot`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`a9bb8a64ca69657e6262e3ca06541ecaf3a6d1ca`（分支：`master`）
>
> 调查方式：只读源码与仓库文档交叉梳理；结合 Agent 工具、Chat 等既有笔记做去重；未修改 AstrBot 仓库
>
> 调查范围：第三批 P2 补查——主动式 Agent、Agent Sandbox、1000+ 插件生态、多 IM 消息投影、语音能力的独立能力卡判定；重点确认哪些能力需要独立能力卡而非补入口
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

README 四个招牌能力（`README.md:45-55`：Proactive Agent、Agentic Capabilities、1000+ Plugins、Agent Sandbox）中，本次确认需要独立能力卡的有两项：Agent Sandbox 与主动式 Agent；语音能力形成完整管道，列为辅助贡献；多 IM 消息投影与 1000+ 插件生态归并到已有类目（现有笔记已覆盖产品主链，计数与生态规模属外部事实）。

| 候选 | 状态 | 依据 |
|---|---|---|
| Agent Sandbox | `主链确认` | `astrbot/core/computer/` 完整子系统（booter 族 + 会话级实例 + 技能同步 + 文件进出），见能力卡 1 |
| 主动式 Agent | `主链确认` | 主动回复概率 + cron 工具 + "autonomous proactive agent" 提示词 + 后台唤醒链，见能力卡 2 |
| 语音能力 | `主链确认` | 14 个 TTS/STT provider + 流水线 TTS 阶段 + 预处理器 STT，见能力卡 3 |
| 多 IM 消息投影 | `归并已有类目` | 平台适配器族 + UMO 归一在 Chat/LLM 渠道笔记已主链确认，见"已归并"节 |
| 1000+ 插件生态 | `归并已有类目` | star 插件框架（命令/工具/定时任务/WebUI 扩展）已被 Agent 工具笔记覆盖；"1000+" 是插件市场外部计数，见"已归并"节 |

## 介绍声明与候选盘点

README 声明（`README.md:45-55`）：Agent Sandbox 提供"isolated, safe execution of code, shell calls, and session-level resource reuse"（链接 `docs/use/astrbot-agent-sandbox.html`）；Web ChatUI 内置 agent sandbox 与 web search，并有 1000+ 社区插件。中文使用文档包含 proactive-agent 专门页面，配置文件中的提示指向 `docs.astrbot.app/use/proactive-agent.html`（`astrbot/core/config/default.py:3651`）。

## 已确认的独特能力

### 能力卡 1：Agent Sandbox（隔离执行运行时）

**用户目标**：让 Agent 在隔离环境中执行代码/shell/浏览器操作而不直接触碰宿主机，且同一会话内复用运行实例（README 明示 "session-level resource reuse"）。

**入口与触发者**：触发者是模型工具调用。配置键 `provider_settings.computer_use_runtime` 决定本机、沙箱或关闭（默认 `none`），另一个配置键选择 booter，默认值为 `shipyard_neo`，可选值为 `cua`、`shipyard`、`boxlite`、`bay`；配置定义见 `core/config/default.py:173-191`。

**事实对象**：会话级 booter 实例按会话 ID 复用；实例表的类型与选择逻辑见 `astrbot/core/computer/computer_client.py:21`、`:551`。

**完整主链**（静态走通）：

```text
模型调用 computer 工具（shell / python / fs / cua / browser）
  -> _get_runtime_computer_tools 按 runtime 组装（astr_agent_tool_exec.py:189-245，
     sandbox 8 个 + cua 3 个 + local 7 个；shipyard_neo 另 14 个技能流水线工具）
  -> get_booter -> booter 族：
      LocalBooter（core/computer/booters/local.py，本机受限执行）
      CuaBooter（cua.py，容器桌面 + GUI 截图/点击/键盘）
      ShipyardBooter / ShipyardNeoBooter / BoxliteBooter / BayContainerManager（远端容器）
  -> olayer 协议面（shell/python/filesystem/gui/browser Protocol）屏蔽 booter 差异
  -> 文件进出：astrbot_upload_file / astrbot_download_file（fs.py:805/871，
     本地 <-> 沙箱互传）
  -> 技能同步：_apply_skills_to_sandbox / _scan_sandbox_skills / sync_skills_to_active_sandboxes
     （computer_client.py:456-669，SKILL.md 同步进沙箱并扫描回读；
     收集侧只同步已激活插件的 skill，未激活插件 skill 被跳过，
     _collect_sync_skill_dirs computer_client.py:101-134）
  -> 生命周期：CUA idle timeout 自动回收（computer_client.py:35-87）、
     shipyard TTL / max_sessions（config sandbox 段）
  -> 权限：computer_use_require_admin（默认 True）
```

**持续性**：会话级 booter 在会话存续期间复用；空闲回收/TTL 后下一次调用重新拉起。文件上传/下载的结果落本机临时目录。

**独特性判断**：DeepChat 采用主进程子进程执行与权限审批的本机执行面；AstrBot 把容器或桌面环境作为一等执行域，并支持会话级复用与技能双向同步。shipyard_neo 还提供从执行历史到技能发布或回滚的流水线管理。当前样本中唯一形成完整沙箱主链的 IM 机器人项目。

**证据强度**：静态源码确认；booters 的远端容器行为（shipyard/cua 云镜像）依赖外部服务，未运行。

### 能力卡 2：主动式 Agent（主动回复 + 定时任务 + 后台唤醒）

**用户目标**：Agent 在用户不发言时也能行动：群聊概率性主动插话、按 cron/一次性计划执行任务、后台任务完成后主动向用户汇报。README 把 Proactive Agent 列为四大招牌之一。

**入口与触发者**：三条并存的主动路径，触发者分别是平台事件（群消息）、时间调度（cron）、任务完成（后台工具）。

**完整主链**（静态走通）：

```text
路径 A 主动回复（群聊概率插话）：
  群消息（非 @、非唤醒命令、白名单通过）
    -> GroupChatContext.need_active_reply（group_chat_context.py:110-128）
        -> method='possibility_reply'：random() < 0.1（默认）
        -> 命中后按普通对话流程生成并发送
   配置：provider_ltm_settings.active_reply.{enable,method,possibility_reply,prompt,whitelist}

路径 B 定时/计划任务：
  配置 proactive_capability.add_cron_tools=True
    -> astr_main_agent._proactive_cron_job_tools（:1224）注入 future_task 工具
    -> cron_tools.py:52-：create/edit/delete/list（cron 或一次性 run_at）
    -> 时区未显式指定时继承会话配置的 timezone（cron_service.py:66-73，#9579）
    -> 执行经 CronMessageEvent 构造主动事件进入 pipeline

路径 C 后台任务唤醒：
  工具 is_background_task -> asyncio.create_task 立即返回 task_id
    -> _wake_main_agent_for_background_result（astr_agent_tool_exec.py:509-619）
        -> CronMessageEvent 模拟事件重建主 Agent，step_until_done(30)
        -> 强制用 send_message_to_user 交付，结果写回对话历史
   平台门控：platform_metadata.support_proactive_message（platform_metadata.py:22），
   仅支持主动消息的平台开放（wecom 需 webhook 等）
```

**主动性边界**：AstrBot 是"事件/计划驱动的主动"而非常驻后台大脑；主动回复只在群聊且概率触发；平台能力（主动消息支持）由各适配器元数据声明（`registry.py:121-181` 的 `_evaluate_send_message_tool` 校验平台支持与 wecom webhook）。

**独特性判断**：三条主动路径组合（概率插话、cron 工具、后台唤醒）构成 AstrBot 的完整主动 Agent 产品面。它与 VCPToolBox TaskAssistant 的 interval/cron/manual 派发、Hermes Agent follow-up 属于同一自然聚类，但触发面增加了 IM 概率插话。

### 能力卡 3：语音能力（IM 语音收发管道）

**用户目标**：在 IM 平台完成语音输入转文本与回复转语音，供无法/不便读文本的场景使用。

**完整主链**（静态走通）：

```text
入站：preprocess_stage（pipeline/preprocess_stage/stage.py:181）对 Record 组件执行
      STT（语音转文本），成功转 Plain 继续流水线
出站：ResultDecorateStage（result_decorate/stage.py:46-56、269-356）
      -> enable + trigger_probability（随机触发） + 会话服务判断
      -> get_using_tts_provider -> get_audio(text) -> 音频文件替换/附带回复
Live Mode：internal.py:297-320 在实时对话模式启用 TTS 处理
Provider 面：core/provider/sources/ 下 14 个 TTS/STT 源
      （azure/edge/elevenlabs/fishaudio/gemini/genie/gsvi/mimo/minimax/openai/
       dashscope/volcengine/sensevoice/xinference）
```

**边界**：TTS 概率触发意味着同一条回复可能是文本或语音；`provider_tts_settings` 的完整字段面未逐项核对。

**独特性判断**：把 14 个语音服务统一进"消息管道装饰"阶段、与平台无关，是 AstrBot 相对纯客户端项目的独特面；独特性中等偏上，建议辅助贡献。

## 已归并到现有类目的能力

- **多 IM 消息投影**：归并已有类目。README 平台清单（QQ/OneBot/Telegram/Wecom/WeChat 公众号/Feishu/DingTalk/Slack/Discord/LINE/Satori/KOOK/Misskey/Mattermost，`README.md:152-174`）与 UMO 归一、九阶段流水线、平台差异投递已由 Chat 概览笔记和 LLM 渠道笔记主链确认。本次只补充：平台元数据中的 `support_proactive_message`（`platform_metadata.py:22`）是消息投影能力与主动能力的交点，已在能力卡 2 记录。
- **1000+ 插件生态**：归并已有类目。star 插件框架的工具与命令装饰器、工具注册、插件生命周期和 WebUI 扩展已由 Agent 工具笔记 §2/§10 覆盖；"1000+" 是插件市场计数（README 徽章来自 `api.soulter.top/astrbot/plugin-num`），属外部生态事实而非本仓库可执行能力。插件安装与更新链未做新增调查。
- **Agent 本体（工具循环、MCP、handoff 子 Agent、上下文压缩）**：Agent 工具笔记与对话请求与上下文笔记已覆盖，不重复。

## 声明不符、外部依赖与暂缓项

- 沙箱默认 booter 为 shipyard_neo（远端容器服务），本地运行需配置 endpoint/token；\computer_use_runtime\ 默认 one\，即能力默认关闭，需显式启用。
- 主动回复默认关闭，概率为 0.1；能力存在但默认不激活。
- 远端沙箱（shipyard/cua 云镜像）依赖外部服务可用性。

## 对特色贡献统计的影响

建议进入主贡献：Agent Sandbox、主动式 Agent（主动 Agent 标签聚类）。辅助贡献：语音能力。归并不计数：多 IM 消息投影、插件生态、Agent 工具链本体。

## 未验证事项

- 未启动实例：沙箱 booter（尤其远端容器）的真实执行、CUA 截图链路、shipyard_neo 技能流水线的服务端行为未验证。
- cron 任务执行与后台唤醒在并发多任务下的顺序与丢消息风险（Agent 工具笔记 §13 已列，未新增验证）。
- 主动回复概率触发与 follow-up 队列并发交互未实测。
- TTS/STT 各 provider 的真实音频收发未逐源验证。

## 关键源码索引

- 沙箱客户端与会话实例：`astrbot/core/computer/computer_client.py:21`、`:551-669`
- booter 族：`astrbot/core/computer/booters/{base,local,cua,shipyard,shipyard_neo,boxlite,bay_manager}.py`
- 沙箱工具：`astrbot/core/tools/computer_tools/{shell,python,fs,cua}.py`、`shipyard_neo/{browser,neo_skills}.py`
- 运行时工具组装：`astrbot/core/astr_agent_tool_exec.py:189-245`
- 主动回复：`astrbot/builtin_stars/astrbot/group_chat_context.py:110-128`
- cron 工具注入：`astrbot/core/astr_main_agent.py:1224`、`astrbot/core/tools/cron_tools.py:52-`
- 主动 Agent 提示词：`astrbot/core/astr_main_agent_resources.py:91/105`
- 后台唤醒：`astrbot/core/astr_agent_tool_exec.py:509-619`
- 平台主动能力元数据：`astrbot/core/platform/platform_metadata.py:22`、`astrbot/core/tools/registry.py:121-181`
- TTS/STT：`astrbot/core/pipeline/result_decorate/stage.py:46-356`、`astrbot/core/pipeline/preprocess_stage/stage.py:181`、`astrbot/core/provider/sources/*_tts*.py`
