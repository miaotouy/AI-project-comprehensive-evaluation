# SillyTavern 通用界面盘点

> 来源文件：`../Chat/SillyTavern-Chat调查笔记.md` 第 13 节（2026-08-11 按类目边界原样摘出，未改动正文）
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 摘出日期：2026-08-11
>
> 说明：本节为通用界面基础设施盘点（弹窗库、Toast 系统、加载/空状态、右键菜单、主题、无障碍、响应式断点、动画、图片预览、拖放、扩展面板），不承担聊天主链细节；可选界面专题建立后整体迁入。

## 13. UI 交互再深挖：弹窗、状态反馈与无障碍

本节聚焦第 12 节没有覆盖的实现细节：弹窗系统内部机制、toastr 配置、加载/空状态、右键菜单、主题存储、无障碍现状、响应式断点、动画参数、图片预览、拖放导入、扩展面板结构。全部基于 `E:\works\git\SillyTavern` 同一快照（`8172dcd0e`）读码得出，逐条标注文件行号；查无实据的地方直接写"未找到"。

### 13.1 弹窗系统：原生 `<dialog>` + 自研 Popup 类，不是 jQuery UI Dialog

`public/scripts/popup.js`（全文已读，966 行）是整个弹窗系统的唯一实现。核心结论：**底层用的是浏览器原生 `<dialog>` 元素，不是 jQuery UI Dialog**，jQuery UI 在这里只用于别的组件（比如 `.sortable()`，见 13.10）。

- `Popup` 构造函数（`popup.js:195-236`）从 `#popup_template`（一个 `<template>`）克隆出 `.popup`（即一个 `<dialog>`），如果浏览器不支持 `showModal()`（`this.dlg.showModal` 为假）就用 `dialogPolyfill.registerDialog()`（`../lib/dialog-polyfill.esm.js`）打补丁，并挂一个 `ResizeObserver` 在 polyfill 场景下重新定位（`popup.js:237-248`）——这是专门为不支持原生 `<dialog>` 的旧浏览器准备的兜底。
- 弹窗类型是枚举 `POPUP_TYPE`：`TEXT`/`CONFIRM`/`INPUT`/`DISPLAY`/`CROP`（`popup.js:9-20`），`callGenericPopup(content, type, inputValue, popupOptions)`（`popup.js:909-917`）是最常用的对外入口，内部就是 `new Popup(...).show()`。`Popup.show.input/confirm/text` 三个静态帮助方法（`popup.js:106-146`）是更语义化的封装。
- **Esc 关闭行为**：默认 `allowEscapeClose: true` 时，`dlg` 的 `cancel` 事件被拦截并调用 `this.complete(POPUP_RESULT.CANCELLED)`（`popup.js:604-607`）。如果显式设为 `false`（用于"阻塞性"弹窗，比如生成中不该被随手关掉的弹窗），第一次 Esc 会被吞掉且不关闭，但有个**双击 Esc 强制关闭**的设计：500ms 内连续按两次 Esc 会弹出一个二级确认弹窗"Force-close Blocking Popup"，用户确认后才真正强制关闭（`popup.js:556-607`，注释里作者自称"Don't ask me why this is needed. I don't get it. But we have to keep it."，说明这段逻辑本身是踩过坑后留下的防御代码，而不是清晰设计）。
- **遮罩关闭**：原生 `<dialog>` 的 `showModal()` 自带背景层（`::backdrop`），但代码里**没有找到点击遮罩关闭弹窗的逻辑**——`cancelListener` 只绑定在 `cancel` 事件（即 Esc 键或部分浏览器的手势），没有额外绑定 `click` 事件判断点击目标是否为 `this.dlg` 本身来实现"点遮罩关闭"。也就是说，**点击弹窗外部区域不会关闭弹窗**，这是一个和很多现代 Web 弹窗库不同的行为选择,已核实（通读全文件未发现相关代码，且历史交互经验一致）。
- **焦点管理**：`setAutoFocus()`（`popup.js:700-733`）打开时把默认按钮或输入框设 `autofocus` 属性（依赖浏览器对 `showModal()` 内 autofocus 的原生支持）；关闭时通过 `focusin` 事件持续记录 `lastFocus`（`popup.js:538`），弹窗栈里如果还有更底层的弹窗，会把焦点还给它记住的 `lastFocus` 或重新调 `setAutoFocus()`（`popup.js:836-844`）——这是一套简单但明确的焦点归还机制,支持多层弹窗堆叠(`Popup.util.popups` 数组维护堆叠顺序,`popup.js:860-862`）。
- **拖拽/缩放**：Popup 本身**不可拖拽或缩放**——没有找到给 `.popup` dialog 绑定 `dragElement()` 或类似逻辑的代码。真正可拖拽缩放的是另一套完全独立的机制：`script.js` 里的 `dragElement($elmnt)`（`script.js:477-约560+`，"Make the given element draggable. This is used for Moving UI"），用于"Moving UI"这个把面板变成可拖拽浮窗的功能（拖拽头部 `.drag-grabber`、缩放靠 `actionType === 'resize'` 分支，位置和尺寸持久化进 `power_user.movingUIState[elmntName]`，`script.js:490-503`）。这套机制用在头像放大浮层（`.zoomed_avatar`，`script.js:12196-12219`）等场景，与 `Popup` 弹窗系统是两套并行、不共享代码的"可移动 UI"实现。

- **Enter 提交**：弹窗内 `keydown` 监听 Enter 键（`popup.js:623-664`），但有一套细致的守卫逻辑：如果焦点不在当前最上层弹窗内、焦点元素不是 `.result-control`、或者焦点在多行文本框内且没按 Ctrl，都不会触发提交——这是为了避免"在多行输入框里按 Enter 想换行，结果把弹窗提交了"的误触。

### 13.2 Toastr 通知：全局单例配置 + 弹窗内特殊定位处理

`toastr.options` 在 `public/script.js:347-365` 全局配置一次：位置 `toast-top-center`，无关闭按钮，无进度条，显示/隐藏动画各 250ms，普通提示 4000ms 自动消失，"扩展超时"（`extendedTimeOut`，鼠标悬停后重新计时用的时长）10000ms，显示/隐藏效果是 `fadeIn`/`fadeOut`，`escapeHtml: true`（提示文本按纯文本转义，防止 toast 内容被当 HTML 解析,即防 XSS）。用户可在设置里改 `power_user.toastr_position`（`power-user.js:1078`：`toastr.options.positionClass = power_user.toastr_position`），说明弹出位置是可配置项，不是硬编码死的。

一个专门的细节：toastr 默认渲染在 `document.body` 下，但如果当前有弹窗打开，toast 会被挡在弹窗（`<dialog>`）下面——因为原生 `<dialog>` 的模态层级高于普通 body 内容。`fixToastrForDialogs()`（`popup.js:934-966`）专门处理这个问题：检测当前最上层的 `dialog[open]:not([closing])`，把 `#toast-container` 移进这个 dialog 内部；弹窗关闭时再挪回 `document.body`。这个函数在 toastr 的 `onHidden` 回调（`script.js:360-364`）和 `Popup.show()`/`#hide()`（`popup.js:683, 817`）里都会被调用，用于保证"弹窗开着的时候通知消息也要显示在弹窗上层，不能被弹窗盖住"。

toastr 调用点极其分散：全仓库 86 个文件、988 处 `toastr.success/error/warning/info(...)` 调用（已用 grep 统计确认,未逐一验证每个触发场景），几乎每个功能模块（角色导入、正则、Quick Reply、TTS、World Info、预设管理等）都直接调 toastr，没有一个统一的"通知服务"包装层——这与 `Popup` 弹窗那样至少有个类封装的做法不同，说明 toastr 更像是被当作一个可以随处调用的全局工具库，而不是被抽象过的应用内 API。

代码里有个特殊行为：`tags.js:1910` 给标签导入结果的提示设置 `timeOut: toastr.options.timeOut * 2`（显示两倍时长），说明"重要/信息量大的提示要停留更久"这种差异化处理是存在的，但只是零星的个例覆盖，不是系统化的分级机制（比如没有"error 比 info 停留更久"这种全局规则，`toastr.error/warning/info/success` 四种全部共享同一个 `timeOut`，除非调用点自己传参覆盖）。

### 13.3 加载/空状态：三层不同的"loading"实现，互不复用

调查发现 SillyTavern 里"加载中"这件事至少有**三套独立实现**，服务不同场景，彼此没有共用代码：

1. **首屏 HTML 预加载层**（`public/index.html:52` 的 `<div id="preloader">`，样式在 `public/css/loader.css:1-17`）：纯 HTML+CSS，页面 HTML 一解析就存在，用来盖住"JS 还没跑完、样式还没套上"的一段空白期,毛玻璃模糊背景 `backdrop-filter: blur(30px)`。这个元素在首次隐藏统一 loader 后被 `yoinkPreloader()`（`action-loader.js:609-613`）移除，且只移除一次（`preloaderYoinked` 标志位防重复）。
2. **统一 Action Loader 系统**（`public/scripts/action-loader.js`，全文 617 行已读）：这是本次调查中发现的一个此前笔记完全没提到的、设计相当完整的子系统。`ActionLoaderHandle` 类同时管理"阻塞遮罩"（复用 `Popup` 的 `POPUP_TYPE.DISPLAY` 类型渲染一个 `transparent+wide+large+allowEscapeClose:false` 的弹窗当遮罩层，`action-loader.js:530-548`）和"可堆叠 toast"（`#createToast`，`action-loader.js:170-205`）。关键设计点：
   - **遮罩单例，toast 可堆叠**：多个耗时操作同时进行时，只显示一个遮罩（`hasBlockingLoaders()` 判断，`action-loader.js:63-70, 150`），但每个操作有自己独立的 toast 提示（可以同时看到"Generating title..."和"Downloading..."两条 toast）。
   - **toast 三种模式**（`ActionLoaderToastMode`：`NONE`/`STATIC`/`STOPPABLE`，`action-loader.js:23-30`）：`STOPPABLE` 模式的 toast 上带一个停止按钮（`fa-stop-circle`），点击调用 `onStop` 回调或默认的 `stopGeneration()`（`action-loader.js:270-286`）——这意味着"生成中"这个最常见的 loading 状态，用户可以直接从 toast 上点停止，不需要找专门的停止按钮。
   - toast 本身用 `toastr.info(...)` 渲染但 `timeOut: 0, extendedTimeOut: 0, tapToDismiss: false`（`action-loader.js:199-204`）——即这类 loading toast 不会自动消失，也不能点击手动关闭，只能通过代码调用 `hide()`/`stop()` 结束，这与普通提示 toast（4 秒自动消失、可点击关闭）的行为完全不同,是同一个 toastr 库上叠的两种不同交互模式。
   - 消费点确认：聊天重命名（`script.js:10616-10621`）、首次加载初始化（`script.js:719`）、`script.js:11221` 等处都调用 `loader.show()`，说明这是当前版本里"正在处理"反馈的标准做法,而不是每个功能自己拼一个 spinner。
3. **CSS 驱动的空状态占位**（无 JS 参与）：World Info 条目列表为空时靠纯 CSS 伪元素显示提示——`#world_popup_entries_list:empty::before { content: 'No entries found.'; ... }`（`public/css/world-info.css:64-约70`），群聊"添加成员"列表为空时用 `content: attr(no_characters_text)` 读取 HTML 属性里预先写好的文案（`public/css/rm-groups.css:118-119`，对应 HTML `<div id="rm_group_add_members" ... no_characters_text="No characters available">`，`public/index.html:6342`）。这是一种"零 JS 空状态"设计：容器本身没有子节点时，`:empty` 选择器命中,`::before` 用 CSS `content: attr(...)` 直接从自定义 HTML 属性读文案渲染出来,连文本节点都不需要 JS 插入。**但这个模式没有覆盖到主角色列表**（`#rm_print_characters_block`）——搜索未发现类似的 `:empty::before` 规则用在主角色列表容器上，说明"聊天角色列表完全为空时"这个场景目前**没有专门的空状态提示**（未找到对应实现，属于确认性的"未做"而不是"没找到"）。

"生成中"三个点的动画（`@keyframes ellipsis`，`public/css/animations.css:85-101`，`content` 从空到 `"..."` 循环变化）已在 CSS 里定义，但只在 grep 全仓库后**没有找到直接把这个 keyframe 挂到聊天区"角色正在输入"提示上的代码**——它更像是一个通用工具动画（可能给某些扩展或旧版本用），当前主聊天流的"正在生成"反馈实际上是走 Action Loader 的 toast + `data-generating="true"` 这个 body 属性驱动的 CSS（`style.css:4569`：`body:is([data-generating="true"], [data-swiping="true"]) :is(...)`控制哪些元素在生成/swipe 期间要禁用交互），而不是消息气泡里的三点动画。这与直觉（很多聊天应用有"对方正在输入…"的跳动省略号）不同,值得记录。`document.body.dataset.generating`（`script.js:7020, 7029`）确认是全局单一状态位，不是逐条消息级别的。

### 13.4 右键/上下文菜单：只在角色卡网格和 Quick Reply 按钮上存在，消息本身没有

消息 hover 操作栏（复制/编辑/删除等，已在第 12 节记录）之外，SillyTavern **没有给聊天消息本身做专门的右键上下文菜单**——全仓库搜索 `contextmenu` 事件监听，聊天消息 `.mes` 相关代码里没有绑定。真正实现了自定义右键菜单的是两个不相关的地方：

- **角色卡网格的长按/右键菜单**（`public/scripts/BulkEditOverlay.js`，`handleHold`/`handleLongPressEnd`，`571-607`）：在角色列表卡片上，`mousedown`/`touchstart` 触发 `handleHold()`，用 `setTimeout(..., BulkEditOverlay.longPressDelay)`（`longPressDelay = 2500`，`BulkEditOverlay.js:389`，即**长按 2.5 秒**）判断是否为长按；如果当前是"浏览"状态就切到"多选"状态，如果已经在"多选"状态再长按就弹出 `CharacterContextMenu`（批量标签/删除等操作）。同时该网格的每个卡片元素也监听原生 `contextmenu` 事件（`handleDefaultContextMenu`，`onPageLoad` 里绑定，`BulkEditOverlay.js:499`），已核实其实现（`BulkEditOverlay.js:558-563`）：只有 `this.isLongPress` 为真时才 `preventDefault + stopPropagation` 拦截浏览器默认菜单,否则放行——即只有真正触发了长按流程才会吞掉右键菜单，普通右键点击（比如想用浏览器自带的"检查元素"）不受影响。这套机制同时兼容鼠标右键和触屏长按，是特意为触屏做的手势适配。
- **Quick Reply 按钮的右键菜单**（`public/scripts/extensions/quick-reply/src/QuickReply.js:116-123`）：每个 Quick Reply 按钮如果 `hasContext`（配置了右键上下文动作）为真，点击右键会 `preventDefault + stopPropagation` 并弹出自定义菜单,而不是走 slash command 默认执行。

### 13.5 主题系统：服务端 JSON 存储 + CSS 变量注入,支持导入/导出但对 `@import` 有安全提示

主题不是简单的"深色/浅色"二元切换，而是一整套可配置的 CSS 变量集合：

- `power_user.theme`（默认值 `'Default (Dark) 1.7.1'`，`power-user.js:177`）标识当前选中主题名；实际颜色值都是 `--SmartThemeXxxColor` 系列 CSS 变量（`power-user.js:159-168` 列出了 `main_text_color`/`italics_text_color`/`blur_tint_color`/`chat_tint_color` 等十来个变量，初始值直接从 `getComputedStyle(document.documentElement)` 读出当前 CSS 里的默认值）。
- `applyTheme(name)`（`power-user.js:1227-约1430+`）遍历一个 `themeProperties` 数组（`1234-约1260`），把主题对象里的每个字段映射到对应的颜色选择器 DOM 元素和 `applyThemeColor`/`applyBlurStrength`/`applyCustomCSS` 等应用函数——**每次切换主题本质是批量调用 `document.documentElement.style.setProperty('--SmartThemeXxx', 值)`**（参见 `applyThemeColor`，`power-user.js:1104-1143`），不是切换 CSS 文件或加 `<link>`,是纯 CSS 变量运行时改写。
- **自定义 CSS**：`power_user.custom_css` 字段（`power-user.js:170`，默认空字符串）由 `applyCustomCSS()`（`power-user.js:1147-1157`）注入到一个 `<style>` 元素的 `innerHTML`，即**用户可以为任意选择器写任意 CSS 规则并持久化保存**，这是比"主题预设"更底层的自由度（相当于允许用户注入任意样式,理论上也可用来做视觉上的越权改动,但只影响用户自己客户端渲染,不涉及权限判断）。
- **主题导入的安全提示**：`importTheme(file)`（`power-user.js:2443-2476`）解析上传的主题 JSON,如果 `custom_css` 字段里包含 `@import` 字符串,会先弹出一个专门的警告弹窗（`themeImportWarning` 模板）要求用户确认才继续导入（`power-user.js:2459-2465`）——这是因为 CSS `@import` 可以从外部 URL 拉资源,官方特意对这种"看起来像主题文件、实际可能引入外部请求"的情况做了提示,而不是静默允许。是我在读代码前没预料到的一个具体安全考量点。
- **存储位置**：主题不是存在浏览器 `localStorage`,而是通过 `/api/themes/save`、`/api/themes/delete`（`power-user.js:2499, 2404`）等接口存到服务端（`src/server-startup.js:121, 148` 挂载 `themesRouter`），和聊天记录一样是"服务端持久化，多设备共享"的模型，这与很多纯前端应用"主题只存 localStorage"的做法不同。
- **深色/浅色系统偏好**：全仓库搜索 `prefers-color-scheme`，在 `public/` 范围内**没有找到**（唯一命中是第三方库 `lib/pdf.min.mjs`，与 SillyTavern 自身 UI 无关）。也就是说，**SillyTavern 不会自动跟随操作系统的深色/浅色模式设置**，主题完全由用户在设置里手动选择，已核实（全文 grep 无匹配，非推断）。

### 13.6 无障碍现状：有一套自建的"键盘可达性"框架，但语义化 ARIA 几乎缺失

这是本次调查里发现的最值得记录的反差点：**SillyTavern 没有大规模使用原生语义化 HTML（`<button>`）或 ARIA 属性，但专门写了一套 JS 层的键盘可达性 polyfill 来补偿**。

- **`aria-*` 属性几乎不存在**：对 `public/index.html`（主界面 HTML，几千行）grep `aria-` 只有 **1 处**命中——一个装饰性图标上的 `aria-hidden="true"`（`index.html:5733`）。对全部 `public/scripts/*.js` 搜索,只有 3 个文件各出现 1 次 `aria-*`/`role=`（`PromptManager.js`、`world-info.js` 各 1 处 `role="..."`，且都是把业务数据值(prompt 的 role 字段)写进 HTML 属性,不是无障碍语义的 `role`），实质上**没有找到任何专门为屏幕阅读器设计的 `aria-label`/`aria-describedby`/`role="button"` 等标注**（已核实，非推断,是全文 grep 的确定性结果）。
- **绝大多数"按钮"其实是 `<div>`/`<i>` 图标元素**：`index.html` 里有 245 处 `.menu_button` 相关的 `<div>`（grep 统计），而不是原生 `<button>`。原生 `<button>` 自带键盘 Tab 可达、Enter/Space 触发、屏幕阅读器识别为"按钮"角色，`<div>` 都没有,必须靠手工补。
- **补偿机制**：`public/scripts/keyboard.js`（全文 254 行已读）实现了一个"interactable"注册系统——维护一个 CSS 选择器白名单（`interactableSelectors`，`keyboard.js:2-28`，涵盖 `.menu_button`、`.mes_buttons .mes_button`、`.swipe_left/.swipe_right`、角色卡片等近 30 类元素），用 `MutationObserver` 监听 DOM 变化（`keyboard.js:46-58`），给匹配到的元素动态加 `tabindex="0"`（`makeKeyboardInteractable`，`keyboard.js:121-159`），并在 `document` 级别监听 `keydown`,收到 Enter 键就沿 DOM 树向上找最近的 interactable 元素并 `.click()`（`handleGlobalKeyDown`，`keyboard.js:213-234`）。这套系统**解决了 Tab 键可达和 Enter 键触发的问题**，但没有解决"屏幕阅读器该怎么念这个按钮"的问题——因为没有配套的 `role="button"`/`aria-label`，屏幕阅读器遇到一个 `<div tabindex="0">` 通常只会读出里面的文字内容（如果有的话）或者完全跳过（如果是纯图标 `<i class="fa-solid fa-xxx">` 没有文字）。
- **`title` 属性大量存在但不能替代 ARIA**：`index.html` 里有 595 处 `title="..."`（这些同时是鼠标悬浮提示,通过 `data-i18n="[title]..."` 支持多语言），可以被部分屏幕阅读器读出，但 `title` 属性的无障碍支持并不稳定（依赖屏幕阅读器和浏览器组合,不是标准做法),不能等价于 `aria-label`。
- **`tabindex` 硬编码点极少**：静态搜索 `index.html` 里手写 `tabindex="..."` 的只有 3 处（`switch_input_type_icon` 按钮设 `tabindex="-1"`，即刻意排除出 Tab 顺序；`mes_impersonate` 图标设 `tabindex="0"`），绝大多数可交互元素的 `tabindex` 是靠上面的 `keyboard.js` 运行时动态加的，不是写在 HTML 里的静态属性。
- **结论**（已核实，非推断）：SillyTavern 的无障碍现状是"键盘可用性中等（有专门框架保障 Tab/Enter），屏幕阅读器语义几乎没有"。这是一个明确、具体的缺失，不是极端说法——本次没有做实际的屏幕阅读器（如 NVDA/VoiceOver）测试，上述结论完全基于静态代码扫描，实际使用体验可能因浏览器/读屏软件的兼容性处理而有所不同,如实标注为**未做运行时验证**。

### 13.7 响应式/移动端适配：两个断点 + iOS 专属分支，没有触摸版 swipe 手势

响应式布局集中在 `public/css/mobile-styles.css`（全文 656 行已读），是**媒体查询驱动的桌面/移动布局切换**,不是响应式框架（无 Bootstrap/Tailwind 断点系统）：

- **主断点：`max-width: 1000px`**（`mobile-styles.css:2-508`，注释写明"catches ipads, horizontal phones, and vertical phones"）：这个断点下做了大量结构性改变——各设置面板列（如 `#UI-Theme-Block`/`#ContextSettings` 等）从桌面端并排布局改为 `flex-basis: 100%` 单列纵向堆叠（`mobile-styles.css:4-11`）；`body { touch-action: none; overflow: hidden; position: fixed; }`（`mobile-styles.css:250-254`，禁用默认触摸手势如双指缩放整页、锁定 body 不滚动,把滚动交给内部容器管理）；抽屉面板（`.drawer-content`）在此断点下改为 `position: fixed` 铺满 `100dvw`（`mobile-styles.css:260-269`）而不是桌面端的浮动面板。
- **横屏子断点**：`@media screen and (max-width: 1000px) and (orientation: landscape)`（`mobile-styles.css:511-534`）单独处理横屏手机/平板的头像放大层定位和 waifu 模式表情图裁剪方式。
- **竖屏窄屏子断点**：`@media screen and (max-width: 450px)`（`mobile-styles.css:537-580`）进一步收窄抽屉宽度比例（`.drawer25pWidth`/`.drawer33pWidth` 从 1/4、1/3 收窄成 1/2）。
- **iOS 专属分支**：`@supports (-webkit-touch-callout: none)`（`mobile-styles.css:583-656`，这是检测"是否为 WebKit/iOS Safari"的常见 hack，因为该 CSS 属性只在 iOS Safari 有意义）单独处理 `env(safe-area-inset-*)`（刘海屏安全区）留白，以及 PWA 模式下（`body.PWA`）的底部安全区内边距（`mobile-styles.css:610-615`）。这说明 SillyTavern 官方是把"作为 PWA 装到 iOS 主屏幕"当作一个被认真对待的使用场景来适配的，不只是"响应式网页"。
- **触摸手势方面的结论（已核实，是缺失而非猜测）**：全仓库搜索 swipe 相关代码 + `touchstart`/`touchmove`/`touchend` 事件绑定，**没有找到"在消息上左右滑动手指触发 swipe 切换候选回复"的触摸手势实现**。当前 swipe 功能在移动端的操作方式，是点击消息下方的 `<` `>` 箭头按钮（`.swipe_left`/`.swipe_right`，见第 12 节），这两个按钮本身在触屏上当然可以点击，但**"swipe"这个功能名字所暗示的手指滑动手势，实际并未实现**，无论桌面还是移动端都是点按钮。真正用到 `touchstart`/`touchmove`/`touchend` 的触摸交互场景只有三处：①滑动条（`<input type="range">`）触摸时锁定页面滚动 300ms（`script.js:11696-11711`，防止拖动滑块时手指误触发页面滚动）；②角色卡网格长按手势（见 13.4）；③头像放大层的关闭点击兼容 `touchend`（`script.js:12225`）。
- **`getSortableDelay()`**（`public/scripts/utils.js:358-364`）是一个直接体现"为触屏专门调参"的函数：桌面端拖拽排序（World Info 条目、Quick Reply 按钮等,`.sortable({ delay: getSortableDelay() })` 用法遍布 `world-info.js`、`tags.js`、`openai.js`、`textgen-settings.js` 等十余个文件）的触发延迟是 50ms，移动端（`isMobile()` 为真）则是 750ms——注释明确写"这是为了防止滚动页面时误触发拖拽"，这是一个具体的、体现了对触屏交互差异有认真考虑的实现细节。

### 13.8 动画/过渡效果参数补充

`public/css/animations.css`（全文 154 行已读）定义了一批可复用的 `@keyframes`：`fade-in`/`fade-out`（纯透明度）、`pop-in`/`pop-out`（透明度+垂直缩放，`pop-in` 在 0%-33% 就把 `scaleY` 拉到 1、后 67% 只调透明度，让"弹出感"更快出现,不是线性）、`flash`（0%/50%/100% 全透明度、25%/75% 降到 0.2，用于高亮闹一下的强调效果）、`pulse`（配合 `filter: brightness` 做发亮的呼吸效果）、`ellipsis`（三点省略号内容变化，见 13.3,当前未找到消费点）、`infinite-spinning`（匀速 360° 旋转，用在 `.PastChat_cross:hover` 让删除聊天的叉号 hover 时旋转,`style.css:4872-4875`，纯粹是装饰性 hover 反馈，与"加载"无关）、`slide`（依赖 CSS 变量 `--slide-mes-x-start/end` 做消息横向滑动，用于消息删除动画的位移方向可由 JS 动态指定起止点）。

全局动画时长由 `ANIMATION_DURATION_DEFAULT = 125`（毫秒，`script.js:595`）驱动的 `--animation-duration` CSS 变量控制（`setAnimationDuration()`，`script.js:824-828`），用户可在设置里改这个值（变量名指向 `power_user` 相关设置，本次未深入具体设置项 UI 绑定,但确认了运行时改变机制存在）；抽屉展开/收起在"已有其它抽屉打开"时会先等待 `animation_duration` 毫秒再切换当前抽屉状态（`doNavbarIconClick()`，`script.js:10908-10910`），避免多个面板同时做开合动画造成视觉混乱。这与第 12 节已经记录的 `stream-fadein.js`（流式消息淡入,用 `morphdom` + `Intl.Segmenter`）是两个不同层面的动画机制：一个管"面板级"的开合过渡，一个管"文本级"的逐词淡入。

### 13.9 图片/附件预览：弹窗承载的简易灯箱，支持点击放大但无手势缩放

消息里的图片/视频附件点击后的"放大查看"实现是 `expandMedia`（对应函数体在 `chats.js:880-970`，已读全文）,复用的是 13.1 提到的同一套 `Popup` 弹窗系统,不是独立的灯箱库：

- 弹窗类型是 `POPUP_TYPE.DISPLAY`（只有关闭 X,没有 OK/Cancel 按钮），额外传 `{ large: true, transparent: true }`（`chats.js:960`）,让弹窗铺大、背景透明,只剩内容本身。
- **点击放大/还原**是纯 class toggle，不是真正的图像缩放引擎：点击图片本体切换 `.zoomed` class（`chats.js:941-945`），CSS 侧 `.img_enlarged`（未 zoomed）用 `object-fit: contain`+`cursor: zoom-in`，`.img_enlarged.zoomed` 切到 `object-fit: cover` 并允许滚动查看（`style.css:5305-5319`，`.img_enlarged_holder:has(.zoomed) { overflow: auto; }`）——即"放大"实际上是从"缩小以适应容器"切换到"按原始比例填充,可能超出容器需要滚动查看",而不是插值放大或支持拖拽平移/滚轮缩放的真正图像浏览器手势。
- 视频走同样弹窗但换成 `<video controls autoplay>`（`chats.js:913-919`），音频类型媒体**明确不支持展开**（`chats.js:896-898`：`if (mediaAttachment.type === MEDIA_TYPE.AUDIO) { console.warn('Audio media cannot be expanded'); return; }`）。
- 点击弹窗本身背景关闭（`popup.dlg.addEventListener('click', () => popup.completeCancelled())`，`chats.js:964-966`）——注意这与 13.1 提到的"Popup 系统本身不支持点遮罩关闭"并不矛盾：这里是 `expandMedia` 自己在弹窗内容层手动加了一个点击关闭的监听，是调用方主动加的行为，不是 `Popup` 类内建能力。
- 有标题的媒体会用 `<pre><code>` 渲染附加说明文字（`chats.js:947-957`），且这段代码专门 `stopPropagation` 阻止点击标题时触发放大/还原的 toggle 或误关闭弹窗。
- **另一套独立的图片查看器**：桌面端角色卡/用户头像放大用的是 `jquery.izoomify`（`public/lib/jquery.izoomify.js`，`script.js:12221-12223` 调用 `$('.zoomed_avatar_container').izoomify()`），这是鼠标悬停放大镜式的局部放大（跟随鼠标位置放大局部区域），仅在 `power_user.zoomed_avatar_magnification` 开启时生效，且这套放大镜效果依赖 `mouseover`/`mousemove`（`jquery.izoomify.js:144-147`）——**在纯触屏设备上，悬停放大镜这个交互模式基本不可用**（该库虽然也监听了 `touchstart`/`touchmove`，但放大镜跟随鼠标位置的交互模式在触屏上体验和桌面端会有本质差异，本次未做触屏实机验证，标注为**未核实的实际触屏体验**）。这是与聊天消息内嵌图片预览（`img_enlarged`）完全不同的第三套图像交互实现，三者（消息图片弹窗、头像放大 izoomify、头像拖拽浮层 `dragElement`）分别服务不同场景,没有整合成统一的"图片查看器"组件。

### 13.10 拖放细节：两类拖拽，机制不同

拖放交互在这次调查里发现分为两类完全不同的实现，此前笔记未涉及：

**A. 文件拖入导入（`DragAndDropHandler` 类，`public/scripts/dragdrop.js`，全文 107 行已读）**——一个通用的、可复用的拖拽区域封装：构造时传入 CSS 选择器和回调，内部用 jQuery 事件委托在 `document.body` 上监听 `dragover`/`dragleave`/`drop`（而不是直接绑定到目标元素本身,这样即使目标元素后续被重新渲染替换也不会丢失监听,`dragdrop.js:52-65`）；`dragleave` 用 `debounce_timeout.quick` 做了去抖（`dragdrop.js:87-91`，注释明确写"防止拖拽略过内部子元素边界时闪烁"）。全仓库有 4 个消费点：
  - 角色卡拖入导入：`charDragDropHandler = new DragAndDropHandler('body', ...)`（`script.js:12494-12499`，`{ noAnimation: true }`），拖放整个页面任意位置都能触发，内部区分"是文件"走 `processDroppedFiles()`（`script.js:10401-10434`，按 MIME/扩展名白名单——`application/json`、`image/png`（角色卡通常是打了 PNG tEXt 元数据的头像图）、YAML、`.charx`、`.byaf` 允许，其它类型 `toastr.warning` 拒绝）还是"是外部 URL"（拖动浏览器地址栏文字或图片链接时走 `importFromURL`，处理 `dataTransfer.items`）。
  - 聊天记录导入：`chatDragDropHandler = new DragAndDropHandler('#select_chat_popup', ...)`（`script.js:12501-12507`），把拖入的文件塞进隐藏的 `<input type="file">` 再触发 `change` 事件复用已有的文件选择逻辑，而不是另写一套处理逻辑。
  - 附件拖入弹窗：`chats.js:1510`（在 Data Bank / Attachment Manager 弹窗内,`.popup` 选择器,拖入后弹出目标选择器让用户选这个文件挂到全局/角色/聊天哪个作用域）。
  - 消息输入框拖入：`chats.js:2392-2394`（`#form_sheld` 选择器，拖文件到发送框直接走 `handleFileAttach`，等同于用文件选择器上传附件）。
  - 拖拽悬停视觉反馈统一由 CSS class `drop_target`/`dragover` 驱动（`dragdrop.js:75, 90, 102`），意味着所有这些拖放目标共享同一套视觉语言（具体动画效果由各自 CSS 定义，本次未逐一比对每个 `drop_target` 的 CSS 细节）。

**B. World Info / Quick Reply 等列表的拖拽排序（jQuery UI `.sortable()`）**——与上面文件拖入完全是另一套机制,用的是 `public/lib/jquery-ui.min.js` 的 `sortable` 插件（不是 SortableJS，也不是自己撕写的实现）。World Info 条目排序（`world-info.js:2576-2580`）：`items: '.world_entry', delay: getSortableDelay(), handle: '.drag-handle'`——`handle` 限定只有拖着专门的把手图标（`.drag-handle`）才能拖动整行，防止用户想选中文字/点开输入框结果不小心拖走了整个条目。同样的 `.sortable({ delay: getSortableDelay(), handle: ... })` 模式在 Quick Reply 按钮排序（`QuickReply.js:1007`、`QuickReplyConfig.js:70`）、正则规则排序（`regex/index.js:1177-1932`,多个作用域列表：全局/局部/预设级正则规则各自可独立排序）、采样器参数排序（`textgen-settings.js`/`nai-settings.js`/`kai-settings.js`/`openai.js`/`logit-bias.js`/`tags.js` 等十余处）里反复出现——这是一个统一透过 `getSortableDelay()` 共享"移动端延迟更长"这一参数的模式,但排序功能本身分散在各个模块各自初始化,没有一个集中的"可排序列表"组件封装（每处都是独立调用 `.sortable({...})`,配置参数相似但代码不共享）。

### 13.11 扩展面板（Extensions panel）结构与交互

Extensions 抽屉本身（`#rm_extensions_block`，`index.html:5741`）结构是**一串固定 ID 的空容器 `<div>`**（`#extensions_settings` 下挂 `#assets_container`/`#typing_indicator_container`/`#expressions_container`/`#sd_container`/`#tts_container` 等二十多个,`index.html:5760-5780+`），每个容器对应一个具体的内置扩展模块，模块自己的 `index.js` 在初始化时把自己的设置 UI（通常是 `renderExtensionTemplateAsync` 渲染的模板）塞进对应容器——**面板本身不是动态生成扩展列表，是预先在 HTML 里开好每个已知内置扩展的"坑位"**，第三方扩展则走另一条路径（见下）。

第三方/外部扩展的管理入口不在这个抽屉里，而是点击输入框旁的"魔法棒"图标（Wand，`addExtensionsButtonAndMenu()`，`extensions.js:688-723`）弹出一个用 `Popper.js` 定位的下拉菜单（`#extensionsMenu`，`placement: 'top-start'`，`extensions.js:699-701`），点击外部区域（且不在白名单 `#sd_gen`/`#extensionsMenuButton`/`#roll_dice` 内）会自动收起（`extensions.js:714-722`）。这个菜单聚合了各扩展贡献的快捷操作项（比如 Stable Diffusion 的生成按钮、掷骰子命令等），跟"扩展设置面板"（在抽屉里配置扩展参数）是两个不同的 UI 概念：**魔法棒菜单是"扩展提供的快捷动作入口"，Extensions 抽屉是"扩展的详细设置面板"**。

扩展的启用/禁用交互：`.extension_block` 上有 `.extension_toggle` 内的 `<input>`（复选框，`extensions.js:928, 1225, 1243`），勾选/取消勾选触发 `enableExtension(name)`/`disableExtension(name)`（`extensions.js:473-500`）。关键细节：**启用或禁用扩展默认会导致整页刷新**（`location.reload()`，`extensions.js:479, 496`）——两个函数都接受 `reload` 参数为 `false` 来跳过刷新（这种用法出现在"批量切换扩展"场景,`extensions.js:1218-1243` 的 `toggleAllExtensionsButton` 点击处理里,累积多个切换后统一走 `requiresReload = true` 标记,等用户主动确认后才刷新一次,而不是切一个刷一次）。这说明单个切换和批量切换在交互上是刻意区分的：零散地在设置里点开关一个扩展会立刻整页刷新生效；管理员批量启停第三方扩展列表时,系统会推迟刷新,给用户攒够操作后一次性生效的机会。

第三方扩展列表弹窗（`extensions.js:1150-1183` 一带涉及的更大的"Manage Extensions"弹窗，不同于魔法棒下拉菜单）区分"默认容器"和"外部容器"两组展示，第三方扩展列表加载时会先显示一个 `fa-spin` 转圈图标+"Loading third-party extensions... Please wait..."提示（`extensions.js:1156-1164`），并提供"Update all"/"Update enabled"两个批量更新按钮（各自调 `autoUpdateExtensions(force)`，`extensions.js:1186-1203`）和一个"Toggle extensions"批量切换按钮（`extensions.js:1205-1219`，配一个仅在有历史批量操作记录时才显示的"Restore toggled extensions"还原按钮，`extensions.js:1214-1216`，`displayNone` 默认隐藏）。列表排序支持按名称或按 manifest 声明顺序切换（`sortByName`/`sortManifestsByOrder`，`extensions.js:1166-1169`，排序偏好存在 `accountStorage`，即浏览器本地存储,不是服务端设置）。
