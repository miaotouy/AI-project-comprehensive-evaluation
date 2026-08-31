# VCPMobile Chat UI 调查笔记

> 调查对象：`VCPMobile`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`cecdbe432feda57821938bba7625a272113d21c1`（分支：`main`）
>
> 调查方式：静态阅读 Vue 组件、Pinia UI 状态、事件绑定与 Android 输入适配代码
>
> 调查范围：移动聊天工作台、会话选择、Composer、流式反馈与消息操作；不包含全应用设置或视觉审计
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPMobile 拥有移动端 Chat UI：固定头部、可滚动消息区、底部 Composer 和 Agent/Group 侧栏共同构成工作台。会话切换通过 owner 下的 Topic 进行；列表与未读状态独立于消息窗口，输入暂存与活动流也分属不同 store。

## 工作台边界与用户主链

用户从 Agent/Group 侧栏选择 owner，再选择或创建 Topic；ChatView 监听当前 Topic，将其标已读并加载历史。页面由 header、消息列表和固定输入区组成，软键盘高度写入 CSS 变量，且空态可打开侧栏引导选择助手，见 `src/features/chat/ChatView.vue:88-198, 278-342`。

发送动作由 InputEnhancer 发射给 history store；工作台自身只组合 Store 与滚动控制，不直接执行请求。当前主题、通知、侧栏抽屉和键盘 Insets 是外围 UI 状态，聊天主链只在需要时消费它们。

## 1. 会话导航、搜索与现场恢复

Topic 列表可按标题或格式化日期过滤；它支持新建、删除、改名、锁定与未读标记。选择 owner 时优先恢复持久化的最近活动 Topic，否则向本地服务取最新项；选择变更增加 epoch，使正在返回的旧列表无法污染新现场，见 `src/core/stores/topicListManager.ts:63-168, 171-305` 和 `src/core/stores/chatSessionStore.ts:174-227`。

消息阅读的“现场恢复”以历史窗口、滚动锚点和活动流对象为主。未找到跨会话消息搜索面板、分支树或版本导航 UI；底层 FTS 索引是否有其他页面入口超出本次已确认范围。

## 2. Composer、草稿、附件与快捷输入

Composer 是单个 textarea，可输入文本，支持粘贴处理、相机、相册、文件、语音转文字及长按录音附件。附件在独立 store 暂存并显示横向预览，未完成上传时发送按钮禁用；外部 Android 分享意图会先选择 Agent、创建新 Topic，再把文本/文件预填到 Composer，见 `src/features/chat/InputEnhancer.vue:360-615` 和 `src/core/stores/chatSessionStore.ts:83-138`。

草稿是组件内输入状态，不按 Topic 持久化；外部分享预填是 session store 中的一次性状态。Ctrl/Cmd+Enter 可发送或停止，移动端实际软键盘与焦点效果尚未运行验证。

## 3. 发送、流式反馈与停止

发送按钮在有内容或生成中显示，生成中变为停止图标。它会对当前活动流集合逐条调用停止；群聊另有全局停止组件。消息区依据流 store 的活动 ID 启停跟随滚动，进入其他 Topic 后，非当前流可转换为未读提醒，见 `src/features/chat/InputEnhancer.vue:373-395, 560-570` 与 `src/core/stores/chatStreamStore.ts:340-422`。

静态代码可确认停止控件最终调到 Rust 的中断命令，但不能证明网络层已经在所有 Android 状态下停止，具体终结语义见[对话请求与上下文](../对话请求与上下文/VCPMobile-对话请求与上下文调查笔记.md)。

## 4. 消息操作与阅读导航

对消息长按弹出操作菜单。用户消息可编辑或删除；助手消息可复制、停止、重新生成、重新渲染与删除。操作把内容修改、截断或请求重启交给 history/stream store，消息壳只负责入口和菜单装配，见 `src/features/chat/MessageRenderer.vue:601-711`。

列表没有通用虚拟滚动组件。初始页较小、上翻按键集游标分页；滚动状态机在加载旧页前记录顶部可见消息锚点，prepend 后恢复位置。最后一条保留底部空白，避免被输入区遮挡，见 `src/features/chat/ChatView.vue:278-342` 与 `src/core/composables/useChatScroll.ts:30-381`。

## 5. UI 状态所有权与边界

当前 owner、Topic 和最近 Topic 映射由持久化的 session store 保存；历史窗口、载入状态和编辑重发目标由 history store 保存；活动流由 stream store 保存；附件暂存由 attachment store 保存。这个拆分使切换会话时可清空历史窗口而保留全局流恢复能力，详见[会话与消息管理](../会话与消息管理/VCPMobile-会话与消息管理调查笔记.md)。

## 未验证事项

未在设备上验证侧栏手势、响应式抽屉、焦点顺序、TalkBack 可用性、语音/STT、软键盘避让、通知返回会话以及长历史滚动性能。

## 关键源码索引

- `src/features/chat/ChatView.vue:88-198, 278-342`
- `src/features/chat/InputEnhancer.vue:360-615`
- `src/features/chat/MessageRenderer.vue:601-711`
- `src/core/stores/topicListManager.ts:63-305`
- `src/core/composables/useChatScroll.ts:30-381`
