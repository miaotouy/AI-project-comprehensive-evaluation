# LobeHub 通用界面盘点（待迁移）

> 来源：`../Chat/LobeHub-Chat调查笔记.md` 第 13 节；2026-08-11 该文件压缩为 Chat 概览时，原第 13 节中未迁移的通用界面盘点内容整体搬出至此
>
> 代码快照：`3b57a07e3cc1f6b5aaabad36112e8ba40142df29`（分支：`canary`）
>
> 迁移规则：以下为原文件第 13 节原文（保留原小节编号、段落与行号证据，未改写）；原段落中对旧文件其它章节的交叉引用（如“第 11、12 节”）保留原样，仅作历史定位
>
> 承接范围：13.1 弹窗、13.2 Toast/Notification、13.3 空状态/骨架屏、13.4 主题、13.6 响应式/移动端、13.7 动画、13.8 图片/附件预览、13.10 拖放、13.12 国际化，13.11 的 PWA 安装与离线提示部分，以及 13.13 未核实事项汇总
>
> 排除说明：13.5 无障碍盘点、13.9 快捷键面板、13.11 桌面通知部分已于 2026-08-11 迁入 [`../Chat UI/LobeHub-ChatUI调查笔记.md`](<../Chat UI/LobeHub-ChatUI调查笔记.md>)（第 8.1/8.2/9/11 节），本文件不重复收录；13.13 中与聊天工作台相关的条目（ActionIcon aria-label、250ms 定时器键盘可达、工具快捷按钮拖拽排序、输入框拖入反馈）在 Chat UI 笔记第 11 节亦有对应记录，迁移期重复属预期
>
> 文档定位：可选界面专题建立前的临时承接位置；实现学习与跨项目横向比较，不作为整改方案

本节聚焦第 11、12 节完全没触及的呈现层细节：弹窗组件库与关闭机制、Toast/Notification 的具体实现、空状态/骨架屏、主题系统、无障碍证据、响应式断点、动画方案、图片预览、快捷键面板和拖放细节。全部基于 Grep + Read 核实，未凭猜测下结论。

## 13.1 弹窗：两套并存的 Modal 体系，不是单一 antd Modal

LobeHub 的弹窗实际上有两条并行实现路径，而不是统一走 antd `Modal`：

- **命令式弹窗**（大多数设置/删除确认/分享/导出场景）：`@lobehub/ui/base-ui` 导出的 `createModal`/`confirmModal`，是一套自封装的命令式 API,不依赖 React 组件树里的 `<Modal open>`。例如：
  - `src/features/TopicDoctorModal/index.tsx:3-15`：`openTopicDoctorModal` 直接 `createModal({ content, footer: null, maskClosable: true, title, width: 'min(90vw, 480px)' })`；
  - `src/features/DeleteTopicConfirm/index.tsx:58-76`：Topic 删除确认走 `confirmModal({ cancelText, content: <DeleteTopicConfirmContent/>, okButtonProps: { danger: true }, onOk })`，其中"是否连带删除已上传文件"的 checkbox 状态通过一个外部闭包变量 `state.removeFiles`（第 56、64-67 行）在弹窗内被修改，再在 `onOk` 里读取——不是受控 state，而是手工闭包同步；
  - `src/features/WorkspaceDeleteAllModal/index.tsx:69-92`：批量删除工作区内容的弹窗把 `maskClosable` 显式设为 `false`（第 88 行），且必须勾选"我已知晓"复选框（`acknowledged` state）才能激活危险操作的红色按钮（第 45 行 `disabled={!acknowledged}`）——这是本次调查中发现的唯一一处对"点遮罩误关闭"做专门防护的高风险操作。
- **响应式包装层**：`src/components/ImperativeModal/index.tsx`（全文件 79-191 行）是一个把"legacy antd Modal 风格 props"（`cancelButtonProps`/`classNames.body`/`styles.wrapper` 等）适配到 `@lobehub/ui/base-ui` 的 `createModal`/`ModalFooter` 上的兼容层，说明代码库正处在从旧 antd Modal 用法迁移到 base-ui 命令式 Modal 的过程中，`ShareModal`（`src/features/Conversation/components/ShareMessageModal/index.tsx:62-84`）就是通过这层 `ImperativeModal` 包出来的。

**Esc/遮罩关闭**：`maskClosable` 在绝大多数弹窗里显式传 `true`（如 `AddWorkingDirModal.tsx:98`、`CreateWorktreeModal.tsx:103`、`ModelSwitchPanel/BenchmarkModal/index.tsx:459` 等 20+ 处），只有少数破坏性操作（`WorkspaceDeleteAllModal`、`ShareDeviceModal.tsx:290`、`Electron/AuthRequiredModal/index.tsx:116,122`、`HeteroSessionImport/index.tsx:14`）把它设为 `false`。**没有找到**对 Esc 键单独配置（`keyboard: false`）的代码点——本次调查未在全仓库搜到任何显式禁用 Esc 关闭的弹窗，说明键盘关闭默认是全局一致开启的，未被针对性关闭过。焦点管理层面本次只读到 `@lobehub/ui/base-ui` 的调用方代码，没有下钻进包内部实现，弹窗打开时是否有 focus trap/焦点归还逻辑**未核实**（这是 base-ui 包内部实现，源码不在 `src/` 下）。

## 13.2 Toast/Notification：antd 静态方法通过单例挂载，位置和堆叠由业务方手工控制

`src/components/AntdStaticMethods/index.tsx`（1-23 行）是唯一入口：一个 `memo` 组件调用 `App.useApp()` 拿到 `message`/`modal`/`notification` 三个静态方法实例，赋给模块级可变导出变量，供全仓库 `import { message, notification } from '@/components/AntdStaticMethods'` 直接调用——这是标准的 antd 5 "AppConfigContext + App.useApp()" 单例挂载模式，不是每处业务代码各自 `useApp()`。

- **错误提示**：`src/components/Error/fetchErrorNotification.tsx:8-17` 用 `notification.error({ description, icon: <FluentEmoji emoji={'🤧'}/>, message: title, type: 'error' })`——图标不是常规 antd icon 而是 emoji 组件，是这套 UI 一贯的"情绪化反馈"风格。`src/components/Error/loginRequiredNotification.tsx:8-19` 类似，额外带 `duration: timeout / 1000` 和 `showProgress: true`（进度条倒计时提示自动跳转登录页的剩余时间）。
- **成功/信息提示**：全仓库大量业务代码直接调用 `message.success/error/warning/loading`（如 `store/chat/slices/topic/action.ts:245-286` 话题复制/导入的 loading→success/error 三态切换；`Conversation/MessageForward/useForwardMessages.ts:38-66` 转发消息的空选中警告和部分失败提示）。**位置**：`AppTheme.tsx:114-152` 里桌面端会在 `useEffect` 里调用 `antdMessage.config({ top: messageTop })`，把 message 弹出位置下移 `TITLE_BAR_HEIGHT + 8`，避免被 Electron 自绘标题栏遮挡——这是本次新发现的一个桌面端专属细节,Web 端没有这个偏移。
- **堆叠/自动消失时长**：`message.loading` 常显式传 `duration: 0`（如 `store/home/slices/sidebarUI/action.ts:37,63,184`、`store/session/slices/sessionGroup/action.ts:50`、`store/chat/slices/topic/action.ts:245`）配合固定 `key` 手动 `message.success`/`message.error` 替换掉同一个 loading 条,是这套代码里"进度型提示"的统一写法；普通 success/error 未见到显式传 `duration`，因此走 antd 默认的 3 秒自动消失。没有找到任何自定义的 Toast 堆叠上限或位置分组逻辑——堆叠行为完全交给 antd `message`/`notification` 的内置队列。
- **专用悬浮通知卡**：`src/components/Notification/index.tsx`（全文件）是一个独立于 antd message/notification 体系之外的自绘悬浮卡片组件（`position: absolute` 定位在右下角，`z-index: 1100`,第 18-31 行），带渐变背景 + SVG 星形装饰纹理（43 行内联 data URI），用于比 message 更重的场景（如引导提示）,不是简单文字条。

## 13.3 空状态/骨架屏：三种场景三套写法，无统一组件

- **消息列表加载中**：`src/features/Conversation/components/SkeletonList.tsx`（1-59 行）手工拼一条"用户消息骨架（右对齐 3 行）+ 两条助手消息骨架（方形头像占位 + 段落 + 2 个标签占位）"，模拟真实对话的视觉节奏,不是通用的 N 行骨架循环。
- **Topic 列表为空**：`src/features/AgentSidebar/Topic/List/index.tsx:7,40,45`——若 topics 尚未加载完成（`isUndefinedTopics`）显示 `SkeletonList`（`src/features/NavPanel/components/SkeletonList.tsx:51-61`，每行是"方形头像占位 + 单行文字占位"的重复,行数固定为 3）；若确定为空则显示 `EmptyNavItem`。这两者复用的是 `NavPanel` 下的通用组件，和上面 Conversation 的 `SkeletonList` 是两个不同文件、不同实现,同名但不共享代码。
- **Agent 市场/发现页加载中**：`src/routes/(main)/community/components/ListLoading.tsx`（14-50 行）用 `Grid` 铺出卡片骨架（头像+标题+段落+标签+底部条各自 `Skeleton.Xxx` 占位）；同文件的 `DetailsLoading`（52-99 行）专门给详情页用，读 `useResponsive().mobile` 在移动端把左右分栏改成 `column-reverse` 纵向堆叠。
- **通用空状态**：`AssistantEmpty.tsx`（`routes/(main)/community/features/AssistantEmpty.tsx:14-30`）用 `@lobehub/ui` 的 `<Empty icon={Bot} type={search ? 'default' : 'page'}/>`，区分"搜索无结果"（只显示 description,无 title,`type='default'`）和"列表本身为空"（显示 title + description,`type='page'`）两种文案态,这个区分模式在 `ModelEmpty`/`ProviderEmpty`/`SkillEmpty`/`McpEmpty` 等同目录文件里重复出现,是发现页的统一约定，但与 Conversation 侧的骨架屏实现完全独立,没有共享基类。
- 骨架屏组件经 `3aee848b9`（#18192）重写为"上下文骨架屏"：`src/features/NavPanel/components/SkeletonList.tsx` 删除重写、Conversation 的 `SkeletonList.tsx` 改写、新增 `AgentSidebar/Topic/List/TopicListSkeleton.tsx`，"品牌化 loading"被移除。"多套并行、无统一组件"的结构结论不变，上述文件与行号描述的是重写前的实现细节。

## 13.4 主题/深色模式：next-themes 管操作系统层面的明暗，`@lobehub/ui` ThemeProvider 管 token

这是本次调查确认的最重要的一条：**"是否 dark"和"具体用什么颜色 token"是两套独立机制拼起来的，不是一个 ThemeProvider 全包了。**

- `src/layout/GlobalProvider/NextThemeProvider.tsx`（1-22 行）用第三方 `next-themes` 的 `ThemeProvider`，配置 `attribute="data-theme"`、`defaultTheme="system"`、`enableSystem`、`disableTransitionOnChange`——它只负责往 `<html>` 写 `data-theme="light"/"dark"` 属性，并处理"跟随系统"（监听 `prefers-color-scheme`）,不涉及具体色值。
- `src/hooks/useIsDark.ts`（7-11 行）是所有业务代码判断当前是否深色模式的唯一入口：`useNextThemesTheme().resolvedTheme === 'dark'`——`resolvedTheme` 是 `next-themes` 算出的"最终生效主题"（system 模式下已经解析成 light/dark 的具体值,不是字符串 `'system'`）。
- `src/layout/GlobalProvider/AppTheme.tsx`（96-198 行）才是真正套用色板的地方：读 `useIsDark()` 算出 `currentAppearence`,传给 `@lobehub/ui` 的 `<ThemeProvider appearance={currentAppearence} customTheme={{ neutralColor, primaryColor }} theme={{ cssVar: { key: 'lobe-vars' }, token: { motion, motionUnit } }}>`（158-176 行）。`neutralColor`/`primaryColor` 来自 `useUserStore`（用户在设置里选的强调色/中性色，第 109-113 行）,且这两个值还会被同步写进 cookie（142-147 行,`LOBE_THEME_PRIMARY_COLOR`/`LOBE_THEME_NEUTRAL_COLOR`），供 SSR 首屏渲染前就能拿到用户偏好,避免首屏色板闪烁。
- CSS 变量方案：`theme={{ cssVar: { key: 'lobe-vars' } }}`（168 行）说明 `@lobehub/ui`/`antd-style` 把所有 token 编译成以 `lobe-vars` 为前缀的 CSS 变量,业务代码里到处出现的 `cssVar.colorXxx`（如 `Notification/index.tsx`、`WorkflowCollapse.tsx` 等）就是读这些变量,而不是编译期静态色值——这是深色模式能在客户端零刷新切换的关键,变量值随 `data-theme` 属性变化由 CSS 层直接生效,不需要 React 重渲染整棵树。
- 存储位置：主题模式（light/dark/system）由 `next-themes` 自己管理,默认存在 `localStorage`（`next-themes` 库行为,未在本仓库代码里看到自定义 storageKey 覆盖）；强调色/中性色存在 `useUserStore`（服务端持久化的用户设置）+ 两个 cookie 镜像。**这意味着"深色/浅色"这个开关和"主题色"这两套偏好实际存在两个不同的持久化层**,前者是纯客户端 `next-themes` 状态,后者走用户账号设置同步。
- 切换入口：`src/features/User/UserPanel/ThemeButton.tsx`（16-60 行，用户面板里的图标按钮 + DropdownMenu，三选一 system/light/dark）与 `src/routes/(main)/settings/common/features/Common/Common.tsx`（45-83 行，设置页里的 `ImageSelect` 大图选择器,附带三张预览图 `theme_light/dark/auto.webp`）是两个独立入口，都最终调用同一个 `next-themes` 的 `setTheme`。`src/features/CommandMenu/ThemeMenu.tsx`（经 `useCommandMenu.ts:118-124` 的 `handleThemeChange`）提供第三个入口——Cmd/Ctrl+K 命令面板里也能直接切主题。
- **动画强度**同样是主题系统的一部分而不是独立开关：设置页的 `animationMode`（disabled/agile/elegant,`Common.tsx:106-136`）被传进 `AppTheme.tsx` 的 `theme.token.motion`（`animationMode !== 'disabled'`）和 `motionUnit`（agile=0.05,其余=0.1,第 173-174 行），统一控制 `@lobehub/ui` 组件库内部动效的开关和速度系数,是全局单一开关,不是每个组件各自配置。

## 13.6 响应式/移动端：断点值在包常量里，移动端走独立路由树 + 底部 TabBar,不是同构响应式布局

- **架构层面**：这套应用不是"一套组件用 CSS 媒体查询自适应",而是 `src/routes/(mobile)/...` 和 `src/routes/(main)/...` 两棵**独立路由树**,由 `vite.config.ts:28,109,115` 的构建配置按 `isMobile` 标志整体切换 entry HTML（`index.mobile.html` vs `index.html`）和产物目录（`dist/mobile` vs `dist/desktop`）——移动端是独立打包出的 SPA,不是同一套 bundle 靠 JS 判断屏幕宽度切换 UI。
- **移动端导航方式**：底部 TabBar,不是抽屉。`src/routes/(mobile)/_layout/NavBar.tsx`（31-87 行）用 `@lobehub/ui/mobile` 的 `<TabBar>`,固定在 `position: fixed; inset-block-end: 0`（24-28 行）,高度取 `MOBILE_TABBAR_HEIGHT`（`packages/const/src/layoutTokens.ts:5`,值为 **48px**）,三个 tab 固定为 Chat/Community（受 `showMarket` feature flag 控制,55 行）/Me,选中态给 icon 加 33% 透明度的主色填充（18-21 行）。
- **断点数值**：均定义在 `packages/const/src/layoutTokens.ts`（1-29 行）：`HEADER_HEIGHT=64`、`MOBILE_NABBAR_HEIGHT=44`（顶部导航条）、`MOBILE_TABBAR_HEIGHT=48`（底部 tab）、`CHAT_TEXTAREA_HEIGHT=160` vs `CHAT_TEXTAREA_HEIGHT_MOBILE=108`（输入框移动端更矮）、`CONVERSATION_MIN_WIDTH=960`（会话区最小宽度,用于桌面端多栏布局判断是否收起侧栏）。**没有找到**一个集中定义的"mobile breakpoint px 值"常量——移动端判定不是靠某个具体像素阈值,而是靠 `src/hooks/useIsMobile.ts`（1-8 行）包的 `antd-style` 的 `useResponsive().mobile` 字段,断点阈值定义在 `antd-style`/`antd` 库内部（未在本仓库代码中覆盖,本次未下钻三方包源码确认具体像素值）。
- **响应式细节**：`AppTheme.tsx:44-46` 用 `@media (device-width >= 576px) { overflow: hidden }` 处理超小屏滚动;`ListLoading.tsx:52-98` 的 `DetailsLoading` 骨架屏在 `mobile` 时把左右两栏改 `column-reverse`;`ShareModal`（`components/ShareMessageModal/index.tsx:32,72`）在移动端把弹窗内 gap 从 24 压到 8。这些都是"读同一个 `mobile` boolean 后手工调整具体样式",不是统一的响应式 Grid 系统。

## 13.7 动画/过渡：`motion/react`(即 framer-motion 的新包名)是唯一方案,但只用在特定组件,并非全局统一动效层

- 依赖库是 `motion/react`（`AppTheme.tsx:11` 里 `import * as m from 'motion/react-m'`,这是 framer-motion 改名后的新发行包，API 与 framer-motion 一致）。`AppTheme.tsx:183` 把 `m`（即 `motion/react-m`,一个专为按需引入优化的子集）作为 `<ConfigProvider motion={m}>` 传给 `@lobehub/ui`,让整个组件库内部动效（如 Modal 进出场、Dropdown 展开）统一走这一份 motion 实例,而不是各组件各自 import。
- **消息级动画**：本次检索**没有在消息进入/离开时找到 `AnimatePresence`/`motion.div` 包裹**——新消息出现在虚拟列表里没有专门的进场动画,是 virtua 直接插入 DOM 节点的默认行为（无渐显/滑入）。这点和第 11 节记录的"`keepMounted` 保留生成中消息避免 Markdown 动画重播"是两件事：`keepMounted` 保的是 Markdown 内部渲染态（如代码块语法高亮增量渲染）,不是消息容器本身的进出场动效。
- **AssistantGroup/WorkflowCollapse 的折叠展开确实用了 `motion/react`**：`Messages/AssistantGroup/components/WorkflowCollapse.tsx:5,412-429,447-473`——展开/收起箭头图标切换用 `AnimatePresence` + `motion.div`（`opacity+scale`,180ms,`ease:[0.4,0,0.2,1]`）;流式阶段的"当前动作标题"文字用 `AnimatePresence mode="popLayout"` 做上下滑入滑出（`opacity+y:±8`,200ms）,这是给"Working... → 具体工具名 → 下一个工具名"这种高频切换的文字做的防跳动处理,而折叠面板主体的展开/收起动画则是交给内部的 `Accordion`（`@lobehub/ui`）组件,没有额外包 `motion`。
- **侧边面板滑动**：`src/utils/motion/panelSlideMotion.ts`（1-37 行）是专门给"左侧主导航"和"右侧编辑器面板"内容切换做的水平滑入滑出变体（8px 位移,280ms,`ease:[0.4,0,0.2,1]`）,目前仅在 `PageEditor/RightPanel/index.tsx` 引用——**不是 Conversation 区域用到的动画**,是文档编辑器侧栏专属;文件里 `isPanelLayerMotionDisabled(animationMode)` 显式检查了第 13.4 节提到的 `animationMode==='disabled'` 开关,说明这类自定义动画有主动接入全局动画开关,但 `WorkflowCollapse` 里的动画**没有看到**类似的 `animationMode` 判断——这是两处自定义动画对"关闭动画"设置遵守程度不一致的具体证据。
- 命令面板（`CommandMenu`）自己的展开动画是纯 CSS `@keyframes slide-down`（`features/CommandMenu/README.md` 文档记录,12%不透明度缩放,120ms ease-out）,不经过 `motion/react`,是第三条独立的动画实现路径。

## 13.8 图片/附件预览：有灯箱放大,基于 `@lobehub/ui` 的 `Image`/`PreviewGroup`,非自建

`Messages/components/ImageFileListViewer.tsx`（1-27 行）用 `@lobehub/ui` 的 `<PreviewGroup>` 包一组 `<GalleyGrid items={items} renderItem={ImageItem}/>`——`PreviewGroup` 是标准的"点击缩略图弹出全屏灯箱、支持组内左右切换"的 antd `Image.PreviewGroup` 风格实现（`@lobehub/ui` 二次封装）。`components/ImageItem/index.tsx:51-83` 内部用 `@lobehub/ui` 的 `<Image preview={preview}>`,`preview` 是外部传入的受控 prop（透传灯箱开关/自定义渲染）。**灯箱本身的具体实现（是否支持缩放/旋转/下载按钮）在 `@lobehub/ui` 包内部,本次未下钻三方包源码,未核实**;仅确认了业务侧接入方式是标准的 `PreviewGroup` 用法,不是自建的 lightbox 组件。

## 13.10 拖放：除 Topic 拖拽引用外,还有资源管理器的文件拖拽和 Skill/工具面板排序拖拽

- **资源管理器拖拽移动文件/文件夹**：`src/routes/(main)/resource/features/DndContextWrapper.tsx`（全文件 75-329 行）是一个**自建的原生 HTML5 drag/drop 实现**,注释明确写"Pragmatic DnD wrapper ... Much more performant than dnd-kit for large virtualized lists"（71-74 行）——即团队评估过 `dnd-kit` 后主动选择原生 `dragstart/drag/drop/dragover/dragend` 事件 + `data-*` 属性做命中测试（119-133 行遍历 DOM `dataset.dropTargetId`），放弃了更重的第三方拖拽库,理由是虚拟化长列表下性能更好。拖拽视觉反馈是手工 `createPortal` 出的跟随鼠标的悬浮卡片（233-322 行,直接改 DOM style 而不走 React state 触发重渲染,241-107 行注释"no React re-render!"），拖拽中还会全局注入一条 `cursor: grabbing !important` 的样式（204-231 行）。支持多选批量拖拽（142-171 行,如果拖的项在当前选中集合里,则整个选中集合一起移动）。
- **本次未找到**插件/工具面板通过 `dnd-kit`/`react-beautiful-dnd` 一类专门拖拽库实现排序的代码——第 12.2 节提到的"工具快捷按钮可在 + 面板固定/取消固定/拖拽排序"经复核,`ChatInput/ActionBar/Tools/useControls.tsx` 里搜索 `DndContext`/`useSortable`/`Draggable` **均无匹配**,说明该处排序功能的具体拖拽实现本次未定位到（可能走的是别的机制,如上下箭头按钮或原生 HTML5 drag 属性,需要进一步读该文件才能确认,本次未深入,标注为未核实）。
- **文件拖入的视觉反馈**：第 11.1 节已提到 Lexical 编辑器支持文件拖入,但拖入时是否有"拖拽悬停高亮输入框边框"一类视觉反馈,本次未在 `InputEditor` 目录下找到专门的 dragover 样式处理,**未核实**。

## 13.11 PWA/桌面端集成（本文件仅含 PWA 安装与离线提示部分；桌面通知部分已迁至 Chat UI 笔记第 9 节）

- **PWA 安装**：`src/hooks/usePWAInstall.ts`（1-38 行）包 `pwa-install-handler` 库,通过查找页面里 id 为 `pwa-install`（`packages/const/src/layoutTokens.ts:29`）的自定义元素调用其 `showDialog`/`externalPromptEvent`——是标准 Web PWA 安装横幅的封装,在已是 PWA 模式或环境不支持时不显示安装按钮（22-23 行）。这是纯安装引导,和"聊天状态"没有直接联动。
- **离线提示**：本次全仓库搜索 `navigator.onLine`/`useNetwork`/`isOnline` 关键词**未找到匹配**，说明当前没有专门的"网络离线"横幅或状态提示，断网场景下的用户反馈依赖第 3 节提到的 `RefreshError` 组件（请求失败时的通用重试条,不区分是否离线导致）。

## 13.12 国际化切换：三处入口共用同一个 `switchLocale`,与主题切换入口分布模式一致

`src/features/User/UserPanel/LangButton.tsx`（13-121 行）是用户面板里的语言切换入口,用 `DropdownMenuCheckboxItem` 列出"自动跟随系统"+ 所有 `localeOptions`,每项显示语言本地名+英文名两行（如"简体中文"配"Chinese, Simplified",27-34/47-54 行）,选中态是 checkbox 勾选而非单选圆点。设置页的 `Common.tsx:84-98` 用普通 `<Select>` 下拉框做同样的事,是第二个入口。两者都调用同一个 `useGlobalStore` 的 `switchLocale` action,语言状态是全局 store 里的单一来源,不是每个入口各自维护。**语言切换与聊天体验的关联**：`AppTheme.tsx:120-139` 显示语言变化会触发 `getUILocaleAndResources(language)` 异步重新加载 UI 文案资源包,加载完成前 `uiLocale`/`uiResources` 维持旧值（避免文案闪烁成 key 名）,这个重载是全局的,包括正在进行中的对话——但由于文案是从消息数据里读的角色/时间戳等而非对话内容本身,切换语言不会影响已发送消息的实际语言,只影响界面文案（按钮、菜单、系统提示语）。语言选择器悬停会预加载 locale 包（`f4aeeca53`，#18135），各语言 locale 文案经批量更新，切换机制不变。

## 13.13 未核实事项汇总（本节新增)

- `@lobehub/ui/base-ui` 的 `createModal`/`Modal` 内部是否有 focus trap、打开时自动聚焦、关闭后焦点归还等无障碍行为——这是三方包内部实现,本次未下钻源码;
- `ActionIcon` 的 `title` prop 是否在渲染时自动映射为 DOM `aria-label`——同样是三方包内部实现,未下钻,直接影响第 13.5 节里"大量图标按钮有没有 aria-label"的判断范围;
- `antd-style` `useResponsive().mobile` 具体的像素断点阈值——库内部实现,未下钻源码确认具体数值;
- `ChatInput/ActionBar/Tools/useControls.tsx` 里"工具快捷按钮拖拽排序"的具体实现机制——本次排除了 `dnd-kit` 等专门拖拽库,但未读该文件确认真正用的是什么机制;
- `InputEditor` 目录下文件拖入时是否有拖拽悬停的视觉反馈样式——未找到专门代码,但也未完整读完整个目录,不排除遗漏;
- Web/PWA 环境下是否存在 Service Worker 层面的推送通知（与 Electron 桌面通知机制完全独立的另一套实现）——本次搜索关键词未命中,但不排除用了本次搜索词覆盖不到的库名。
