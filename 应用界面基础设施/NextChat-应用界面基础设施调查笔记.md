# NextChat 应用界面基础设施调查笔记

> 调查对象：`E:\works\git\NextChat`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`defdcdb55d850cd12c4c657eb83729fd66e215c0`（分支：`main`）
>
> 调查方式：静态源码核对（Grep + Read 全文阅读 `app/components/ui-lib.tsx`、`home.tsx`、`utils.ts`、`styles/globals.scss`、`store/config.ts`、`store/chat.ts`、`utils/chat.ts`、`src-tauri` 各文件等），对引用的符号与行号逐一核对当前 HEAD；2026-08-13 追加主题体系专项核对（token 全集、字体配置与 Google Fonts、theme-color 链路、主题市场/导入导出/壁纸/主色/自定义 CSS 关键词 grep + glob）；视觉效果、焦点行为与桌面运行表现未运行验证
>
> 调查范围：应用根装配与 Provider/浮层机制、自研 UI 库（Modal/Toast/Popover/Selector/FullScreen）、通知与加载/空状态/错误边界、主题链路与持久化（含 2026-08-13 主题体系核对：token 全集与悬空变量、fontSize/fontFamily 与字体加载、theme-color 取值链路）、响应式断点与侧栏/PWA、图片上传/预览/剪贴板/下载公共机制、Tauri 壳交点（窗口、系统通知、流式桥接、更新）；聊天主链交点（toast 业务消费、主题切换按钮、附件上传流程、消息操作弹窗入口、滚动反馈）由 [`../Chat UI/NextChat-ChatUI调查笔记.md`](<../Chat UI/NextChat-ChatUI调查笔记.md>) 记录，本笔记只记录公共机制；仓库布局见 [`../仓库分布/NextChat-仓库分布调查笔记.md`](../仓库分布/NextChat-仓库分布调查笔记.md)
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 无任何第三方组件库（无 antd/Radix/MUI，`package.json:23-60`），弹窗与 Toast 全部是 `ui-lib.tsx` 里的自研基础组件 + 命令式 API：`showModal/showConfirm/showPrompt/showToast/showImageModal` 每次调用都新建 div、用 `react-dom/client` 的 `createRoot` 挂到 `document.body`（无 Portal、无 host、无队列与单例）。主题以 `useAppConfig` store 中的 `config.theme`（auto/light/dark）为权威源，切换只给 `body` 加减 `light`/`dark` 类，auto 由 SCSS `@media (prefers-color-scheme)` 兜底，持久化走 zustand persist + IndexedDB（idb-keyval）。主题 token 是明暗两组固定 SCSS 变量（`--primary` 单一主色且明暗同值），无自定义主色、壁纸、自定义 CSS 或主题导入导出，定制仅限明暗三态 + `fontSize`/`fontFamily` 配置与 Google Fonts 按需注入；MCP 市场页引用了全仓未定义的 `--primary-10`/`--primary-dark` 悬空变量（详见 §4）。响应式是 600px 单断点（JS 与 CSS 双轨一致），桌面侧栏可拖拽调宽并写入 `--sidebar-width` CSS 变量，移动端侧栏是纯 CSS 抽屉。图片上传依赖 ServiceWorker 拦截 `/api/cache` 或本地压缩兜底，消息图片是裸 `<img>`（本次未找到聊天图片灯箱）。Tauri 壳是薄封装：单窗口 + `data-tauri-drag-region` 标题栏 + 自定义 `stream_fetch` 命令做流式 HTTP 桥接，系统通知仅用于应用更新。

## 系统边界与总体装配

- **界面栈**：Next.js 14（app router，`next.config.mjs` 支持 standalone/export 双模式）+ react-router-dom `HashRouter` 客户端路由 + zustand v4（persist 中间件）+ SCSS Modules 自研组件；`package.json` 无 antd/Radix/Tailwind/framer-motion，公共依赖只有 `@hello-pangea/dnd`（会话列表拖拽）、`emoji-picker-react`、`mermaid`、`html-to-image`（导出）等点状工具。
- **根装配**：`app/layout.tsx` 输出 `<meta name="config">`（`getClientConfig` 构建期配置）、`site.webmanifest` 链接与 `serviceWorkerRegister.js`；`app/page.tsx` 渲染 `Home`。`Home`（`app/components/home.tsx:237-272`）依次执行 `useSwitchTheme`、`useLoadData`、`useHtmlLang`、访问配置拉取与可选 MCP 初始化，然后 `useHasHydrated`（`home.tsx:127-135`，仅 effect tick 节流，不检查 store 的 `_hasHydrated`）之后渲染 `ErrorBoundary > Router(HashRouter) > Screen`。
- **Screen**（`home.tsx:160-221`）：按路径渲染 Artifacts/Auth/SD 独立分支或 `SideBar + WindowContent + Routes`，页面组件全部 `dynamic` 懒加载；应用外壳容器是"窗口卡片"形态（桌面 Web 90vw/1200px 圆角卡片，`home.module.scss:1-18`）。
- **无 Provider 树**：全应用没有 Context Provider 装配（浮层不走 portal 也不经 provider）；`grep createPortal` 全 `app` 目录无匹配，唯一 `ResizeObserver` 出现在 artifacts 的 iframe 内嵌脚本（`app/components/artifacts.tsx:82`）。
- **持久化**：全局 store 统一走 `createPersistStore`（`app/utils/store.ts:29-78`）→ zustand `persist` + `createJSONStorage(() => indexedDBStorage)`；`indexedDBStorage`（`app/utils/indexedDB-storage.ts:7-45`）优先 idb-keyval，失败回退 `localStorage`，且 `setItem` 会跳过未水合（`_hasHydrated === false`）的写入。Store 键见 `app/constant.ts:90-101`（chat/config/access/mask/prompt/plugin/update/sync/sd-list/mcp）。

## 1. 界面栈、公共组件与状态所有权

- **自研公共组件**（`app/components/ui-lib.tsx`）：`Modal`、`Popover`、`Card`、`List/ListItem`、`Loading`、`Input/PasswordInput`、`Select`、`Selector`（列表选择器，模型选择复用）、`FullScreen`（原生 `requestFullscreen` API 封装，`ui-lib.tsx:555-589`）；按钮是 `IconButton`（`app/components/button.tsx:9-66`，SVG 图标 + 可选文字，`aria` prop 可选）；头像/表情是 `Avatar`/`AvatarPicker`（`app/components/emoji.tsx`，emoji 走 jsdelivr CDN）。
- **状态所有权**：弹窗/Toast 是**无状态命令式 API**——每次调用在组件树外自建根节点，无队列、无单例、无 store 参与（区别于 Cherry Studio 的 popup/toast store）；界面偏好（`theme`/`sidebarWidth`/`fontSize`/`tightBorder`/`submitKey` 等）全部在 `useAppConfig`（`app/store/config.ts:41-107`）并持久化；会话与消息在 `useChatStore`；窗口几何状态由 Tauri 侧 `tauri-plugin-window-state` 持久化（见 §7）。
- **消费方式**：业务组件通过 `useChatStore()`/`useAppConfig()`（zustand hooks）或命令式 `showXxx()` 调用；`config.update()` 走深拷贝合并（`app/utils/store.ts:61-68`）。

## 2. 弹窗、浮层与菜单

- **Modal 组件**（`ui-lib.tsx:122-179`）：标题栏含最大化/最小化（`-max` 类切 95vw/95vh）与关闭按钮；Esc 关闭由组件内部 `useEffect` 在 `window` 上挂 `keydown` 监听实现（`ui-lib.tsx:123-136`，依赖数组为空，首次渲染的 `onClose` 闭包常驻）。
- **命令式弹窗四件套**（`ui-lib.tsx:181-475`）：`showModal`/`showConfirm`/`showPrompt`/`showImageModal` 均为 `document.createElement("div")` + `createRoot(div)`，div 挂 `.modal-mask`（`app/styles/globals.scss:246-261`，`z-index: 9999`，flex 居中，移动端 `align-items: flex-end` 底部弹起）。遮罩点击关闭靠 `div.onclick` 里 `e.target === div` 判定（`ui-lib.tsx:193-197`）；关闭即 `root.unmount() + div.remove()`，无两阶段退场（区别于 Cherry 的 200ms 延迟卸载）。`showConfirm` 返回 `Promise<boolean>`，确认按钮 `autoFocus`；`showPrompt` 返回 `Promise<string>`。
- **层级**：modal-mask 9999、toast 99999（§3）、`Selector` 全屏遮罩 999（`ui-lib.module.scss:301-311`）、`Popover` 内联 `z-index: 2`（`ui-lib.module.scss:10-13`）——无统一 z-index 管理，四层硬编码值。
- **焦点与滚动**：本次未找到焦点陷阱/焦点归还逻辑（无 `tabIndex` 圈禁、无 `focus` 事件兜底）；`body` 全局 `overflow: hidden`（`globals.scss:97-118`），应用滚动都在容器内部，弹窗无需滚动锁定。自动聚焦只有 `showConfirm` 确认按钮与 `PromptInput` 的 `autoFocus`。
- **Popover**（`ui-lib.tsx:29-46`）：非 portal——`position: relative` 容器内 `absolute` 内容面板（宽 350px，右对齐，`ui-lib.module.scss:15-26`）+ `fixed` 半透明模糊遮罩（`.popover-mask`）点击关闭；内容定位溢出屏幕边界无翻折处理（静态推断）。
- **菜单类**：本次未找到 Tooltip、ContextMenu 或 Dropdown 公共机制（`ui-lib.tsx` 导出清单与 `app/components` 目录内均无对应文件）；代码块"复制"按钮是纯 CSS hover 显示（`globals.scss:273-305`）；输入区按钮组的弹出面板复用 `Popover`/`Selector`/`Modal`（见 Chat UI 笔记 §3/§4）。
- **销毁时机**：路由切换时组件树内弹窗随卸载；命令式弹窗独立于路由，只随调用方 close 逻辑销毁（静态推断，未运行验证）。

## 3. 通知、加载态与错误反馈

- **Toast**（`ui-lib.tsx:232-256`）：`showToast(content, action?, delay=3000)` 每次调用独立建 div（`.show`，`ui-lib.module.scss:183-198`，`z-index: 99999`，`position: fixed` 底部居中），`delay` 后加 `.hide` 类（0.3s 退场）再 `setTimeout` unmount 移除。**无堆叠/队列机制**：多个 toast 并存时都是 fixed 在窗口底部同一区域，视觉上会重叠（静态推断，未运行验证）。支持一个 `action` 按钮（如删除会话的 5 秒撤销：`app/store/chat.ts:368-377` 传 `delay=5000`）；无成功/错误/严重级别区分，无 `role`/`aria-live` 语义。
- **Loading**：`Loading`（全屏三圆点 SVG，`home.tsx:34-41`）用作 `dynamic()` 页面懒加载 fallback（`home.tsx:43-83`）与首屏 `useHasHydrated` 门控；`ui-lib.tsx:98-112` 另有一个等价全屏 Loading。消息流式打字/预览态在 Chat UI 笔记 §5。
- **空状态**：MCP 市场有 "No servers available"（`mcp-market.tsx:463-464`）、SD 页有 `Locale.Sd.EmptyRecord`（`sd.tsx:332`）；会话列表无空态渲染（`chat-list.tsx:134-173` 只 map sessions，最后一条会话删除时 store 自动 push 空会话 `store/chat.ts:352-355`）；聊天窗无欢迎/空态文本（grep `Welcome|EmptyChat` 无匹配，检查范围 `app` 目录）。
- **错误边界**：`ErrorBoundary`（`app/components/error.tsx:19-73`）class 组件挂在 `Home` 最外层，捕获后展示错误栈、`Report This Error`（GitHub issue 链接）与 `Clear All Data`（`showConfirm` 确认后先 `useSyncStore.export()` 再 `clearAllData()`）。
- **系统通知**：仅 Tauri 桌面端、仅应用更新场景（`app/store/update.ts:92-128`，`window.__TAURI__.notification.sendNotification`）；聊天完成无系统通知（Chat UI 笔记 §7 已确认，grep `Notification` 全 `app` 目录无其他消费点）。

## 4. 主题、视觉 token 与持久化

- **权威源**：`useAppConfig` store 的 `config.theme`（`Theme.Auto/Dark/Light`，`app/store/config.ts:33-37`，默认 `auto`，`:48`），持久化到 IndexedDB；Web 端无主进程概念，浏览器内唯一权威。
- **应用链路**：`useSwitchTheme`（`home.tsx:85-114`）effect 中给 `document.body` 加减 `light`/`dark` 类；两个 `meta[name="theme-color"][media]` 的初始值由 Next viewport 元数据提供（`app/layout.tsx:20-28`，light `#fafafa`/dark `#151515`），切换时 auto 模式写回硬编码 `#151515`/`#fafafa`，非 auto 模式读 `--theme-color` 的计算值（`getCSSVar`，`app/utils.ts:220-222`，基于 `getComputedStyle(body)`）同时写入两个 meta（`home.tsx:98-112`）。auto 模式不加类，由 `globals.scss:84-88` 的 `@media (prefers-color-scheme: dark)` 让 `:root` 跟随系统。
- **视觉 token**：SCSS `@mixin light/dark`（`globals.scss:4-45`）定义明暗两组 CSS 变量并挂在 `.light`/`.dark` 类与 `:root` 媒体查询上（`:47-88`）：颜色 `--primary`（rgb(29,147,171)，明暗同值）、`--white`、`--black`、`--gray`、`--second`、`--hover-color`、`--bar-color`、`--theme-color`（`= var(--gray)`）、`--theme` 模式标识；阴影 `--shadow`/`--card-shadow`；描边 `--border-in-light`。布局变量在 `:root`（`globals.scss:59-68`）：`--window-width`（90vw）、`--window-height`（90vh）、`--sidebar-width`（300px）、`--window-content-width`（`calc(100% - var(--sidebar-width))`）、`--message-max-width`（80%）、`--full-height`，600px 断点下整体重定义（`:70-82`）。暗色下对 SVG 图标做全局 `filter: invert(0.5)`（`:42-44`），`no-dark` 类可豁免。**悬空 token**：`--primary-10`/`--primary-dark` 仅在 `mcp-market.module.scss:273,297,339,467,515,548` 被引用（焦点环/按钮背景），全仓 `.scss/.css` 无定义（grep 定义语法 `--primary-10\s*:` 无匹配），CSS 变量无定义时引用属性失效，视觉表现需运行确认。
- **字体配置**：`fontSize`（默认 14，滑块 12-40，`settings.tsx:1644-1657`）与 `fontFamily`（默认空串，文本输入，`settings.tsx:1660-1675`）存 `config`（`config.ts:46-47`）；消费端是 Markdown 容器内联样式（`markdown.tsx:337-338`：`${fontSize}px` + `fontFamily || "inherit"`），消息渲染（`chat.tsx:995-996,1983-1984,2092-2093`）与导出（`exporter.tsx:578-579`）传入。基础字体栈写在 `html` 上（`globals.scss:93-94`：Noto Sans/SF Pro/PingFang SC/Helvetica 等）；`loadAsyncGoogleFont`（`home.tsx:137-150`）在 `Screen` effect 中动态注入 Google Fonts 的 Noto Sans 300/400/700/900，非 export 构建经自身 `/google-fonts` 代理加载、export 构建直连 `fonts.googleapis.com`。
- **切换入口**：输入区主题按钮循环 Auto→Light→Dark（`chat.tsx:516-521, 632-640`）与设置页 Select（`settings.tsx:1606-1617`）；两者都写 `config.theme`。
- **首屏闪烁**：本次未找到防闪烁内联脚本（`layout.tsx` head 只有 manifest 与 SW 脚本）——`:root` 默认 light，用户持久化为 dark 且系统为 light 时，CSR 首帧先亮、`useSwitchTheme` effect 后变暗（静态推断；`useHasHydrated` 只节流渲染不参与主题）。第三方组件 `emoji-picker-react` 独立传 `theme={EmojiTheme.AUTO}`（`emoji.tsx:39`），自行跟随系统。
- **主题扩展能力（本次未找到）**：主题市场/商店与主题导入导出（grep `importTheme|exportTheme|theme.json` 全仓无匹配，glob `**/themes/**` 无目录）；壁纸/背景图（grep `wallpaper` 无匹配，`backgroundImage` 仅 `chat.tsx:2103` 的消息图片渲染、`globals.scss:333-336` 的代码折叠渐变，均非主题背景）；自定义主色/强调色设置（grep `accent` 仅 `markdown.scss:41-42,87-88` 的 GitHub 风格 markdown 变量 `--color-accent-fg/emphasis`，不属应用主题系统；`customCss|userStyle` 无匹配；JS `setProperty` 写 CSS 变量的唯一消费是 `--sidebar-width`，`sidebar.tsx:130`）；Tailwind 配置（无 `tailwind.config.*`）。

## 5. 响应式、移动端与窗口适配

- **断点**：600px 单断点双轨一致——JS `MOBILE_MAX_WIDTH = 600`（`app/utils.ts:145-150`，基于 `useWindowSize` 的 resize 监听）+ CSS `@media (max-width: 600px)`（`globals.scss:70-82,111-113`、`home.module.scss:108-134`、`ui-lib.module.scss:22-26,171-181`）。`useMobileScreen` 驱动多个组件差异（如移动端隐藏全屏/快捷键按钮、附件与弹窗入口差异，见 Chat UI 笔记 §9）。
- **窗口形态**：桌面 Web 为居中卡片（90vw×90vh）；`isApp`（Tauri 构建，`BUILD_APP` 环境变量，`app/config/build.ts:12`）或 `config.tightBorder` 时切 `tight-container` 全屏无边框（`home.module.scss:24-38`）；移动端容器去边框去圆角全宽。聊天头部另有 tightBorder 切换按钮（`chat.tsx:1748-1762`）。
- **侧栏**：桌面可拖拽调宽（300 默认/230 最小/500 最大/100 窄栏），`useDragSideBar`（`sidebar.tsx:65-137`）用 pointermove 节流 20ms 更新 `config.sidebarWidth`，松手距按下 <300ms 视为点击切换窄栏；宽度经 effect 写入 `document.documentElement.style.setProperty("--sidebar-width")`（`sidebar.tsx:125-131`）。移动端侧栏是纯 CSS 抽屉：`position: absolute; left: -100%`，仅 Home 路由加 `sidebar-show` 类滑入（`home.module.scss:118-129`，z-index 1000；`home.tsx:190-193`）。
- **PWA**：`site.webmanifest`（standalone，`start_url: "/"`）；ServiceWorker（`public/serviceWorker.js`）**只拦截 `/api/cache/*`**（图片上传/读取/删除），install 时 `cache.addAll([])` 空列表、`serviceWorkerRegister.js:10-12` 首次安装即整页 reload——本次未找到离线应用壳能力。SW 注册成功后置 `window._SW_ENABLED`，决定上传路径（§6）。
- **Tauri 窗口**：单窗口 960×600、Overlay 标题栏（`titleBarStyle: "Overlay"`、`hiddenTitle: true`，`src-tauri/tauri.conf.json:108-118`）；窗口几何由 `tauri-plugin-window-state` 持久化（`src-tauri/src/main.rs:9`）。

## 6. 图片、附件、拖放与常见内容交互

- **剪贴板**：`copyToClipboard`（`app/utils.ts:28-51`）三路：Tauri `writeText`（`window.__TAURI__` 存在时）→ `navigator.clipboard` → textarea + `document.execCommand("copy")` 兜底，成功/失败各有 toast。
- **下载与读取**：`downloadAs`（`utils.ts:53-94`）Tauri 走 `dialog.save + fs.writeTextFile`，浏览器走 data URL + `<a download>`；图片导出在 Tauri 下走 `dialog.save + writeBinaryFile`（`exporter.tsx:457-477`）；`readFromFile` 用隐藏 `<input type="file" accept="application/json">`（`utils.ts:96-114`）。
- **图片上传链路**（`app/utils/chat.ts`）：`uploadImage`（`:144-165`）在 `window._SW_ENABLED` 时 POST `/api/cache/upload`（由 ServiceWorker `upload` 拦截写入 Cache Storage 并返回 `/api/cache/<nanoid>.<ext>`，`public/serviceWorker.js:22-41`）；SW 不可用时回退 `compressImage`（`:15-71`）——canvas 渐进压缩到 ≤256KB base64，HEIC 先经 `heic2any` 转 JPEG；`cacheImageToBase64Image`（`:113-132`）对已上传图片二次压缩并做模块级内存缓存。上传失败会 toast 错误（Chat UI 笔记 §3 有业务侧流程）。
- **拖放**：本次未找到文件拖放支持——grep `onDrop|onDragOver|dataTransfer|DragEvent` 全 `app` 目录无业务代码匹配（`@hello-pangea/dnd` 内部实现未下钻，属于库内部）。图片只能经文件选择器或粘贴（`chat.tsx:1512-1598`）。
- **图片预览**：`showImageModal`（`ui-lib.tsx:452-475`）只是 Modal 里一个 `<img>`，无缩放/旋转/导航；消费方为导出图片预览（`exporter.tsx:483`）、mermaid 图点击（`markdown.tsx:47-53`）、SD 页图片（`sd.tsx:170`）。**聊天消息图片无灯箱**：消息列表渲染裸 `<img>` 且无 onClick（`chat.tsx:1988-2022`）。
- **内容嵌入**：Markdown 链接按扩展名自动内嵌 `<audio>`/`<video>`（`markdown.tsx:293-307`）；代码块复制按钮与 HTML/mermaid 预览（`markdown.tsx:74-174`）。

## 7. 扩展调查

### 桌面与系统集成（Tauri 壳交点）

- **桥接方式**：`withGlobalTauri: true`（`tauri.conf.json:8`），渲染层直接读 `window.__TAURI__`（类型见 `app/global.d.ts:14-42`）；权限走 Tauri v1 allowlist（dialog/clipboard/fs/notification/http 全开，`tauri.conf.json:15-59`）。
- **流式请求桥接**：浏览器 fetch 在 Tauri 下换成 `app/utils/stream.ts:22-108`——`invoke("stream_fetch", ...)` 发起，Rust 侧 `src-tauri/src/stream.rs:34-144` 用 reqwest 请求并把响应按 `ChunkPayload`/`EndPayload` 事件（`stream-response`）逐块 emit 回渲染层写入 `TransformStream`；AbortSignal 关闭流。用于绕开桌面端跨域/CORS 限制（Chat UI 笔记主链即经此桥）。
- **标题栏**：各页面头部 `data-tauri-drag-region` 支持原生拖窗（`chat.tsx:1685`、`sidebar.tsx:186`、`settings.tsx:1504`、`sd.tsx:111`）。
- **系统通知与更新**：仅更新检查通知（§3）；`clientUpdate` 走 `updater.checkUpdate/installUpdate`（`utils.ts:449-470`），安装模式 `passive`（`tauri.conf.json:103-105`）。
- **未找到**：托盘、原生菜单、全局快捷键、多窗口（grep `tray|Tray|globalShortcut|setMenu|Window` 相关在 `src-tauri/src` 与 `app` 中无匹配，检查范围为本快照 Tauri 源码与 `app` 目录）。

### 无障碍与动画（静态代码结论）

- `IconButton` 可选 `aria` prop，多处传入（如 `chat.tsx:1733,1813` 的 `aria={...}`）；但多数图标按钮只带 `title` 而无 `aria-label`（`button.tsx:37` 的 `title` 不自动进 `aria-label`，读屏可访问名称覆盖参差——静态推断）。
- Modal/Toast/Popover 均无 `role`/`aria-modal`/`aria-live` 语义；`PromptToast` 入口有 `role="button"`（`chat.tsx:246-248`）。
- 动画：无动画库，全部手写 CSS——`animation.scss` 的 `slide-in`/`slide-in-from-top` keyframes 用于弹窗/列表进场（`ui-lib.module.scss:18,44,84,99,190`）；Toast 用 opacity/translateY transition 退场；`prefers-reduced-motion` 处理本次未找到。代码块复制按钮 hover 显隐、消息悬停等为 CSS transition（`globals.scss:273-305`、`home.module.scss:208-224`）。

## 8. 设计取舍与已确认边界

- **零组件库**：UI 全部自研（SCSS Modules + SVG 图标），浮层命令式 `createRoot` 直挂 body——无 portal 复用、无队列与堆叠管理、无焦点管理；与 Cherry Studio（store 驱动单例）和 Chatbox（MUI+sonner 双机制）形成对比。
- **Toast 无严重级别与堆叠**：所有反馈同一视觉形态，多 toast 并存重叠（静态推断）。
- **主题双轨**：`body` 类 + `:root` 媒体查询并存；无防闪烁脚本（静态推断存在首帧闪窗窗口）。
- **主题定制面窄**：token 是明暗两组固定色板，无自定义主色、壁纸、自定义 CSS 或主题导入导出，定制仅限明暗三态 + 字号/字体（见 §4）；MCP 市场页引用未定义的 `--primary-10`/`--primary-dark`，属 token 消费不一致（静态确认无定义，视觉影响未运行验证）。
- **上传依赖 SW**：SW 不可用时整条 `/api/cache` 路径消失、退回本地压缩 base64（静态确认，见 `uploadImage` 分支）。
- **聊天图片无灯箱**、无文件拖放、无 Tooltip/ContextMenu 公共机制（检查范围见 §2/§6 说明）。
- **PWA 非离线壳**：SW 只服务 `/api/cache`，`cache.addAll([])`。
- 聊天主链交点（toast 业务触发点、主题切换按钮、附件/粘贴流程、消息操作弹窗入口、滚动到底反馈等）由 Chat UI 笔记记录，本笔记不重复。

## 9. 未验证事项

- 运行验证：Esc/遮罩关闭、toast 重叠视觉、移动端抽屉与 300ms 侧栏切换、主题首帧闪窗、SW 上传路径切换，均未实测。
- 桌面表现：Tauri 窗口状态持久化、Overlay 标题栏拖拽、系统通知权限流程与更新流程未运行验证。
- 依赖库内部未下钻：`@hello-pangea/dnd`（拖拽排序内部实现与移动端行为）、`emoji-picker-react`、`mermaid`、zustand `persist`/`createJSONStorage` 内部、react-markdown 默认渲染器。
- 图片压缩画质、HEIC 转换在不同浏览器的实际表现未实测；`cacheImageToBase64Image` 内存缓存的失效策略未深查。
- 无障碍结论均基于静态代码，未经读屏实测；`prefers-reduced-motion` 覆盖情况未确认。
- 主题视觉：`--primary-10`/`--primary-dark` 悬空变量导致的 MCP 市场焦点环/按钮背景失效、theme-color meta 在浏览器地址栏/PWA 的实际呈现、`/google-fonts` 代理与 Google Fonts 注入后的字体加载表现，均未运行验证。

## 10. 关键源码索引

- 根装配与路由：`app/layout.tsx`、`app/page.tsx`、`app/components/home.tsx:85-272`
- 自研 UI 库：`app/components/ui-lib.tsx:29-589`、`app/components/ui-lib.module.scss`
- 主题：`app/components/home.tsx:85-114,137-150`、`app/store/config.ts:33-37,46-49,164-261`、`app/styles/globals.scss:4-88`、`app/layout.tsx:20-28`、`app/utils.ts:220-222`、`app/components/markdown.tsx:337-338`
- 持久化：`app/utils/store.ts:29-78`、`app/utils/indexedDB-storage.ts:7-45`
- 响应式与侧栏：`app/utils.ts:121-150`、`app/components/sidebar.tsx:65-137`、`app/components/home.module.scss:108-134`
- 图片上传/压缩：`app/utils/chat.ts:15-71,113-165`、`public/serviceWorker.js:22-61`
- 剪贴板/下载：`app/utils.ts:28-114`
- 错误边界：`app/components/error.tsx`
- Tauri：`src-tauri/tauri.conf.json`、`src-tauri/src/main.rs`、`src-tauri/src/stream.rs`、`app/utils/stream.ts`
- 系统通知：`app/store/update.ts:92-128`
