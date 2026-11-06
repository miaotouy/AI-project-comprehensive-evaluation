# VCPMobile Chat UI 调查笔记

> 调查对象：`VCPMobile`
>
> 调查更新日期：2026-11-05
>
> 代码快照：`5fa2eb09e4f4dfab299cbb609a8b904b3485b5a5`（分支：`main`）
>
> 调查方式：静态阅读 Vue 组件、Pinia UI 状态、事件绑定与 Android 输入适配代码
>
> 调查范围：移动聊天工作台、会话选择、Composer、流式反馈与消息操作；不包含全应用设置或视觉审计
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 拥有移动端 Chat UI：固定头部、可滚动消息区、底部 Composer 和 Agent/Group 侧栏共同构成工作台。会话切换通过 owner 下的 Topic 进行；列表与未读状态独立于消息窗口，输入暂存、活动流与语音通话状态也分属不同 store。Composer 的主按钮在文本发送、停止生成、停止朗读和语音通话之间切换。

## 工作台边界与用户主链

用户从 Agent/Group 侧栏选择 owner，再选择或创建 Topic；ChatView 监听当前 Topic，将其标已读并加载历史。页面由 header、消息列表和固定输入区组成，软键盘高度写入 CSS 变量，且空态可打开侧栏引导选择助手，见 `src/features/chat/ChatView.vue:1-234,236-413`。iOS 端窗口几何由独立 composable 接管，WebView 从后台恢复时按窗口与壁纸状态重绘。

发送动作由 InputEnhancer 发射给 history store；工作台自身只组合 Store 与滚动控制，不直接执行请求。当前主题、通知、侧栏抽屉和键盘 Insets 属外围 UI 状态，不属于聊天主链。

## 1. 会话导航、搜索与现场恢复

Topic 列表可按标题或格式化日期过滤；它支持新建、删除、改名、锁定、置顶与未读标记。选择 owner 时把最近活动 Topic 提示与当前排序交给 Rust；后端验证 owner/Topic 仍存在后选定目标，缺少有效提示时按话题排序取首项。导航与通话共享 Rust 侧仲裁，通话中切换会话会返回提示；页面代次和导航序号使旧 WebView 或迟到请求无法重获焦点。见 [会话 Store](../../VCPMobile/src/core/stores/chatSessionStore.ts#L145-L235)、[导航服务](../../VCPMobile/src-tauri/src/vcp_modules/chat/chat_navigation.rs#L130-L220)。

Agent 侧栏搜索按钮打开独立全局消息搜索页。用户可按全部、owner 或 Topic 搜索，并筛选发言 Agent、角色和时间；本地搜索结果显示摘要和高亮。点击结果携消息 ID 请求导航，后端确认消息仍存在且导航获准后，才关闭搜索页并投影锚点前后的消息窗口；目标消失或通话中则保留页面并提示。见 [侧栏入口](../../VCPMobile/src/components/layout/AgentSidebar.vue#L70-L96)、[搜索跳转](../../VCPMobile/src/features/globalsearch/GlobalSearchView.vue#L277-L301)。本次在消息模型和聊天菜单内仍未找到分支树或版本导航。

## 2. Composer、草稿、附件与快捷输入

Composer 是单个 textarea，可输入文本，支持粘贴处理、相机、相册、文件、语音输入与语音通话。语音输入由 Tauri 插件采集、Rust 语音服务完成语音活动检测与识别，结果回到 Composer；通话模式下发送按钮变为语音控制入口。附件在独立 store 暂存并显示横向预览，未完成上传时发送按钮禁用；外部 Android 分享意图会先选择 Agent、创建新 Topic，再把文本/文件预填到 Composer，见 `src/features/chat/InputEnhancer.vue:179-330,534-811` 和 `src/features/chat/ChatView.vue:95-110`。

普通草稿是组件内输入状态，不按 Topic 持久化；外部分享草稿由独立 share Store 持有，发送时走其提交路径，见 [发送分流](../../VCPMobile/src/features/chat/InputEnhancer.vue#L267-L285)。Ctrl/Cmd+Enter 可发送或停止，移动端实际软键盘与焦点效果尚未运行验证。

## 3. 发送、流式反馈与停止

主按钮依据草稿、生成和朗读状态选择发送或停止；JEV 群聊持续回合中有新草稿且未编辑旧消息时，可继续追加消息。停止时单聊逐个中断当前活动消息，群聊直接调用按 Topic 停止整轮；无生成而有气泡朗读时停止朗读。见 [输入动作](../../VCPMobile/src/features/chat/InputEnhancer.vue#L289-L339)。非当前 Topic 的回复仍可触发未读提醒，历史锚点或固定窗口则保留阅读区，不因回复到达自动切回尾部，见 [可见消息投影](../../VCPMobile/src/core/stores/chatWindow.ts#L90-L108)。

静态代码可确认停止控件最终调到 Rust 的中断命令，但不能证明网络层已经在所有 Android 状态下停止，具体终结语义见[对话请求与上下文](../对话请求与上下文/VCPMobile-对话请求与上下文调查笔记.md)。

## 4. 消息操作与阅读导航

对消息长按弹出操作菜单。用户消息可编辑或删除；助手消息可复制、停止、重新生成、重新渲染、朗读与删除。操作把内容修改、截断或请求重启交给 history/stream store，消息壳只负责入口和菜单装配，见 `src/features/chat/MessageRenderer.vue:1026-1245`。

列表没有通用虚拟滚动组件。初始页较小、上翻按键集游标分页；滚动状态机在加载旧页前记录顶部可见消息锚点，prepend 后恢复位置。最后一条保留底部空白，避免被输入区遮挡，见 `src/features/chat/ChatView.vue:236-413` 与 `src/core/composables/useChatScroll.ts:43-656`。

## 5. UI 状态所有权与边界

当前 owner、Topic 与获准窗口来自 Rust 焦点，session store 保存其投影及持久化冷提示；history store 组合窗口读取与编辑重发意图；活动流和暂存附件各有独立 Store。语音通话与朗读的业务快照由 Rust 持有，前端 voice Store 消费快照并发出控制意图，见 [通话快照投影](../../VCPMobile/src/features/chat/voice/voiceCallStore.ts#L84-L105)。这个拆分使切换会话时可清空历史窗口而保留全局流恢复能力，详见[会话与消息管理](../会话与消息管理/VCPMobile-会话与消息管理调查笔记.md)。

## 未验证事项

未在设备上验证侧栏手势、响应式抽屉、焦点顺序、TalkBack 可用性、语音输入与语音通话的真实采集质量、软键盘避让、通知返回会话以及长历史滚动性能；iOS 窗口几何与 WebView 恢复路径只做源码确认。

## 关键源码索引

- `src/features/chat/ChatView.vue:1-234,236-413`
- `src/features/chat/InputEnhancer.vue:179-330,534-811`
- `src/features/chat/MessageRenderer.vue:1026-1245`
- `src/features/chat/voice/voiceCallStore.ts`、`voiceConversation.ts`：语音通话会话与状态机
- `src/core/stores/topicListManager.ts:62-260`
- `src/core/stores/chatSessionStore.ts:40-120`
- `src/core/composables/useChatScroll.ts:43-656`
