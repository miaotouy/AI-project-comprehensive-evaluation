# SillyTavern 应用界面基础设施调查笔记

> 调查对象：`E:\works\git\SillyTavern`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：基于当前 HEAD 的静态源码核对（Grep + Read 全文阅读），逐条标注文件行号；查无实据的方向直接写"未找到"
>
> 调查范围：弹窗 Popup 系统、Toastr 全量盘点、加载/空状态、右键菜单、主题、无障碍、响应式断点、动画参数、图片预览、拖放、扩展面板结构；聊天主链细节（loader toast 与生成反馈的交点、拖放反馈、弹窗返回定位等）由 [`../Chat UI/SillyTavern-ChatUI调查笔记.md`](<../Chat UI/SillyTavern-ChatUI调查笔记.md>) 记录
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 的界面基础设施是"原生 Web 技术 + 自研机制"的路子：弹窗系统基于浏览器原生 `<dialog>` 元素与自研 `Popup` 类（非 jQuery UI Dialog），点击遮罩不会关闭弹窗是与其他现代弹窗库不同的行为选择；通知统一走 toastr 库但调用点分散在 86 个文件 988 处，没有统一封装层；主题是服务端 JSON 存储 + CSS 变量运行时改写，且全仓库无 `prefers-color-scheme`（不跟随系统深色模式）；无障碍现状是"键盘可用性有专门框架保障，屏幕阅读器语义几乎缺失"。此外发现了一个此前笔记未记录的设计完整的 Action Loader 子系统（阻塞遮罩单例 + 可堆叠带停止按钮的 toast）。

## 系统边界与总体装配

- **界面栈**：原生 HTML + 手写 JS（jQuery 辅助），无前端框架；UI 组件以 `public/index.html` 静态模板 + `public/scripts/*.js` 事件绑定为主，样式在 `public/css/`。
- **弹窗系统**：`public/scripts/popup.js`（966 行）是唯一弹窗实现，`#popup_template`（`<template>`）克隆 `.popup`（即 `<dialog>`）。
- **全局状态**：大量状态存在 `power_user` 设置对象（主题名、toastr 位置等）与服务端接口（主题、聊天记录）；"生成中"是 `document.body.dataset.generating` 全局单一状态位（`script.js:7020, 7029`），不是逐消息级别。

## 1. 界面栈、公共组件与状态所有权

- **弹窗组件**：`Popup` 类（`popup.js:195-236`），枚举 `POPUP_TYPE`：`TEXT`/`CONFIRM`/`INPUT`/`DISPLAY`/`CROP`（`popup.js:9-20`）；`callGenericPopup`（`popup.js:909-917`）是常用入口，`Popup.show.input/confirm/text`（`popup.js:106-146`）是语义化封装。
- **浏览器兼容兜底**：不支持 `showModal()` 时用 `dialogPolyfill.registerDialog()`（`../lib/dialog-polyfill.esm.js`）打补丁，并挂 `ResizeObserver` 在 polyfill 场景重新定位（`popup.js:237-248`）。
- **toastr 是全局工具库**：全仓库 86 个文件、988 处 `toastr.success/error/warning/info(...)` 调用（grep 统计，未逐一验证每个触发场景），几乎每个功能模块直接调用，无统一"通知服务"包装层——与 `Popup` 有类封装的做法不同。
- **Action Loader 子系统**（`public/scripts/action-loader.js`，617 行）：「正在处理」反馈的标准做法，`ActionLoaderHandle` 同时管理阻塞遮罩（复用 `Popup` 的 `DISPLAY` 类型渲染 `transparent+wide+large+allowEscapeClose:false` 弹窗当遮罩，`action-loader.js:530-548`）与可堆叠 toast（`#createToast`，`action-loader.js:170-205`）。消费点：聊天重命名（`script.js:10616-10621`）、首次加载初始化（`script.js:719`）、`script.js:11221` 等。

## 2. 弹窗、浮层与菜单

**弹窗系统**（`public/scripts/popup.js`，全文已读，966 行）：底层是浏览器原生 `<dialog>`，不是 jQuery UI Dialog（jQuery UI 只用于 `.sortable()` 等组件）。

- **Esc 关闭**：默认 `allowEscapeClose: true` 时拦截 `cancel` 事件并 `complete(POPUP_RESULT.CANCELLED)`（`popup.js:604-607`）。显式 `false`（阻塞性弹窗）时首次 Esc 被吞，但**双击 Esc 强制关闭**：500ms 内连按两次会弹出"Force-close Blocking Popup"二级确认弹窗，确认后才强制关闭（`popup.js:556-607`，注释自嘲"Don't ask me why this is needed. I don't get it. But we have to keep it."）。
- **遮罩关闭**：`showModal()` 自带 `::backdrop`，但代码里没有点击遮罩关闭的逻辑——`cancelListener` 只绑 `cancel` 事件，无 `click` 目标判断。**点击弹窗外部区域不会关闭弹窗**，已核实（通读全文件未发现相关代码，且历史交互经验一致）。
- **焦点管理**：`setAutoFocus()`（`popup.js:700-733`）打开时给默认按钮/输入框设 `autofocus`；关闭时 `focusin` 持续记录 `lastFocus`（`popup.js:538`），弹窗栈中还有更底层弹窗时把焦点还给它记住的 `lastFocus` 或重新 `setAutoFocus()`（`popup.js:836-844`）——支持多层堆叠（`Popup.util.popups` 数组维护堆叠顺序，`popup.js:860-862`）。
- **拖拽/缩放**：Popup 本身不可拖拽缩放；可拖拽缩放的是另一套独立的 `dragElement()`（`script.js:477-约560+`，用于"Moving UI"把面板变成可拖拽浮窗，拖拽头部 `.drag-grabber`、`actionType === 'resize'` 分支，位置和尺寸持久化进 `power_user.movingUIState[elmntName]`），用在头像放大浮层（`.zoomed_avatar`）等场景——两套并行、不共享代码的"可移动 UI"实现。
- **Enter 提交**：弹窗内 `keydown` 监听 Enter（`popup.js:623-664`），守卫逻辑：焦点不在最上层弹窗内、焦点不是 `.result-control`、或焦点在多行文本框且没按 Ctrl 时不触发——避免多行输入换行误提交。

**右键/上下文菜单**（全仓库搜 `contextmenu`，聊天消息 `.mes` 无绑定，只有两处）：

- **角色卡网格长按/右键菜单**（`public/scripts/BulkEditOverlay.js`）：`mousedown`/`touchstart` 触发 `handleHold()`，`setTimeout(..., longPressDelay = 2500)`（`BulkEditOverlay.js:389`）判定长按；浏览态长按切多选，多选态长按弹 `CharacterContextMenu`（批量标签/删除）。原生 `contextmenu`（`BulkEditOverlay.js:499,558-563`）只有 `isLongPress` 为真才 `preventDefault + stopPropagation`，普通右键放行——兼容鼠标右键和触屏长按的手势适配。
- **Quick Reply 按钮右键**（`extensions/quick-reply/src/QuickReply.js:116-123`）：配置了右键上下文动作时拦截并弹自定义菜单。

## 3. 通知、加载态与错误反馈

**Toastr 全局配置**（`public/script.js:347-365`）：位置 `toast-top-center`，无关闭按钮，无进度条，显隐动画 250ms，普通提示 4000ms，`extendedTimeOut` 10000ms，`escapeHtml: true`（防 XSS）。位置可在设置里改（`power_user.toastr_position`，`power-user.js:1078`）。`fixToastrForDialogs()`（`popup.js:934-966`）检测最上层 `dialog[open]:not([closing])`，把 `#toast-container` 移进 dialog 内部、关闭时挪回 `document.body`——解决原生 `<dialog>` 模态层级高于 toast 的问题，在 toastr `onHidden`（`script.js:360-364`）和 `Popup.show()/hide()`（`popup.js:683, 817`）里调用。差异化处理是零星的：`tags.js:1910` 给标签导入结果设 `timeOut: toastr.options.timeOut * 2`，但 `error/warning/info/success` 四种共享同一 `timeOut`，无系统化分级。

**加载/空状态是三层独立实现，互不复用**：

1. **首屏 HTML 预加载层**（`index.html:52` `<div id="preloader">`，样式 `css/loader.css:1-17`）：纯 HTML+CSS，`backdrop-filter: blur(30px)` 毛玻璃盖住 JS 未跑完的空白期；首次隐藏统一 loader 后由 `yoinkPreloader()`（`action-loader.js:609-613`）移除，`preloaderYoinked` 标志防重复。
2. **Action Loader 系统**（`action-loader.js`）：遮罩单例（`hasBlockingLoaders()`，`action-loader.js:63-70, 150`），每个操作有独立 toast（可同时看到多条）。toast 三种模式（`ActionLoaderToastMode`：`NONE`/`STATIC`/`STOPPABLE`，`action-loader.js:23-30`），`STOPPABLE` 带停止按钮（`fa-stop-circle`，点击调 `onStop` 或默认 `stopGeneration()`，`action-loader.js:270-286`）——"生成中"可直接从 toast 上点停止。这类 loading toast 用 `toastr.info` 渲染但 `timeOut: 0, extendedTimeOut: 0, tapToDismiss: false`（`action-loader.js:199-204`），不自动消失也不能手动关，只能代码结束——与普通提示 toast 是同一 toastr 库上两种不同交互模式。
3. **CSS 驱动的空状态占位**（零 JS）：World Info 条目列表空时 `#world_popup_entries_list:empty::before { content: 'No entries found.'; }`（`css/world-info.css:64-约70`）；群聊添加成员列表空时 `content: attr(no_characters_text)` 读 HTML 属性文案（`css/rm-groups.css:118-119`，`index.html:6342`）——`:empty` 命中后 `::before` 用 `content: attr(...)` 直接渲染，无需 JS。但主角色列表 `#rm_print_characters_block` **没有**类似规则——"角色列表完全为空"没有专门空状态提示（已核实为"未做"而非"没找到"）。

"生成中"三点动画（`@keyframes ellipsis`，`css/animations.css:85-101`）在 grep 全仓库后未找到挂到聊天区"角色正在输入"的代码——当前主聊天流的生成反馈是 Action Loader toast + `body[data-generating="true"]` 驱动的 CSS（`style.css:4569`），不是气泡内三点动画。

## 4. 主题、视觉 token 与持久化

主题不是简单深浅二元切换，而是可配置的 CSS 变量集合：

- `power_user.theme`（默认 `'Default (Dark) 1.7.1'`，`power-user.js:177`）标识选中主题；颜色值是 `--SmartThemeXxxColor` 系列变量（`power-user.js:159-168`，`main_text_color`/`italics_text_color`/`blur_tint_color`/`chat_tint_color` 等十来个），初始值从 `getComputedStyle(document.documentElement)` 读出。
- `applyTheme(name)`（`power-user.js:1227-约1430+`）遍历 `themeProperties` 数组，把每个字段映射到颜色选择器 DOM 与 `applyThemeColor`/`applyBlurStrength`/`applyCustomCSS` 等应用函数——切换主题本质是批量 `document.documentElement.style.setProperty('--SmartThemeXxx', 值)`（`applyThemeColor`，`power-user.js:1104-1143`），纯 CSS 变量运行时改写，不是切换 CSS 文件。
- **自定义 CSS**：`power_user.custom_css`（`power-user.js:170`）由 `applyCustomCSS()`（`power-user.js:1147-1157`）注入 `<style>` 的 `innerHTML`，用户可为任意选择器写任意规则并持久化。
- **主题导入安全提示**：`importTheme(file)`（`power-user.js:2443-2476`）解析上传的主题 JSON，若 `custom_css` 含 `@import` 字符串先弹 `themeImportWarning` 警告弹窗确认才继续（`power-user.js:2459-2465`）——防"看起来像主题文件、实际从外部 URL 拉资源"。
- **存储位置**：通过 `/api/themes/save`、`/api/themes/delete`（`power-user.js:2499, 2404`）存到服务端（`src/server-startup.js:121, 148` 挂载 `themesRouter`），和聊天记录一样"服务端持久化、多设备共享"，不是 localStorage。
- **系统偏好跟随**：`public/` 范围内全仓库搜索 `prefers-color-scheme` **无匹配**（唯一命中是第三方库 `lib/pdf.min.mjs`）——**不自动跟随 OS 深浅色**，主题完全手动选择，已核实（全文 grep 无匹配，非推断）。

## 5. 响应式、移动端与窗口适配

响应式集中在 `public/css/mobile-styles.css`（全文 656 行已读），是媒体查询驱动的桌面/移动切换，无响应式框架：

- **主断点 `max-width: 1000px`**（`mobile-styles.css:2-508`，注释"catches ipads, horizontal phones, and vertical phones"）：各设置面板列改 `flex-basis: 100%` 单列堆叠（`:4-11`）；`body { touch-action: none; overflow: hidden; position: fixed; }`（`:250-254`，禁默认触摸手势、锁定 body 滚动）；抽屉面板 `.drawer-content` 改 `position: fixed` 铺满 `100dvw`（`:260-269`）。
- **横屏子断点**：`max-width: 1000px and (orientation: landscape)`（`:511-534`）单独处理头像放大层定位与 waifu 表情图裁剪。
- **竖屏窄屏子断点**：`max-width: 450px`（`:537-580`）把抽屉宽度比例从 1/4、1/3 收窄成 1/2。
- **iOS 专属分支**：`@supports (-webkit-touch-callout: none)`（`:583-656`）处理 `env(safe-area-inset-*)` 刘海屏安全区与 PWA 模式（`body.PWA`）底部安全区内边距（`:610-615`）——官方认真对待"作为 PWA 装到 iOS 主屏幕"的场景。
- **触摸手势（已核实缺失）**：全仓库搜索 swipe 相关代码 + `touchstart/touchmove/touchend` 绑定，**没有"消息上左右滑动触发 swipe 候选回复"的手势实现**——移动端 swipe 是点击 `<` `>` 箭头按钮（`.swipe_left`/`.swipe_right`）。真正用触摸事件的只有三处：滑动条触摸时锁页面滚动 300ms（`script.js:11696-11711`）、角色卡长按（见第 2 节）、头像放大层关闭点击兼容 `touchend`（`script.js:12225`）。
- **触屏专用调参**：`getSortableDelay()`（`utils.js:358-364`）——桌面拖拽排序延迟 50ms，移动端 750ms，注释明确"防止滚动页面时误触发拖拽"；`.sortable({ delay, handle })` 模式遍布 world-info、tags、openai、textgen-settings 等十余个文件，但各模块各自初始化，无集中的"可排序列表"组件封装。

## 6. 图片、附件、拖放与常见内容交互

**图片/附件预览**（`expandMedia`，`chats.js:880-970` 已读）：复用第 2 节的 `Popup` 弹窗系统，不是独立灯箱库。

- 弹窗类型 `POPUP_TYPE.DISPLAY`（只有关闭 X），传 `{ large: true, transparent: true }`（`chats.js:960`）铺大、背景透明。
- **点击放大/还原是纯 class toggle**：点击图片切换 `.zoomed` class（`chats.js:941-945`），CSS 侧 `.img_enlarged` 用 `object-fit: contain` + `cursor: zoom-in`，`.zoomed` 切 `object-fit: cover` 并允许滚动（`style.css:5305-5319`，`.img_enlarged_holder:has(.zoomed) { overflow: auto; }`）——是"缩小适应"与"原始比例填充可滚动"的切换，不是支持拖拽平移/滚轮缩放的真正图像浏览器。
- 视频走同样弹窗但换 `<video controls autoplay>`（`chats.js:913-919`）；音频类型**明确不支持展开**（`chats.js:896-898`，`console.warn('Audio media cannot be expanded')`）。
- 点击弹窗背景关闭（`popup.dlg.addEventListener('click', () => popup.completeCancelled())`，`chats.js:964-966`）——与"Popup 不支持点遮罩关闭"不矛盾：这是调用方在内容层手动加的监听，非类内建能力。
- 有标题媒体用 `<pre><code>` 渲染说明文字（`chats.js:947-957`），`stopPropagation` 防点击标题触发放大/关闭。
- **另一套独立查看器**：桌面端头像放大用 `jquery.izoomify`（`public/lib/jquery.izoomify.js`，`script.js:12221-12223`），鼠标悬停局部放大镜，依赖 `mouseover`/`mousemove`（`jquery.izoomify.js:144-147`），仅 `power_user.zoomed_avatar_magnification` 开启时生效——纯触屏设备上基本不可用（未实测，标注未核实）。消息图片弹窗、头像 izoomify、头像拖拽浮层 `dragElement` 是三套并行实现，无统一"图片查看器"组件。

**拖放分两类完全不同的实现**：

**A. 文件拖入导入**（`DragAndDropHandler` 类，`public/scripts/dragdrop.js`，107 行已读）：构造传选择器和回调，用 jQuery 事件委托在 `document.body` 上监听 `dragover/dragleave/drop`（目标元素重渲染也不丢监听，`dragdrop.js:52-65`）；`dragleave` 用 `debounce_timeout.quick` 去抖（`dragdrop.js:87-91`，防内部子元素边界闪烁）。4 个消费点：
- 角色卡拖入导入：`charDragDropHandler = new DragAndDropHandler('body', ...)`（`script.js:12494-12499`，`noAnimation: true`），区分文件（`processDroppedFiles()`，`script.js:10401-10434`，按 MIME/扩展名白名单——`application/json`、`image/png`、YAML、`.charx`、`.byaf`，其它 `toastr.warning` 拒绝）与外部 URL（`importFromURL`）。
- 聊天记录导入：`chatDragDropHandler = new DragAndDropHandler('#select_chat_popup', ...)`（`script.js:12501-12507`），拖入文件塞进隐藏 `<input type="file">` 触发 `change` 复用文件选择逻辑。
- 附件拖入弹窗：`chats.js:1510`（Data Bank / Attachment Manager 弹窗内，拖入后弹目标选择器选作用域）。
- 消息输入框拖入：`chats.js:2392-2394`（`#form_sheld`，直接走 `handleFileAttach`）。
- 拖拽悬停视觉统一由 `drop_target`/`dragover` class 驱动（`dragdrop.js:75, 90, 102`），各消费点共享一套视觉语言。

**B. 列表拖拽排序（jQuery UI `.sortable()`）**：`public/lib/jquery-ui.min.js` 的 sortable 插件，不是 SortableJS。World Info 条目（`world-info.js:2576-2580`，`items: '.world_entry', delay: getSortableDelay(), handle: '.drag-handle'`）、Quick Reply 按钮（`QuickReply.js:1007`、`QuickReplyConfig.js:70`）、正则规则（`regex/index.js:1177-1932`，全局/局部/预设级各自独立排序）、采样器参数（textgen/nai/kai-settings、openai、logit-bias、tags 等十余处）反复出现同一模式——共享 `getSortableDelay()` 的"移动端延迟更长"参数，但排序功能本身分散初始化、代码不共享。

**扩展面板（Extensions panel）**：`#rm_extensions_block`（`index.html:5741`）是**一串固定 ID 的空容器 `<div>`**（`#extensions_settings` 下挂 `#assets_container`/`#typing_indicator_container`/`#expressions_container`/`#sd_container`/`#tts_container` 等二十多个，`index.html:5760-5780+`），各内置扩展初始化时把设置 UI 塞进对应容器——不是动态生成列表，是预先开好的"坑位"。第三方扩展入口是输入框旁"魔法棒"图标（`addExtensionsButtonAndMenu()`，`extensions.js:688-723`）弹出 Popper.js 定位的下拉菜单（`#extensionsMenu`，`placement: 'top-start'`，`extensions.js:699-701`），点击外部白名单外区域自动收起（`extensions.js:714-722`）——魔法棒菜单是"扩展快捷动作入口"，Extensions 抽屉是"扩展详细设置面板"，两个不同概念。扩展启停：`.extension_toggle` 复选框（`extensions.js:928, 1225, 1243`）触发 `enableExtension/disableExtension`（`extensions.js:473-500`），**默认整页刷新**（`location.reload()`，`:479, 496`），批量切换场景传 `reload: false` 累积后用 `requiresReload` 标记统一刷新一次（`extensions.js:1218-1243`）——零散切换与批量切换的交互刻意区分。第三方扩展列表弹窗区分"默认容器/外部容器"两组展示，加载时显示 `fa-spin` + "Loading third-party extensions... Please wait..."（`extensions.js:1156-1164`），提供 "Update all"/"Update enabled"（`extensions.js:1186-1203`）与 "Toggle extensions"（`extensions.js:1205-1219`，含仅在有历史批量记录时显示的 "Restore toggled extensions" 还原按钮，`:1214-1216`）；排序偏好（`sortByName`/`sortManifestsByOrder`，`extensions.js:1166-1169`）存 `accountStorage`（浏览器本地，非服务端）。

## 7. 扩展调查：无障碍与动画

### 无障碍现状（静态代码结论，未做读屏实测）

**"键盘可达性有自建框架，语义化 ARIA 几乎缺失"**：

- `aria-*` 属性几乎不存在：`index.html` grep `aria-` 仅 1 处命中（装饰图标 `aria-hidden="true"`，`index.html:5733`）；全部 `public/scripts/*.js` 只有 3 个文件各 1 处 `role=`，且都是把业务数据值（prompt 的 role 字段）写进 HTML 属性，不是无障碍语义——实质上没有专门为读屏设计的 `aria-label`/`aria-describedby`/`role="button"`（全文 grep 的确定性结果）。
- 绝大多数"按钮"是 `<div>`/`<i>` 图标：`index.html` 有 245 处 `.menu_button` 相关 `<div>`，而非原生 `<button>`。
- **补偿机制**：`public/scripts/keyboard.js`（254 行已读）实现"interactable"注册系统——CSS 选择器白名单（`interactableSelectors`，`keyboard.js:2-28`，涵盖 `.menu_button`、`.mes_buttons .mes_button`、`.swipe_left/.swipe_right`、角色卡片等近 30 类），`MutationObserver` 监听 DOM（`keyboard.js:46-58`）给匹配元素动态加 `tabindex="0"`（`makeKeyboardInteractable`，`keyboard.js:121-159`），`document` 级 `keydown` 收到 Enter 沿 DOM 树找最近 interactable 元素 `.click()`（`handleGlobalKeyDown`，`keyboard.js:213-234`）。这套系统解决 Tab 可达与 Enter 触发，但没解决读屏"怎么念这个按钮"——`<div tabindex="0">` 无 `role`/`aria-label` 时读屏通常跳过或只读文字内容。
- `title` 属性大量存在（595 处）但不能替代 ARIA；手写 `tabindex` 只有 3 处（`switch_input_type_icon` 设 `-1` 刻意排除、`mes_impersonate` 设 `0`），其余靠 `keyboard.js` 运行时动态加。
- 结论（已核实）：键盘可用性中等（有专门框架保障 Tab/Enter），读屏语义几乎没有；未做 NVDA/VoiceOver 实测，实际体验可能因浏览器/读屏兼容性而异，**未做运行时验证**。

### 动画与过渡

`public/css/animations.css`（154 行已读）定义可复用 `@keyframes`：`fade-in`/`fade-out`（纯透明度）、`pop-in`/`pop-out`（透明度+垂直缩放，`pop-in` 在 0%-33% 就把 `scaleY` 拉到 1、后 67% 只调透明度）、`flash`（强调高亮）、`pulse`（`filter: brightness` 呼吸）、`ellipsis`（三点省略号，未找到消费点）、`infinite-spinning`（`.PastChat_cross:hover` 删除叉号旋转，纯装饰）、`slide`（依赖 `--slide-mes-x-start/end` 变量，消息删除动画位移方向可由 JS 指定起止点）。

全局动画时长由 `ANIMATION_DURATION_DEFAULT = 125`（`script.js:595`）驱动的 `--animation-duration` CSS 变量控制（`setAnimationDuration()`，`script.js:824-828`），用户可在设置里改；抽屉展开/收起在已有其它抽屉打开时先等 `animation_duration` 毫秒再切换（`doNavbarIconClick()`，`script.js:10908-10910`）。这与第 12 节记录的 `stream-fadein.js`（流式消息逐词淡入，`morphdom` + `Intl.Segmenter`）是两个层面：一个管面板级开合，一个管文本级淡入。

## 8. 设计取舍与已确认边界

- **点遮罩不关闭弹窗**：与大多数现代 Web 弹窗库相反的行为选择，已核实。
- **双击 Esc 强制关闭阻塞弹窗**：踩坑后留下的防御代码，作者注释自承原因不明。
- **toastr 无统一封装**：988 处调用分散在 86 个文件，作为全局工具库随处调用；差异化时长只是零星个例。
- **主题不跟随系统深浅色**：`public/` 无 `prefers-color-scheme` 匹配（已核实），主题手动选择、服务端存储。
- **"生成中"反馈不是三点动画**：走 Action Loader toast + `data-generating` 全局状态位，气泡无"正在输入"动画。
- **移动端 swipe 是点按钮不是划手势**：与功能名字暗示不符，已核实缺失。
- **主角色列表空状态缺失**：CSS `:empty` 空状态模式未覆盖主角色列表。
- **扩展面板固定坑位**：内置扩展是预先开好的空容器，不是动态生成列表。

## 9. 未验证事项

- toastr 988 处调用的每个触发场景未逐一验证。
- 触屏设备上 izoomify 悬停放大镜的实际体验未实测。
- 无障碍结论基于静态代码扫描，未做屏幕阅读器实测；`title` 属性在具体读屏/浏览器组合下的朗读行为未验证。
- 各消费点 `drop_target`/`dragover` 的 CSS 细节未逐一比对。
- `getSortableDelay()` 与移动端 750ms 延迟的实际触屏拖拽体验未实测。
- 扩展启停整页刷新的运行表现、PWA iOS 安全区适配均未运行验证。

## 10. 关键源码索引

`public/scripts/popup.js`、`public/scripts/action-loader.js`、`public/scripts/keyboard.js`、`public/scripts/dragdrop.js`、`public/scripts/BulkEditOverlay.js`、`public/scripts/chats.js`（880-970 行 expandMedia、1510、2392-2394）、`public/script.js`（347-365 toastr 配置、477-560 dragElement、824-828 动画时长）、`public/scripts/power-user.js`（主题应用与存储）、`public/css/mobile-styles.css`、`public/css/animations.css`、`public/css/loader.css`、`public/css/world-info.css`、`public/css/rm-groups.css`、`public/index.html`、`public/scripts/extensions.js`、`src/server-startup.js`。
