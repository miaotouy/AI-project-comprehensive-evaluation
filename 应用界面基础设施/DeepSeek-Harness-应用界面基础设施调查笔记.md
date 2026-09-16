# DeepSeek Harness 应用界面基础设施调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`（重点 `apps/web/`、`packages/client/`、`packages/host/`、`packages/api/`、`packages/typert/`、`packages/extensions/`、`packages/sdk/`、`packages/boot/`、`apps/cli/`、`packages/util/`）
>
> 调查更新日期：2026-09-16
>
> 代码快照：`0d1f50007f9bca3f52b06e1c3074fa14d5fb0720`（分支：`master`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配和公共实现入手，抽样核对业务消费方；依赖内部行为和运行表现单独标注
>
> 调查范围：Web 应用（`apps/web`）的界面基础设施：启动与加载链、前端运行时与模块系统、连接与传输、Typert 协议与网关、schema-form 表单、国际化、主题、宿主集成（webserver/frontend-static/directory-picker）、HMR、CLI profile boot；聊天业务主链由相邻类目笔记承接。视觉效果、性能、键盘与无障碍行为、真实浏览器运行表现不在本次静态调查范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek Harness 的 Web 界面是一个“一切皆插件”的 Cordis 组合产物：一个零插件依赖的 shell 内核负责加载页与装配，全部 UI 能力以 client 插件包形式经插槽系统组合。仓库另有 CLI/TUI 表面，Web 面通过 `dsh --profile web` 从同一套插件底座启动。

浏览器端仍由启动清单和 client module table 装配插件，但 React 绑定已从旧 web-react/runtime 拆为 `client/store`、`ui-renderer` 与 `ui-session`。传输层上行是 Remote HTTP POST，下行统一为 API Gateway `/api/remote.mux` 上的逻辑 streams，由 generation-ready 握手和连续恢复状态机管理（`packages/client/README.md`；`connection/README.md`）。

业务数据统一由“对象层”持有（会话事件窗口、流式累积、重连机器），表现组件只通过框架注入的 hooks 与 store 读取；Typert 编译器从 TypeScript 类型图生成协议描述符与 zod 编解码器，网关据此分发 `/api` 调用，客户端无需手工维护协议代码。

## 系统边界与总体装配

**界面栈。** React 18 + CSS Modules；无组件库、无 Tailwind，自研 `@deepseek-ai/dsh-client-ui-primitives` 提供按钮、输入、菜单、弹窗、Toast、Markdown 等原子组件与图标（`packages/client/ui-primitives/src/`，51 个文件）。产品文案固定中文，代码注释英文。

**三层职责划分**（`packages/client/AGENTS.md`）：数据对象层（`runtime`，React-free，零 React import，可 grep 断言）持有全部业务状态；渲染机制（`web-react`，shell 独占胶水）完成 ctx 到 React 的全部集成；表现组件（各插件包的 `src/client/`，纯 props）不承载业务逻辑。业务数据绝不进 store，store 只装共享查看/交互状态（面板几何、草稿、选择）。

**装配。** 宿主组合由 `packages/bundle/web-app/cordis.patch.yml` 描述：先在 `dsh-base` 之上插入 web 专用宿主行（webserver、api-gateway、directory-picker 等），再插入约四十个 `dsh.client` 浏览器插件行；每行是一个 `name: '@deepseek-ai/dsh-…'` 的 Cordis 插件。应用面（surface）的 agent 平面通过 `disabled: true` 关闭进程级行，改由每个会话的 agent preset 组合。

**多入口。** 仓库内 Web 面只有 `apps/web` 一个入口；`dsh --profile acp`、`dsh --profile headless` 等其他 profile 不加载 Web 行（`cordis.patch.yml:8-12` 注释）。`apps/web/package.json` 声明 dist 由 `apps/cli` 的 `dsh web` 服务，无独立部署形态。

## 1. 界面栈、公共组件与状态所有权

**插槽系统。** `packages/client/ui-slots` 是组合核心：`SlotMap` 经声明合并扩展，一次 `slots.register({ name, children?, store?, inject? }, Component)` 同时贡献组件、声明子插槽（声明即渲染授权，跨包冲突在加载期失败）、座位 store 与注入面。插槽按两种轴分类：`kind` 决定基数与调度（single/list/keyed/chain），`scope` 决定会话数据上下文（root/session-maybe/session）。组件 props 由四份 share 派生：运行时标准套件、渲染子插槽、store、注入面。框架只渲染内置 `root` 插槽，其余全部由业务插件声明。

**布局根。** `ui-layout` 的注册把 `AppFrame` 挂进 root 插槽，同时声明 sidebar、conversation、details、shell.overlay 四个子插槽并配备布局 store（`ui-layout/src/client/index.ts:116-143`）。渲染决策全部发生在 AppFrame：sidebar 拿到让步解算后的折叠态与宽度作为 owner props，会话相关条目按固定列位置渲染，shell.overlay 是帧级浮层（点击穿透，条目自行选择恢复指针事件）。

**状态所有权。** 三层分账：会话列表、会话对象、连接状态机在对象层（`runtime/src/client/sessions/`，`SessionManager` 与 `Session`）；布局面板宽度、选择、草稿在插件声明的 store；组件内部状态留本地。快照 store 引擎基于 zustand vanilla + immer，产物是裸可观察源（getSnapshot/subscribe），选择器 hook 由 web-react 在绑定点合成（`runtime/src/client/contract/store.ts:1-60`）。发布节流分两档：结构更新走微任务批，可见流式块走动画帧批（`runtime/src/client/sessions/notifier.ts`）。

**渲染绑定。** `web-react/src/scoped-slots.tsx` 是唯一 ctx↔React 桥：按来源缓存 observable hook、按 session 合成标准套件、SessionProvider 提供会话上下文。每个插槽条目外包一层 `SlotErrorBoundary`（`scoped-slots.tsx:317-333`）：单个注册项渲染或注入崩溃不拖累兄弟，装配错误（缺 provider）重新抛出保持 fail-loud。

## 2. 弹窗、浮层与菜单

**Modal。** 自研受控组件（`ui-primitives/src/Modal.tsx`）：portal 到 body（避免祖先 stacking context 盖过遮罩）、Esc 与遮罩点击关闭、role="dialog" + aria-modal + aria-label。无命令式弹窗注册表、无全局 Overlay Host；Modal 内未发现焦点陷阱/焦点归还逻辑，该行为依赖浏览器默认，未验证。仓库内约二十处业务消费（`ui-workspace` 的 WorkspacePicker/WorkspaceBrowser、`ui-settings-models` 的编辑与 onboarding、`ui-agent-preset`、`ui-directory-picker-browse` 等）。对照组件 `ImageLightbox`（ui-attachment）则在卸载时把焦点还给触发元素并聚焦关闭按钮，两组件行为不一致，均未运行验证。

**帧级浮层。** `shell.overlay` 插槽是 list 型、root 作用域，位于三列之外、可堆叠条目；CSS 层点击穿透设计使条目默认不挡下方应用。这是弹窗之外唯一的公共浮层通道。

**菜单与浮层组件。** `ui-primitives` 另提供 Menu、HoverCard、Tooltip、DisclosureRow、Pill 等。命令面板形态由 `ui-commands` 的 PopupSelectView 承担（含 `useAnchoredMaxHeight` 自适应），`ui-input-trigger` 的 MenuView 是 `/` 与 `@` 触发菜单。

## 3. 通知、加载态与错误反馈

**Toast。** 受控、无队列：3 秒全透明驻留 + 1 秒淡出后回调 `onDone` 由 owner 卸载；body portal，可按锚元素水平居中（`ui-primitives/src/Toast.tsx`）。消费实例为 `ui-conversation` 的 InputBar（图片上限等）与 `ui-model-selection` 的 ModelSelect。

**连接反馈。** `ConnectionBanner` 是独立原子组件；连接状态本身由对象层 `ConnectionController` 维护，UI 侧经 sessions 列表快照中的连接事实间接读取。

**加载态。** 启动加载页是 shell 内核自绘（见 §4 主链路），与插件无关；会话内容加载的骨架/空状态集中在 `ui-conversation/src/client/skeleton/`（EmptyHero、ContextMeter 等）。无统一 Loading 组件或骨架屏注册表。

**错误边界。** 两级：插件条目级 `SlotErrorBoundary`（崩溃项显示 `data-slot-error` 占位，见 §1）；HTTP 服务每请求兜底，handler 抛错记日志并回 400，绝不因单请求退出进程（`host/webserver/src/index.ts:170-180`）。无应用根级 React ErrorBoundary，shell 装配错误走 `SlotAssemblyError` 重抛路径。

## 4. 主题、视觉 token 与持久化

**权威源。** 主题偏好是 light、dark、system 三值（`ui-theme/src/theme-settings.ts`），默认 system。持久化在宿主用户设置文档的 ui-theme 命名空间；浏览器侧 ThemeRuntime 把 system 经 prefers-color-scheme 解析成实际方案，并在该模式下监听 OS 变化重发布。

**防首屏闪烁。** 宿主把一段内联脚本注入每个 index 响应：在 shell 加载前就设置 html 的 color-scheme 与深色标记（`boot-theme.ts:12-21`），经 webServer.tapIndex 实现。插件树激活后由 ui-layout 的 ThemePresenter 接管（`theme-presenter.ts:37-51`）：写同一对字段、把 --dsw-* 别名 token 作为内联 CSS 变量刷到 body、更新 presenter 自有的主题色 meta；只回退自己写过的属性，不碰外来样式。

**Token 体系。** 基础色板样式表在 `ui-theme/src/styles/`，特征组件只消费语义别名 token，不写具体颜色。`ThemeDefinition` 携带 light/dark 双值 override 字典，允许多主题按序叠层（`ui-theme/src/client/index.ts:60-87`）。

## 5. 响应式、窗口适配与浮层

**三列让步链。** `AppFrame` 用 CSS grid 固定 `sidebar | minmax(0,1fr) | details` 三轨；宽度偏好进 store，纯函数 `computeColumns` 按“中心不低于 640 → 收缩 details → 自动关闭 details → 中心吸收缺口”让步，sidebar 永不放弃、折叠时显示固定 56px 图标轨（`ui-layout/src/client/columns.ts:62-76`）。无滞后：窗口加宽自动恢复偏好。

**断点。** 视口窄于 1024px 时 sidebar 自动折叠为轨（`SIDEBAR_AUTO_COLLAPSE`），窄幅手动展开会覆盖中心列；判断在 AppFrame 层，解算器保持无断点。帧尺寸经 ResizeObserver + rAF 节流跟踪，拖拽手柄用 pointer capture + rAF 节流。

**移动端。** 本次未找到独立移动端入口、独立路由或媒体查询级导航重组；响应式只在列折叠层面。窗口最小尺寸未发现强制约束。

**图片预览与拖放。** `ui-attachment` 提供 ImageLightbox 灯箱（body portal、Esc/遮罩关闭、焦点归还）与附件轨道。拖放没有公共库：图片拖入在 `ui-conversation` 的 InputBar 以 document 级监听实现（Files 类型判断、dropEffect 反馈、落下取文件），workspace 的行重排与跨区移动走业务自建 dataTransfer 文本协议。剪贴板直接使用浏览器 API，本次未深入。

## 6. 国际化与本地化

`LocaleRuntime` 是浏览器侧字典注册表加偏好（`locale/src/client/index.ts:114-313`）：每个命名空间注册全部语种的字典（注册时强制双语文档完整），查找链依次是当前语种 → 该命名空间中文回退 → 共享 common 命名空间 → 原键（缺译文本保持可见，UI 侧 fail-loud）。内置 zh/en 两语种，中文是回退语种，浏览器 navigator.language 主标签只做临时初值。

偏好经 settings scope 写宿主设置文档的 `locale` 命名空间；切换只经 `setLocale` 一个入口，变更发布为 `locale/change` 事件与带单调 revision 的快照（uSES 安全）。语言选择 UI 是设置 General 区的一行（`LanguageRow`），由 locale 插件自持其设置表面。

## 7. 传输、连接与信任模型

**载波。** Remote unary 调用走 HTTP POST，逻辑 streams 复用 API Gateway 的 `/api/remote.mux` WebSocket；feature package 还可向 Connection 注册精确 Fetch route，用于会话 ZIP、文件上传等非 JSON 响应。shell-owned composition 可用 `connection.rpc.open` 提供等价逻辑 carrier，而不打开 WebSocket（`packages/client/connection/README.md:25-39`）。

**重连状态机。** Gateway 的内部 `$events` logical stream 是 generation source。Host 先装增量监听，再发送 ready baseline；Connection 收到 ready 后才发布 connected generation。stream 结束、Remote 错误、非法 opening 或超时会撤销 generation，按 500ms 到 10s 的抖动退避持续重试；浏览器 offline 时暂停，online 后从首档恢复（`packages/client/connection/README.md:41-50`）。

**信任与认证。** Host/Origin 栅栏仍先拒绝 DNS rebinding 与 cross-site 请求；其后所有 RPC 和 WebSocket 都要求浏览器 session。进程生成随机 launch token，只允许根 GET 用它换取绑定 hostname+port 的签名 HttpOnly、SameSite=Strict cookie；签名 secret 存在 credentials owner record，默认有效 30 天。静态资源公开，业务 API 无匿名 loopback 例外（`packages/client/connection/README.md:30-46`）。

**宿主 RPC 通道。** `rpc-host.ts` 提供 carrier-neutral RPC 与精确 Fetch route 注册；Web carrier 独占 `/api` HTTP bridge、浏览器认证及 Host/Origin 检查。普通 buffered route 有聚合请求体上限，显式 streaming route 以背压块绕过该聚合上限并由 feature 自己负责持久化和取消。

## 8. 前端运行时、模块系统与启动链

**两阶段 boot。** shell 内核 `AppWebEntry.run()`（`client/web/src/boot.tsx:97-143`）先建模块系统与加载页，再接入 Cordis。顺序如下：

1. 解析 `window.__DSH_BOOT__`，构造 `ClientModuleSystem`（种子表 + 静态表 + 图行），渲染加载页。
2. 并行预取 `immediately` 层（只注册工厂，失败不阻断——导入路径自行大声重试）。
3. 安装 vendored Loader，把 `loader.internal` 指到模块系统（浏览器内禁止裸动态导入兜底）。
4. 等待预取后创建每个插件行的 loader 条目，外加 shell 自有的 app-shell 条目。
5. `loader.await()` 后做全条目 ACTIVE 审计，置 settled 信号，AppRoot 一次性切换真实 UI。

启动失败保留加载页并渲染失败报告（fail-loud，绝不进入半成品界面）。

**清单协议。** `window.__DSH_BOOT__` 是 `{ rev, entries: [{ id, url, rev, inject?, immediately? }] }`；同一条数据解析成模块表视图与插件行视图（`modules/src/client/manifest.ts:50-99`）。宿主 `modules` node 半扫描各包 `dsh.client` 声明增量组合该图、服务 `/plugins/<id>/client.js`、经 index tap 注入清单（`modules/src/index.ts:1-21`）。

**懒 CJS 模块表。** 执行插件 bundle 只向 `window.__ModuleLoader__.load` 注册工厂；CSS 注入等副作用在首次 import 时随工厂 materialize 执行，require 按“种子→静态→缓存→已注册工厂→图行”递归解析，装序自解决（`modules/src/client/system.ts`）。种子表只含平台单词，与 `apps/web` 的 Vite 别名和 define 一一对应（`client/web/src/platform.ts`）：

| 类别 | 单词 |
|---|---|
| React 家族 | `react`、`react/jsx-runtime`、`react-dom`、`react-dom/client` |
| 框架 | `@deepseek-ai/cordis`、`@deepseek-ai/dsh-client-ui-slots`、`@deepseek-ai/dsh-client-web-react` |
| 共享 UI | `@deepseek-ai/dsh-client-ui-primitives`、`@deepseek-ai/dsh-client-ui-attachment`、`@deepseek-ai/dsh-client-schema-form` |

**构建。** `apps/web/vite.config.ts`：workspace 包别名到源码编译（CSS 走 Vite 管线）；`index`/`vendor` 双 chunk 划分，数学/Markdown/高亮依赖族进 vendor，shiki 语言语法按需独立 chunk；`rejectStandaloneServe` 插件禁止裸 Vite serve（必须经 `dsh web` 注入清单，防无清单的壳被暴露）。

## 9. Typert 协议、网关与 BFF

**生成。** `packages/typert/generator` 从 TypeScript 项目分析导出图（`analyzer.ts`，程序/符号只作提取手段）→ 编译器无关模型 → 发射 JS/声明与 zod schema（`emitter.ts`）；`tsdown-plugin.ts` 在构建期先降级依赖中的装饰器再写工件。宿主侧 `typert-loader` 按 Loader 条目扫描 `./typert` 导出，逐条校验后注册进运行时（`typert/loader/src/index.ts`）。

**协议形状。** 每个导出方法落成 `InvocationDescriptor`：命名空间/方法、命名 wire 参数、strict 或 src-json 编解码、可选的 context 作用域与 lookup 投影（`typert/protocol/src/types.ts:150-211`）。注册表分 local/remotes/lookups/contexts 四类，均提供注册、订阅与 dispose；跨边界 id 用 `Branded<B>` 名义类型（`util/brand`，仅类型无运行时代码）。

**网关。** 客户端 `api-gateway/client` 挂载各包生成的 contribution：校验无重复与命名空间冲突后，为每个命名空间创建 Cordis service，方法经 `connection.rpc.call('/api', endpoint, { args })` 发出，两端都用 strict codec 解析（`api/gateway/src/client/index.ts:356-415`）。宿主 `ApiProxyService` 实现运输无关的 `apiProxy` 契约（`host/apiproxy/src/index.ts:69-126`），物理载波自行包装。

**BFF 装配。** `api/remotes` 把 commands、goal、cordis-host-runner、plugin-inventory、message-feedback 的 Remote 贡献在客户端一处装配（`api/remotes/src/client/index.ts`）；宿主事件转发白名单 `API_REMOTE_FORWARDED_EVENTS` 在编译期被 `TypertForwardableEvent` 形状门控（无作用域、单向 void），连接行把 `host/remote-event` 帧直接 `$dispatch` 给订阅者。

## 10. schema-form 表单

`client/schema-form` 是设置编辑器的模型层：宿主把 schemastery 序列化信封经 wire 传回，客户端重建为活校验器、按设置路径解析节点、试跑校验、以不可变编辑草稿（`schema-form/src/model.ts`）。编辑器各自渲染控件（Models 页手写布局、插件配置卡片展开式），本包只提供草稿与校验支撑，不提供控件本体。生成器依赖 zod（`_zod` 标记，`typert/loader/src/index.ts:105-107`），设置线用 schemastery，两套 schema 体系并存。

## 11. 宿主集成（webserver、frontend-static、directory-picker）

**webserver。** 纯路由注册载波，不含任何 harness 概念：exact/prefix 命名路由、HTTP upgrade 路由、index 变换 tap 链、单一 fallback 席位（二抢抛错）；监听即激活，启动期未认领的请求回 404（`host/webserver/src/index.ts`）。

**frontend-static。** SPA dist 服务插件认领 fallback 席位：目录穿越 403、任何 miss 回 index.html 且状态 200、未知扩展名 octet-stream、非 GET/HEAD 405；每次 index 响应过 `applyIndexTaps`（boot 清单与主题脚本的注入点）。dist 位置由组合应用经 `!!js` 表达式提供，插件不硬编码（`host/frontend-static/src/index.ts`）。

**directory-picker。** 能力判别服务：`native` 能力在宿主显示器上打开系统选择器，`browse` 能力提供逐层列目录/创建原语供应用内浏览器使用（远程客户端无显示也可用）；消费者按 `capability().kind` 分支，未知 kind 的默认是隐藏选择入口而非报错。native 后端是平台命令链（macOS osascript、Linux zenity→kdialog 回退）+ Windows 走 koffi 绑定的 IFileOpenDialog 子进程（`host/directory-picker-native/src/native-picker.ts:48-106`），并非 Tauri 或其他嵌入式外壳；目录行携带绝对路径与面包屑、截断标记，客户端从不自行拼接路径（`host/directory-picker/src/index.ts:28-56`）。

## 12. HMR

宿主半用 stat-poll 跟踪每个图行的 client bundle（默认 500ms，兼容网络挂载，`hmr/src/index.ts:99` 起），内容变化经 clientModules.rebuilt 重算 rev，并通过 `/plugins/events` SSE 广播重建帧。浏览器半收到帧后按固定顺序执行（`hmr/src/client/index.ts:104-140`）：先 invalidate 丢弃旧工厂与物化记录（必须早于 prefetch，否则 prefetch 是 no-op），再 prefetch 注册新工厂（纯注册无副作用）；随后从注册表先行拆除旧纤维、排空其 disposer、移除该条目自有的样式标签；最后 entry.refresh() 重新物化（副作用在此执行）并等待新纤维。级联零手工：下游纤维的激活纪元键控于 provider 纤维 uid，数据层重载自动级联到 UI 依赖者。失败无回滚，import 失败留待下一帧重试，apply 失败留给 shell 状态投影；串行化防止帧交错。存在 `apps/web/tests/hmr-live.e2e.ts` 端到端用例，但需要真实发布流程运行。

## 13. 设计取舍与已确认边界

**插件化界面即产品形态。** 一个 UI 功能 = 一个 client 插件包，组合走插槽而非组件树约定；跨插件值导入是构建期错误，唯一通道是插槽、store、注入面与服务。这与仓库“一切皆插件”的总体设计一致。

**shell 自足规则。** 加载页与失败页零插件依赖，连快照 store 引擎都是手写信号（`client/web/src/loader-status.ts`），保证插件全挂时页面仍能解释发生了什么。

**懒 CJS 而非 ESM。** 为把脚本加载与副作用执行解耦，用注册-物化两段模型支撑 HMR 就地位换；代价是 require 环成为致命错误（工厂形态无法交付部分导出）。

**无全局 overlay host / 命令式弹窗。** Modal、Toast 都是业务侧受控组件；唯一的公共浮层通道是 `shell.overlay` 插槽。没有命令式弹窗注册表、没有全局 toast 队列。

**传输非对称。** 上行 HTTP、下行 WS，客户端对事件流只读；重连严格握手保证 resync 不超前于订阅基线。信任栅栏是绑定策略，不是认证层——`trustedHosts` 之外的网络可达性管控由部署决定。

**文档与实现不一致（已确认）。** `cordis.patch.yml:287` 注释引用 `apps/cli/src/web.ts`，该文件在当前快照中不存在；实际的 web 参数解析在 `packages/bundle/web-app/src/startup.ts`。同文件 `:142` 的 HMR 注释称“TODO 重开共享 HMR”，但 `client-hmr` 行实际已启用且 HMR 宿主/浏览器两端实现完整，注释滞后。

**桌面壳已出现。** 当前仓库已增加 Electron 应用入口及 asar runtime resolution；它复用现有 Web client 与 Host 能力，而不是另造业务 UI。桌面打包、升级和平台行为仍未运行验证。

**进程级启动兜底。** CLI 侧 `app-boot` 提供 fail-loud 守卫（未处理拒绝打标退出，终端持有者可先归还终端）、patch 层动态应用（用户 patch 经 Cordis HMR 热重载）、以及 `assertEntriesActivated` 激活审计（把 pending 原因列出）；`apps/cli/src/process-shutdown.ts` 提供 5 秒优雅退出与信号升级强制退出。浏览器 shell 侧有对应的 settled 审计，两端都在放行前确认全部条目激活。

## 14. 未验证事项

- 视觉效果、布局观感、色彩呈现、动画时长与过渡需要浏览器运行验证；本次只确认样式规则、事件绑定与状态路径。
- Modal 的焦点陷阱、Esc 语义的键盘可用性与读屏表现依赖浏览器与 React 默认行为，未运行验证。
- vite 构建产物的实际 chunk 划分与加载性能未验证；`apps/web/stress-tests/reasoning-chunks.stress.ts`（10 万 chunk 压测）需浏览器运行。
- HMR 端到端、重连期间的数据恢复、`markFrameDirty` 流式批的渲染节奏未实测。
- Typert 生成器对真实包的运行期产物（schema 校验在 wire 上的表现）、事件转发白名单的端到端行为未验证。
- 依赖库内部未下钻：zustand/immer 的批处理与订阅内部、zod 与 schemastery 的解析边界、shiki 语法高亮、micromark 增量渲染的细节。
- `shell.overlay` 条目消费实例、native directory-picker 在真实桌面会话上的对话框表现（含 Windows koffi 对话框）未验证。
- 主题 `system` 模式跟随 OS 变化的实际刷新时机未实测。

## 15. 关键源码索引

- `packages/client/web/src/boot.tsx`：`AppWebEntry`（`:68-238`），两阶段 boot 与 ACTIVE 审计
- `packages/client/web/src/AppRoot.tsx`、`loader-status.ts`：加载页与失败报告
- `packages/client/modules/src/client/system.ts`、`manifest.ts`：懒 CJS 模块表与 `__DSH_BOOT__` 协议
- `packages/client/modules/src/index.ts`：宿主图组合、bundle 服务、index tap
- `packages/client/connection/src/client/connection.ts`：`ConnectionController`（`:61-202`）
- `packages/client/connection/src/client/web-api-client.ts`：fetch + 双 WS 载波
- `packages/client/connection/src/api-request-trust.ts`：`isTrustedApiRequest`（`:96-123`）
- `packages/client/connection/src/rpc-host.ts`、`http-bridge.ts`：宿主通道与 fetch 桥
- `packages/client/runtime/src/client/sessions/`：对象层（`service.ts`、`manager.ts`、`session.ts`、`notifier.ts`）
- `packages/client/runtime/src/client/contract/store.ts`：快照 store 引擎
- `packages/client/ui-slots/src/index.ts`：SlotMap/register/四份 share 类型
- `packages/client/web-react/src/scoped-slots.tsx`：渲染绑定与 `SlotErrorBoundary`（`:317-333`）
- `packages/client/ui-layout/src/client/AppFrame.tsx`、`columns.ts`：三列框架与让步解算
- `packages/client/ui-primitives/src/Modal.tsx`、`Toast.tsx`：受控弹窗与横幅
- `packages/client/ui-theme/src/boot-theme.ts`、`theme-settings.ts`、`src/client/index.ts`：主题权威源与防闪烁
- `packages/client/ui-layout/src/client/theme-presenter.ts`：DOM 主题应用
- `packages/client/locale/src/client/index.ts`：`LocaleRuntime`（`:114-313`）
- `packages/client/schema-form/src/model.ts`：schema 草稿模型
- `packages/client/hmr/src/index.ts`、`src/client/index.ts`、`src/events.ts`：HMR 两端与 SSE 协议
- `packages/typert/protocol/src/types.ts`、`generator/src/{analyzer,emitter,tsdown-plugin}.ts`：协议类型与生成
- `packages/api/gateway/src/client/index.ts`、`packages/api/remotes/src/client/index.ts`：Remote 装配与事件转发
- `packages/host/webserver/src/index.ts`、`frontend-static/src/index.ts`、`apiproxy/src/index.ts`：宿主服务
- `packages/host/directory-picker/src/index.ts`、`directory-picker-native/src/native-picker.ts`：目录选择能力
- `packages/bundle/web-app/cordis.patch.yml`：Web 组合
- `packages/boot/app-boot/src/index.ts`：`boot`（`:757-802`）、`assertEntriesActivated`（`:692-725`）
- `apps/cli/src/bin.ts`、`profile-boot.ts`、`process-shutdown.ts`：CLI 启动与退出
- `packages/util/brand/src/index.ts`、`home-paths/src/index.ts`、`launch-environment/src/index.ts`：基础工具
