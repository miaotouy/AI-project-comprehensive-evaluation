# SillyTavern 应用界面基础设施调查笔记

> 调查对象：`E:\works\git\SillyTavern`
>
> 调查更新日期：2026-08-13
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配和公共实现入手，抽样核对业务消费方；依赖内部行为和运行表现单独标注
>
> 调查范围：应用装配、弹窗与浮层、通知与错误反馈、主题、响应式、常见内容交互及项目特有的界面基础设施；聊天业务主链由相邻类目笔记承接
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

SillyTavern 主要使用原生 Web 技术和项目自研机制。弹窗基于浏览器 dialog 与自研 Popup，点击遮罩不会关闭；通知统一调用 toastr，但调用点分散，没有项目级门面。另有 Action Loader 处理阻塞任务和带停止按钮的进度提示。

主题存于服务端 JSON，并在运行时改写 CSS 变量，不跟随系统深浅色。背景图库是独立的大型子系统，支持全局与聊天级背景、目录分组、动画背景、自动选择和基于背景图生成配色。项目没有主题市场、字体族设置或 light/dark 双变体主题。

无障碍机制更侧重键盘路径，屏幕阅读器语义覆盖有限。本次没有找到全局错误边界或用户可见的渲染崩溃兜底；启动失败主要依靠有限次数的页面重载，首屏颜色则使用静态默认 token 过渡到服务端设置。

## 系统边界与总体装配

**界面栈。** 原生 HTML + 手写 JS（jQuery 辅助），无前端框架；界面组件以 public/index.html 静态模板和 public/scripts/*.js 事件绑定为主，样式在 public/css/。

**弹窗系统。** public/scripts/popup.js（966 行）是唯一弹窗实现，#popup_template 模板克隆 .popup（即 dialog 元素）。

**全局状态。** 大量状态存在 power_user 设置对象（主题名、toastr 位置等）与服务端接口（主题、聊天记录）；“生成中”是 document.body.dataset.generating 全局单一状态位（script.js:7020, 7029），不是逐消息级别。

## 1. 界面栈、公共组件与状态所有权

**弹窗组件。** Popup 类（popup.js:195-236）定义 POPUP_TYPE 枚举及五种类型：TEXT、CONFIRM、INPUT、DISPLAY、CROP（popup.js:9-20）；callGenericPopup（popup.js:909-917）是常用入口，Popup.show.input/confirm/text 是语义化封装（popup.js:106-146）。

**浏览器兼容兜底。** 不支持 showModal() 时用 dialogPolyfill.registerDialog()（../lib/dialog-polyfill.esm.js）打补丁，并挂 ResizeObserver 在 polyfill 场景重新定位（popup.js:237-248）。

**toastr 是全局工具库。** 全仓库 86 个文件、988 处 toastr 四种提示方法调用（grep 统计，未逐一验证每个触发场景），几乎每个功能模块直接调用，无统一“通知服务”包装层——与 Popup 有类封装的做法不同。
- **Action Loader 子系统**（public/scripts/action-loader.js，617 行）：“正在处理”反馈的标准做法，ActionLoaderHandle 同时管理阻塞遮罩（复用 Popup 的 DISPLAY 类型渲染透明、宽屏、大尺寸且不允许 Esc 关闭的弹窗，action-loader.js:530-548）与可堆叠 toast（创建提示的逻辑见 action-loader.js:170-205）。

  消费点：聊天重命名（script.js:10616-10621）、首次加载初始化（script.js:719）、script.js:11221 等。

## 2. 弹窗、浮层与菜单

**弹窗系统**（public/scripts/popup.js，全文已读，966 行）：底层是浏览器原生 dialog 元素，不是 jQuery UI Dialog（jQuery UI 只用于 sortable 等组件）。

**Esc 关闭。** 默认允许 Esc 关闭时拦截 cancel 事件并完成取消结果（popup.js:604-607）。

显式 false（阻塞性弹窗）时首次 Esc 被吞，但**双击 Esc 强制关闭**：500ms 内连按两次会弹出"Force-close Blocking Popup"二级确认弹窗，确认后才强制关闭（popup.js:556-607，注释自嘲"Don't ask me why this is needed. I don't get it. But we have to keep it."）。

**遮罩关闭。** showModal() 自带 ::backdrop，但代码里没有点击遮罩关闭的逻辑——cancelListener 只绑 cancel 事件，无 click 目标判断。**点击弹窗外部区域不会关闭弹窗**，已核实（通读全文件未发现相关代码，且历史交互经验一致）。

**焦点管理。** setAutoFocus()（popup.js:700-733）打开时给默认按钮或输入框设 autofocus；关闭时持续记录最近焦点（popup.js:538），弹窗栈中还有更底层弹窗时把焦点还给它，或重新执行自动聚焦（popup.js:836-844）。Popup.util.popups 数组维护堆叠顺序（popup.js:860-862），因此支持多层堆叠。

**拖拽/缩放。** Popup 本身不可拖拽缩放；另一套独立的 dragElement() 用于“Moving UI”，可把面板变成可拖拽浮窗，位置和尺寸持久化到 power_user.movingUIState（script.js:477-约560）。它用于头像放大浮层等场景，两套“可移动 UI”实现并行且不共享代码。

**Enter 提交。** 弹窗内监听 keydown 的 Enter（popup.js:623-664）；当焦点不在最上层弹窗、不是 result-control，或位于多行文本框且未按 Ctrl 时不触发，避免多行输入换行误提交。

**右键/上下文菜单**（全仓库搜 contextmenu，聊天消息 .mes 无绑定，只有两处）：

- **角色卡网格长按/右键菜单**（public/scripts/BulkEditOverlay.js）：mousedown/touchstart 触发 handleHold()，通过延时计时判定长按（BulkEditOverlay.js:389）；浏览态长按切多选，多选态长按弹 CharacterContextMenu（批量标签/删除）。

  原生 contextmenu（`BulkEditOverlay.js:499,558-563`）只有 isLongPress 为真才 preventDefault + stopPropagation，普通右键放行——兼容鼠标右键和触屏长按的手势适配。
- **Quick Reply 按钮右键**（extensions/quick-reply/src/QuickReply.js:116-123）：配置了右键上下文动作时拦截并弹自定义菜单。

## 3. 通知、加载态与错误反馈

**Toastr 全局配置**（public/script.js:347-365）：位置为 toast-top-center，无关闭按钮和进度条，显隐动画 250ms，普通提示 4000ms，延长时长 10000ms，并启用 HTML 转义（防 XSS）。位置可在设置里改（power_user.toastr_position，power-user.js:1078）。

fixToastrForDialogs()（popup.js:934-966）检测最上层打开且未关闭的 dialog，把 #toast-container 移进其中，关闭时再移回 document.body；这样解决原生 dialog 模态层级高于 toast 的问题。该处理在提示隐藏和 Popup 显隐时调用（script.js:360-364；popup.js:683, 817）。

差异化处理是零星的：tags.js:1910 给标签导入结果设置两倍提示时长，但 error、warning、info、success 四种提示共享同一时长，无系统化分级。

**加载/空状态是三层独立实现，互不复用**：

1. **首屏 HTML 预加载层**（index.html:52 的 preloader 容器，样式见 css/loader.css:1-17）：纯 HTML+CSS，使用 30px 模糊效果盖住 JS 未跑完的空白期；首次隐藏统一 loader 后由 yoinkPreloader() 移除，标志位防重复（action-loader.js:609-613）。
2. **Action Loader 系统**（action-loader.js）：遮罩是单例（hasBlockingLoaders()，action-loader.js:63-70, 150），每个操作有独立 toast，可同时看到多条。

toast 三种模式（ActionLoaderToastMode：NONE、STATIC、STOPPABLE，action-loader.js:23-30），STOPPABLE 带停止按钮，点击后调用 onStop 或默认的停止生成逻辑（action-loader.js:270-286），“生成中”可直接从 toast 上点停止。

这类 loading toast 用 toastr.info 渲染，但关闭时长为零且禁止点击消失（action-loader.js:199-204），不自动消失也不能手动关，只能由代码结束；它与普通提示 toast 共用同一库，却是两种不同交互模式。
3. **CSS 驱动的空状态占位**（零 JS）：World Info 条目列表空时 `#world_popup_entries_list:empty::before { content: 'No entries found.'; }`（`css/world-info.css:64-约70`）；

群聊添加成员列表空时 content: attr(no_characters_text) 读 HTML 属性文案（`css/rm-groups.css:118-119`，`index.html:6342`）——:empty 命中后 `::before` 用 content: attr(...) 直接渲染，无需 JS。

但主角色列表 `#rm_print_characters_block` **没有**类似规则——"角色列表完全为空"没有专门空状态提示（已核实为"未做"而非"没找到"）。

"生成中"三点动画（@keyframes ellipsis，`css/animations.css:85-101`）在 grep 全仓库后未找到挂到聊天区"角色正在输入"的代码——当前主聊天流的生成反馈是 Action Loader toast + `body[data-generating="true"]` 驱动的 CSS（`style.css:4569`），不是气泡内三点动画。

**应用级错误边界（必查问题 3，本次补充调查）**：

**无全局 JS 错误钩子。** 在 `public/script.js` 与 `public/scripts/`（排除 `lib/`、`extensions/*/lib/` 与 `*.min.js` 第三方打包）搜索 window.onerror / unhandledrejection / addEventListener('error'|'unhandledrejection')，应用代码无匹配；

唯一命中 `script.js:1543, 1551` 是 `scrollOnMediaLoad()`（`script.js:1532-1566`）给聊天内 `<img>`/`<video>`/`<audio>` 挂的加载失败计数——图片/媒体加载失败也算"加载完"继续滚到底部，属单点行为，不是全局错误边界。

**启动失败恢复而非渲染兜底。** getSettings() 请求失败时进入 reloadLoop()（script.js:7862-7866）：toastr.error 提示 + sessionStorage 计数最多 5 次 location.reload()（script.js:7842-7850），5 次后不再重载（超限后表现未运行验证）。

**preloader 无错误状态。** `#preloader`（`index.html:52`，`css/loader.css:1-17`）是纯 CSS 动画占位层，本次未找到失败态文案、重试入口或"加载失败→显示错误页"的分支；`index.html` 全文也无 `<noscript>` 兜底。

**服务端进程级处理与界面无交集。** process.on('uncaughtException')（src/server-main.js:332-335）只做 console.error 后调 exitProcess() 优雅退出（server-main.js:317-327：统计落盘、插件清理、diskCache 释放后 process.exit()），没有重启或界面可感知的错误页；

`src/` 搜索 process.on 仅命中 SIGINT/SIGTERM/uncaughtException/exit 四处，**无 unhandledRejection 处理**（本次未找到，非项目级绝对结论）。
- 结论：类似前端框架 ErrorBoundary 的"渲染错误兜底 UI"本次未找到；错误反馈的承载方式是 toastr（见本节约 988 处统计），业务异常由各调用点自行 try/catch + toast 提示（如生成主链 `finishGenerating().then(onSuccess, onError)`，`script.js:5394`，主链细节归 Chat UI 笔记）。

## 4. 主题、视觉 token 与持久化

主题不是简单深浅二元切换，而是可配置的 CSS 变量集合：

- power_user.theme（默认 'Default (Dark) 1.7.1'，power-user.js:177）标识选中主题；

  颜色值是 --SmartThemeXxxColor 系列变量（power-user.js:159-168，main_text_color、italics_text_color、blur_tint_color、chat_tint_color 等十来个，全集与派生 token 见下文），初始值从 getComputedStyle(document.documentElement) 读出。
- applyTheme(name)（power-user.js:1227-约1430+）遍历 themeProperties 数组，

  把每个字段映射到颜色选择器 DOM 与多个应用函数——切换主题本质是批量改写 document.documentElement 的 CSS 变量（applyThemeColor，power-user.js:1104-1143），纯 CSS 变量运行时改写，

  不是切换 CSS 文件。

**自定义 CSS。** power_user.custom_css（power-user.js:170）由 applyCustomCSS()（power-user.js:1147-1157）注入 style 元素的 innerHTML，用户可为任意选择器写任意规则并持久化。

**主题导入安全提示。** importTheme(file)（`power-user.js:2443-2476`）解析上传的主题 JSON，若 custom_css 含 `@import` 字符串先弹 themeImportWarning 警告弹窗确认才继续（`power-user.js:2459-2465`）——防"看起来像主题文件、实际从外部 URL 拉资源"。

**存储位置。** 通过 /api/themes/save、/api/themes/delete（power-user.js:2499, 2404）存到服务端（src/server-startup.js:121, 148 挂载 themesRouter），和聊天记录一样"服务端持久化、多设备共享"，不是 localStorage。

**系统偏好跟随。** public/ 范围内全仓库搜索 prefers-color-scheme **无匹配**（唯一命中是第三方库 lib/pdf.min.mjs）——**不自动跟随 OS 深浅色**，主题完全手动选择，已核实（全文 grep 无匹配，非推断）。

**首帧主题与防闪烁。** 启动时先取得设置，把 power_user 合入全局对象，再批量应用颜色、模糊和自定义 CSS。主题列表随设置响应返回，主题端点只负责保存和删除，没有独立读取路由。（`script.js:750,7911`；`power-user.js:1475-1606`）

**启动阶段不调用 applyTheme(name)**——该函数只在 4 个交互/命令点触发：删除主题后（`power-user.js:2423`）、背景图生成主题后（:2945）、ST Script setTheme（:2975）、设置页下拉切换（:3511），主题切换总是先写 power_user.* 并 `saveSettingsDebounced()` 持久化，下次启动直接应用持久化值。

首帧兜底：`style.css:70-82` 的 :root 静态 `--SmartTheme*` 默认值（注释 "Default Theme, will be changed by ToolCool Color Picker"）在 JS 改写前生效，power_user 的颜色默认值也是从 getComputedStyle 读这套 CSS 变量（`power-user.js:159-168`）——静态 CSS 本身就是 "Default (Dark)" 观感；

`index.html:14-19` 内联 `<style>` 仅一条 `body { background-color: rgb(36, 36, 37); }`（另有 `meta name="theme-color" content="#333"`，`index.html:13`），**无内联主题应用脚本**，所以"主题闪烁"窗口只存在于默认主题到用户主题之间的颜色改写瞬间，无"先亮后黑"的换肤式首帧。

**主题文件格式与字段全集（本次补充核对）**：

**主题即 JSON 文件列表，无数据库。** 内置主题在 default/content/themes/（当前快照 5 个：Dark V 1.0.json、Dark Lite.json、Celestial Macaron.json、Cappuccino.json、Azure.json），用户目录同理；

`/api/settings/get` 用 readAndParseFromDirectory(request.user.directories.themes) 直接扫目录读全部 JSON（`src/endpoints/settings.js:259, 279`），保存/删除就是 `themes.js` 的 save/delete 两个 POST 原子写/删文件（write-file-atomic）。
- **主题字段**：除 name 外共有 38 个键，包括 10 个颜色、4 个尺寸或强度值、自定义 CSS 和 23 个行为或显示开关。主题文件因此不只是色板，也会打包消息显示、Toast 位置、动画、输入区和编辑行为等界面偏好。（`power-user.js:2535-2578`）

  内置 `Dark V 1.0.json` 只存了其中 36 个，缺 click_to_edit/media_display/show_swipe_num_all_messages 三个较新的键）。导入时 getNewTheme（`power-user.js:2585-2593`）**只把白名单内已知键合并进当前设置快照，未知键一律丢弃**——比 `@import` 检查更深一层的净化（坏字段不会污染设置）。
- **主题 UI 是五个操作按钮 + 下拉**（index.html:4916-4936）：导入（importTheme，含 @import 警告与重名拒绝）、导出（exportTheme）、删除（deleteTheme，删除后自动回落到列表第一个主题并应用，

  power-user.js:2415-2424）、**更新当前主题文件**（updateTheme→saveTheme(power_user.theme) 覆盖保存，power-user.js:2384-2387）、**另存为新主题**（saveTheme() 无参时弹 INPUT 弹窗取名字，power-user.js:2484-2493）。

**字号、字体族与阴影 token（本次补充核对）**：

- 字号是全站派生链不是单点：power_user.font_scale（0.5-1.5 滑块，`index.html:5048-5049`）→ applyFontScale 写 `--fontScale`（`power-user.js:1172-1185`，滑块拖动时只在 mouseup touchend 才应用，

  避免实时重排）→ `--mainFontSize: calc(var(--fontScale) * 15px)`（`style.css:95-96`）→ 全站几十处 `calc(var(--mainFontSize) * …)` 派生字号（`tags.css`/`welcome.css`/`st-tailwind.css` 等十多个 CSS 文件）。

**字体族硬编码、无自定义字体设置。** `--mainFontFamily: "Noto Sans", sans-serif` 与 `--monoFontFamily`（`style.css:97-98`）写死在 CSS，grep customFont/font_family 于 `public/scripts/` 无匹配——用户只能缩放字号，不能换字体。
- 阴影基变量：`--blurStrength`（默认 10）与 `--shadowWidth`（默认 2）在 `style.css:101-104`，由 applyBlurStrength/applyShadowWidth 改写（`power-user.js:1160-1170`）；

  全局通配规则 `* { text-shadow: 0px 0px calc(var(--shadowWidth) * 1px) var(--SmartThemeShadowColor); }`（`style.css:140`）把"文本阴影"做成全站统一 token。

**`--SmartTheme` 变量全集与派生 token（本次补充核对）**：

- 静态默认定义在 `public/style.css:70-89`（注意是 `public/style.css` 根文件，不是 `public/css/` 子目录）：除笔记前述十来个颜色外，还有 `--SmartThemeCheckboxBgColorR/G/B` 与**亮度派生的勾选色** `--SmartThemeCheckboxTickColorValue`/`--SmartThemeCheckboxTickColor`（按主文本色亮度公式自动算黑白勾选色，`style.css:83-89`）——主题切换时 applyThemeColor('main') 把主文本色的 RGBA 分量解析写入（`power-user.js:1105-1111`）；

  `--SmartThemeFastUIBGColor` 在 CSS 与 JS 中都是注释掉的死代码（`style.css:75`、`power-user.js:1122-1124`）。
- applyThemeColor('blurTint') 还同步改写 `meta[name=theme-color]`（`power-user.js:1126-1128`）——浏览器标签页主题色跟随 UI 背景色（静态默认 `#333` 只在 JS 未跑时生效）。

**背景图库子系统（本次补充核对，此前笔记完全未记录）**：背景图是独立于主题色的一层视觉机制，实现规模与弹窗系统同级：

**承载。** `#bg1` 是 z-index: -1 的全屏背景图层（`css/backgrounds.css:2-11`），background_settings（`backgrounds.js:108-114`：name/url/fitting/animation/sortOrder/thumbnailColumns）持久化在 settings.background（服务端 settings，

非 power_user），选中背景 setBackground 改 `#bg1` 的 background-image 并 saveSettingsDebounced（`backgrounds.js:1439-1447`）。

**双来源 tab。** BG_SOURCES.GLOBAL（服务器 `backgrounds/` 目录）与 BG_SOURCES.CHAT（当前聊天的自定义背景列表，存 chat_metadata.chat_backgrounds）各自渲染缩略图网格（`backgrounds.js:661-706`）；

**聊天级锁定**：chat_metadata.custom_background 锁定后全局背景变更不再生效（`backgrounds.js:1440-1443`），提供 lockbg/unlockbg 斜杠命令（:1813-1830）。

**4 种 fitting。** cover/contain/stretch/center 是 `#bg1` 的 class 切换（`backgrounds.js:1632-1638`，CSS 在 `backgrounds.css:19-41`），默认 classic（无任何 fitting class，走 `backgrounds.css:2-11` 的基础 background-size: cover）。

**缩略图工程。** `--bg-thumb-columns` 列数（2-8 可调，`backgrounds.js:200-209`）、IntersectionObserver 懒加载（:1357-1396）、localforage 缩略图缓存（:42, 431-465）、服务端图片元数据（`/api/image-metadata/all` 的 dominantColor/aspectRatio 做加载占位，:740-759）。

**动画背景。** mp4/webp/gif/apng 视为动画背景（:55），开关 background_settings.animation 决定用静态缩略图还是动图（:1430-1434）。

**文件夹分组。** `/api/image-metadata/folders/*`（create/update/delete/set-thumbnails）管理背景文件夹，支持批量选中分配/移除、封面图（`backgrounds.js:764-1355`）。

**autobg AI 自动选背景。** 把背景名列表喂给模型，用 Fuse 模糊匹配选中（`backgrounds.js:622-655`）。

**bgcol 背景图配色生成主题。** 斜杠命令（`power-user.js:2890-2949`，注册于 :4194-4216）取当前背景图 → `util/ThemeGenerator.js`（322 行，全文已读）用 Oklch 色空间提取主色（chroma² 加权平均 + 循环色相平均，150px 降采样，

extractDominantColor）→ generateThemePalette 生成 12 字段调色板（互补/类似/三色色相关系 + 逐点迭代保证对面板背景 WCAG 对比度 ≥3.5:1，`ThemeGenerator.js:225-300`）→ 存为 `bgcol - <背景名>` 新主题并应用。
- 服务端点：`/api/backgrounds/all|folders|delete|rename|upload`（`src/endpoints/backgrounds.js`）与 `/api/image-metadata/*`（`src/endpoints/image-metadata.js`）。

**本次未找到（检查范围：`public/index.html` 全文 + `public/scripts/` 全部源码 + `public/css/` + 主题 JSON 字段全集）**：

**主题市场/官方主题库下载入口。** grep More Themes/themeLibrary/download.*themes 等模式无匹配；设置页 UI Theme 区块只有导入/导出/删除/更新/另存五个操作；`index.html:2800, 2852` 的 "Download" 是第三方扩展与资产下载面板（`extensions.js`），不含主题；

主题文件只能经 importTheme 导入 JSON 或经 content-manager 的 THEME 类型文件通道（`src/endpoints/content-manager.js:340-341`）手工搬运，**无应用内"下载更多主题"**。

**同一主题 light/dark 双变体。** grep theme_dark/theme_light/ThemeDark/ThemeLight 于 `public/scripts/`（含 `util/`）与 `public/css/` 无匹配；主题 JSON 无明暗字段——每个主题是单一外观，"明暗"靠选择不同主题实现。

**独立强调色/主色设置。** 颜色选择器仅 10 个固定字段（`index.html:4984-5025`），无 accent 色字段；`--ac-color-*`（`css/macros.css:534-599`）只是 autocomplete 样式的回退变量，CSS 中无内置定义——第三方可注入，内置主题不涉及。

## 5. 响应式、移动端与窗口适配

响应式集中在 `public/css/mobile-styles.css`（全文 656 行已读），是媒体查询驱动的桌面/移动切换，无响应式框架：

- **主断点 max-width: 1000px**（`mobile-styles.css:2-508`，注释"catches ipads, horizontal phones, and vertical phones"）：各设置面板列改 flex-basis: 100% 单列堆叠（:4-11）；

  `body { touch-action: none; overflow: hidden; position: fixed; }`（:250-254，禁默认触摸手势、锁定 body 滚动）；抽屉面板 `.drawer-content` 改 position: fixed 铺满 100dvw（:260-269）。

**横屏子断点。** max-width: 1000px and (orientation: landscape)（:511-534）单独处理头像放大层定位与 waifu 表情图裁剪。

**竖屏窄屏子断点。** max-width: 450px（:537-580）把抽屉宽度比例从 1/4、1/3 收窄成 1/2。

**iOS 专属分支。** @supports (-webkit-touch-callout: none)（:583-656）处理 env(safe-area-inset-*) 刘海屏安全区与 PWA 模式（body.PWA）底部安全区内边距（:610-615）——官方认真对待"作为 PWA 装到 iOS 主屏幕"的场景。

**触摸手势（已核实缺失）。** 全仓库搜索 swipe 相关代码 + `touchstart/touchmove/touchend` 绑定，**没有"消息上左右滑动触发 swipe 候选回复"的手势实现**——移动端 swipe 是点击 `<` `>` 箭头按钮（`.swipe_left`/`.swipe_right`）。

真正用触摸事件的只有三处：滑动条触摸时锁页面滚动 300ms（`script.js:11696-11711`）、角色卡长按（见第 2 节）、头像放大层关闭点击兼容 touchend（`script.js:12225`）。

**触屏专用调参。** getSortableDelay()（utils.js:358-364）——桌面拖拽排序延迟 50ms，移动端 750ms，注释明确“防止滚动页面时误触发拖拽”；sortable({ delay, handle }) 模式遍布 world-info、tags、openai、textgen-settings 等十余个文件，但各模块各自初始化，无集中的“可排序列表”组件封装。

## 6. 图片、附件、拖放与常见内容交互

**图片/附件预览**（expandMedia，chats.js:880-970 已读）：复用第 2 节的 Popup 弹窗系统，不是独立灯箱库。

- 弹窗类型 POPUP_TYPE.DISPLAY（只有关闭 X），传入 large 和 transparent 选项（chats.js:960）铺大、背景透明。

**点击放大/还原是纯 class toggle。** 点击图片切换 `.zoomed` class（`chats.js:941-945`），CSS 侧 `.img_enlarged` 用 object-fit: contain + cursor: zoom-in，`.zoomed` 切 object-fit: cover 并允许滚动（`style.css:5305-5319`，

`.img_enlarged_holder:has(.zoomed) { overflow: auto; }`）——是"缩小适应"与"原始比例填充可滚动"的切换，不是支持拖拽平移/滚轮缩放的真正图像浏览器。
- 视频走同样弹窗但换 `<video controls autoplay>`（`chats.js:913-919`）；音频类型**明确不支持展开**（`chats.js:896-898`，console.warn('Audio media cannot be expanded')）。
- 点击弹窗背景关闭（`popup.dlg.addEventListener('click', () => popup.completeCancelled())`，`chats.js:964-966`）——与"Popup 不支持点遮罩关闭"不矛盾：这是调用方在内容层手动加的监听，非类内建能力。
- 有标题媒体用 `<pre><code>` 渲染说明文字（`chats.js:947-957`），stopPropagation 防点击标题触发放大/关闭。

**另一套独立查看器。** 桌面端头像放大用 jquery.izoomify（public/lib/jquery.izoomify.js，script.js:12221-12223），鼠标悬停局部放大镜，依赖 mouseover/mousemove（jquery.izoomify.js:144-147），仅 power_user.zoomed_avatar_magnification 开启时生效——纯触屏设备上基本不可用（未实测，标注未核实）。

消息图片弹窗、头像 izoomify、头像拖拽浮层 dragElement 是三套并行实现，无统一"图片查看器"组件。

**拖放分两类完全不同的实现**：

**A. 文件拖入导入**（DragAndDropHandler 类，`public/scripts/dragdrop.js`，107 行已读）：构造传选择器和回调，用 jQuery 事件委托在 document.body 上监听 `dragover/dragleave/drop`（目标元素重渲染也不丢监听，`dragdrop.js:52-65`）；dragleave 用 debounce_timeout.quick 去抖（`dragdrop.js:87-91`，防内部子元素边界闪烁）。4 个消费点：
- 角色卡拖入导入：`charDragDropHandler = new DragAndDropHandler('body', ...)`（`script.js:12494-12499`，noAnimation: true），区分文件（`processDroppedFiles()`，`script.js:10401-10434`，

  按 MIME/扩展名白名单——`application/json`、`image/png`、YAML、`.charx`、`.byaf`，其它 toastr.warning 拒绝）与外部 URL（importFromURL）。
- 聊天记录导入：`chatDragDropHandler = new DragAndDropHandler('#select_chat_popup', ...)`（`script.js:12501-12507`），拖入文件塞进隐藏 `<input type="file">` 触发 change 复用文件选择逻辑。
- 附件拖入弹窗：`chats.js:1510`（Data Bank / Attachment Manager 弹窗内，拖入后弹目标选择器选作用域）。
- 消息输入框拖入：`chats.js:2392-2394`（`#form_sheld`，直接走 handleFileAttach）。
- 拖拽悬停视觉统一由 drop_target/dragover class 驱动（`dragdrop.js:75, 90, 102`），各消费点共享一套视觉语言。

**B. 列表拖拽排序（jQuery UI sortable）**：public/lib/jquery-ui.min.js 的 sortable 插件，不是 SortableJS。

World Info、Quick Reply、正则规则和多组采样参数都使用相同的 Sortable 模式，并共享“移动端延迟更长”的参数。具体排序器仍由各功能分别初始化，没有形成公共封装（world-info.js:2576-2580）。

**扩展面板（Extensions panel）**：#rm_extensions_block（index.html:5741）是一串固定 ID 的空容器 div（#extensions_settings 下挂二十多个扩展容器，index.html:5760-5780+），各内置扩展初始化时把设置 UI 塞进对应容器——不是动态生成列表，是预先开好的“坑位”。

第三方扩展入口是输入框旁"魔法棒"图标（`addExtensionsButtonAndMenu()`，`extensions.js:688-723`）弹出 Popper.js 定位的下拉菜单（`#extensionsMenu`，placement: 'top-start'，`extensions.js:699-701`），点击外部白名单外区域自动收起（`extensions.js:714-722`）——魔法棒菜单是"扩展快捷动作入口"，Extensions 抽屉是"扩展详细设置面板"，两个不同概念。

扩展启停：`.extension_toggle` 复选框（`extensions.js:928, 1225, 1243`）触发 `enableExtension/disableExtension`（`extensions.js:473-500`），**默认整页刷新**（`location.reload()`，:479, 496），批量切换场景传 reload: false 累积后用 requiresReload 标记统一刷新一次（`extensions.js:1218-1243`）——零散切换与批量切换的交互刻意区分。

第三方扩展列表弹窗区分"默认容器/外部容器"两组展示，加载时显示 fa-spin + "Loading third-party extensions... Please wait..."（`extensions.js:1156-1164`），提供 "Update all"/"Update enabled"（`extensions.js:1186-1203`）与 "Toggle extensions"（`extensions.js:1205-1219`，含仅在有历史批量记录时显示的 "Restore toggled extensions" 还原按钮，:1214-1216）；

排序偏好（sortByName/sortManifestsByOrder，`extensions.js:1166-1169`）存 accountStorage（浏览器本地，非服务端）。

## 7. 扩展调查：无障碍与动画

### 无障碍现状（静态代码结论，未做读屏实测）

**"键盘可达性有自建框架，语义化 ARIA 几乎缺失"**：

- aria-* 属性几乎不存在：`index.html` grep aria- 仅 1 处命中（装饰图标 `aria-hidden="true"`，`index.html:5733`）；全部 `public/scripts/*.js` 只有 3 个文件各 1 处 `role=`，且都是把业务数据值（prompt 的 role 字段）写进 HTML 属性，不是无障碍语义——实质上没有专门为读屏设计的 aria-label/aria-describedby/`role="button"`（全文 grep 的确定性结果）。
- 绝大多数"按钮"是 `<div>`/`<i>` 图标：`index.html` 有 245 处 `.menu_button` 相关 `<div>`，而非原生 `<button>`。

**补偿机制。** keyboard.js 维护约 30 类可交互选择器。MutationObserver 会给新出现的匹配元素补 `tabindex="0"`，全局 Enter 处理再找到最近的可交互祖先并触发点击。这使大量非原生控件获得基本键盘路径，但不等于具备完整语义。（`public/scripts/keyboard.js:2-234`）

这套系统解决 Tab 可达与 Enter 触发，但没解决读屏"怎么念这个按钮"——`<div tabindex="0">` 无 role/aria-label 时读屏通常跳过或只读文字内容。
- title 属性大量存在（595 处）但不能替代 ARIA；手写 tabindex 只有 3 处（switch_input_type_icon 设 -1 刻意排除、mes_impersonate 设 0），其余靠 `keyboard.js` 运行时动态加。
- 结论（已核实）：键盘可用性中等（有专门框架保障 Tab/Enter），读屏语义几乎没有；未做 NVDA/VoiceOver 实测，实际体验可能因浏览器/读屏兼容性而异，**未做运行时验证**。

### 动画与过渡

`public/css/animations.css`（154 行已读）定义可复用 @keyframes：fade-in/fade-out（纯透明度）、pop-in/pop-out（透明度+垂直缩放，pop-in 在 0%-33% 就把 scaleY 拉到 1、后 67% 只调透明度）、flash（强调高亮）、pulse（filter: brightness 呼吸）、ellipsis（三点省略号，

未找到消费点）、infinite-spinning（`.PastChat_cross:hover` 删除叉号旋转，纯装饰）、slide（依赖 `--slide-mes-x-start/end` 变量，消息删除动画位移方向可由 JS 指定起止点）。

全局动画时长由 `ANIMATION_DURATION_DEFAULT = 125`（`script.js:595`）驱动的 `--animation-duration` CSS 变量控制（`setAnimationDuration()`，`script.js:824-828`），用户可在设置里改；

抽屉展开/收起在已有其它抽屉打开时先等 animation_duration 毫秒再切换（doNavbarIconClick()，script.js:10908-10910）。这与 public/scripts/util/stream-fadein.js（流式消息逐词淡入，morphdom + Intl.Segmenter）是两个层面：一个管面板级开合，一个管文本级淡入。

## 8. 设计取舍与已确认边界

**点遮罩不关闭弹窗。** 与大多数现代 Web 弹窗库相反的行为选择，已核实。

**双击 Esc 强制关闭阻塞弹窗。** 踩坑后留下的防御代码，作者注释自承原因不明。

**toastr 无统一封装。** 988 处调用分散在 86 个文件，作为全局工具库随处调用；差异化时长只是零星个例。

**主题不跟随系统深浅色。** `public/` 无 prefers-color-scheme 匹配（已核实），主题手动选择、服务端存储。

**主题单一外观、无明暗双变体。** 同一主题没有 light/dark 两套（已核实，见第 4 节"本次未找到"）。

**无应用内主题市场。** 主题只能导入 JSON 文件或经内容管理通道搬运，没有官方库下载入口（已核实）。

**字体族不可自定义。** 字号可缩放（`--fontScale` 派生链），字体族写死在 CSS（已核实）。

**背景图是独立于主题色的视觉层。** 背景库子系统（锁定、文件夹、动画、fitting）与主题颜色分离管理，bgcol 是两者唯一的程序化桥接。

**"生成中"反馈不是三点动画。** 走 Action Loader toast + data-generating 全局状态位，气泡无"正在输入"动画。

**移动端 swipe 是点按钮不是划手势。** 与功能名字暗示不符，已核实缺失。

**主角色列表空状态缺失。** CSS :empty 空状态模式未覆盖主角色列表。

**扩展面板固定坑位。** 内置扩展是预先开好的空容器，不是动态生成列表。

## 9. 未验证事项

- toastr 988 处调用的每个触发场景未逐一验证。
- 触屏设备上 izoomify 悬停放大镜的实际体验未实测。
- 无障碍结论基于静态代码扫描，未做屏幕阅读器实测；title 属性在具体读屏/浏览器组合下的朗读行为未验证。
- 各消费点 drop_target/dragover 的 CSS 细节未逐一比对。
- `getSortableDelay()` 与移动端 750ms 延迟的实际触屏拖拽体验未实测。
- 扩展启停整页刷新的运行表现、PWA iOS 安全区适配均未运行验证。
- 错误边界结论基于源码搜索（搜索模式与排除范围见第 3 节），未运行注入异常实测；`reloadLoop()` 达到 5 次上限后的页面表现（静默停留 preloader）未运行验证；服务端 uncaughtException 触发的 `exitProcess()` 清理链路未运行验证。
- 首帧主题表现未运行验证：静态链路显示首帧即应用持久化颜色值，但"`/api/settings/get` 返回前窗口停留在静态默认主题"的可见时长与闪变观感未实测。
- 主题体系核对新增（2026-08-13）：bgcol/autobg 的生成结果观感（对比度迭代保证、AI 选背景）是静态逻辑，未运行验证；背景库缩略图懒加载、主色占位、动画背景开关与文件夹操作的实际运行表现未实测；getNewTheme 白名单丢弃未知键的行为未用含坏字段的主题文件实测。

## 10. 关键源码索引

- `public/scripts/popup.js`
- `public/scripts/action-loader.js`
- `public/scripts/keyboard.js`
- `public/scripts/dragdrop.js`
- `public/scripts/BulkEditOverlay.js`
- `public/scripts/chats.js`（880-970 行 expandMedia）
- `public/scripts/util/stream-fadein.js`
- `public/script.js`（347-365 toastr 配置）
- `public/scripts/power-user.js`（主题应用与存储）
- `public/scripts/backgrounds.js`（背景库全文）
