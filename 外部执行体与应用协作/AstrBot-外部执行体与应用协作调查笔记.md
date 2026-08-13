# AstrBot 外部执行体与应用协作调查笔记

> 调查对象：`E:\works\git\AstrBot`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`a9bb8a64ca69657e6262e3ca06541ecaf3a6d1ca`（分支：`master`）
>
> 调查方式：静态复核平台 adapter、注册/登录绑定、统一 webhook、UMO、事件流水线和主动投递；复用 Chat、消息渲染和独特功能笔记；未连接真实 IM 平台
>
> 调查范围：外部 IM 平台作为 AstrBot 的主要交互表面；排除普通模型 Provider、插件市场数量和“遥控既有桌面任务”的推断
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 达到外部控制与交互表面的 `主链确认`（静态证据）。`astrbot/core/platform/sources/` 下 18 个平台适配器（Telegram、Discord、Slack、飞书/Lark、企业微信、钉钉、QQ 官方/OneBot、KOOK、LINE、Mattermost、Misskey、Satori、微信公众平台/微信 OCR 等）不是单向通知通道，而是带身份、连接、入站事件、命令、会话映射、媒体转换和出站投递的产品主入口。

它与 DeepChat 的语义不同：AstrBot 本身就是 IM Agent 宿主，不是从 IM 远程驾驶另一个桌面客户端。正式横向比较应保留这一区别。

## 接入角色与系统边界

外部对象是平台 bot/app、用户/群 endpoint 与平台消息线程。AstrBot 持有平台配置、adapter 生命周期、事件队列、UMO 到 conversation/config 的映射、Agent 执行与结果装饰；平台客户端 UI 和平台账号系统不归仓库所有。

## 完整主链

```text
平台 webhook / socket / polling 收到消息
  -> adapter 校验并构造 AstrBotMessage/AstrMessageEvent
  -> unified_msg_origin = platform:message_type:session_id
  -> EventBus 入队并交 PipelineScheduler
  -> 唤醒、白名单、会话、限流、安全、预处理、Agent 执行
  -> MessageChain/result_decorate 按平台能力转换
  -> adapter 发回原 endpoint 或主动投递目标
```

统一 webhook 路由通过 `/webhooks/platforms/{webhook_uuid}` 将请求分发给对应 platform service，另保留 legacy `/webhook/{uuid}` 与 dashboard `/api/platform/webhook/{uuid}` 两处别名，配置提示指向后者；部分平台也支持 socket 或 long connection，其中 Satori 与 aiocqhttp（OneBot v11 反向 WS）是出站 WebSocket 客户端形态，连接外部协议网关而不是被动收 webhook。

```text
平台注册/登录绑定
  -> 飞书/钉钉 app registration（request + poll）
  -> QQ 官方机器人 / 微信 OCR 二维码登录
  -> 平台 token/secret/webhook 配置落库
```

## 身份、协议与状态映射

平台配置实例有稳定 id、token/secret、连接模式和 adapter runtime；部分平台经交互式注册/登录绑定（`platform_service.py`：飞书/钉钉 app registration、QQ 与微信二维码登录），不是只有静态凭据。UMO 将平台、消息类型和 session id 统一为 AstrBot 的会话与配置路由键。conversation、主动任务和停止操作均使用该身份定位。平台能力由 `platform_metadata.py` 按 `support_streaming_message` / `support_proactive_message` 声明，驱动结果装饰与主动投递。

## 执行、回流与控制语义

平台用户可通过普通消息、唤醒词、斜杠/注册命令与 AstrBot 交互。结果按平台限制处理 Markdown、长度、流式、附件和交互组件。主动 Agent、cron 和后台任务可向支持主动消息的平台发送结果；`request_agent_stop_all` 等停止入口按 UMO 终止当前 Agent 工作。断线语义分形态：Satori/aiocqhttp 出站连接带心跳与指数退避重连，Telegram 长轮询带恢复，webhook 形态则依赖平台重投。产品表面即 IM 线程本身，执行位置、账号和连接状态在 dashboard 平台管理页展示，接管入口是直接发言或命令。平台消息属于不可信输入，pipeline 内置限流与安全步骤后才会进入 Agent 执行，可进一步触发文件与业务账号副作用。

## 权限、凭据与治理边界

Telegram/Discord/Slack 等使用各自 token，飞书/企业微信/钉钉等还涉及 app secret、webhook token、AES key 或长连接凭据。白名单、群聊唤醒、平台命令注册和主动消息能力共同限制入口。Agent 工具、容器沙箱和审批属于相邻类目，不能由平台连接直接推断。

## 相邻类目交接

- UMO、事件流水线和会话主链见[Chat 笔记](../Chat/AstrBot-Chat调查笔记.md)。
- 各平台文本、媒体和流式差异见[消息渲染器笔记](../消息渲染器/AstrBot-消息渲染器调查笔记.md)。
- 主动回复、cron 和后台唤醒见[独特功能笔记](../独特功能/AstrBot-独特功能调查笔记.md)。

## 已确认边界与未验证事项

- 未运行真实平台登录、webhook 签名、断线重连、命令同步或限额行为。
- 多 IM 主链成立，但不据此声称能接管其他桌面应用的既有任务。
- “支持平台数量”随 adapter 与外部 API 变化，本文不作长期兼容承诺。

## 关键源码索引

- `astrbot/core/platform/`
- `astrbot/core/platform/sources/`
- `astrbot/core/platform/sources/{satori/satori_adapter,aiocqhttp/aiocqhttp_platform_adapter}.py`
- `astrbot/core/platform/platform_metadata.py`
- `astrbot/core/platform/webhook_server.py`
- `astrbot/dashboard/api/platform.py`
- `astrbot/dashboard/services/platform_service.py`
- `astrbot/core/config/default.py`
- `astrbot/core/star/context.py`
- `astrbot/dashboard/services/chat_service.py`

