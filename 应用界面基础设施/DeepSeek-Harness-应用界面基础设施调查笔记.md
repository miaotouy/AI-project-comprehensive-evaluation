# DeepSeek Harness 应用界面基础设施调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`（重点 `apps/web/`、`apps/desktop/`、`packages/client/`、`packages/host/`、`packages/api/`、`packages/typert/`、`packages/extensions/`、`packages/sdk/`、`packages/boot/`、`apps/cli/`、`packages/util/`）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`8bd073392eef6f54e921a093b95076248eb08cbb`（分支：`master`）
>
> 调查方式：基于当前代码快照进行静态源码核对；从应用装配与公共实现入手，抽样核对业务消费方；辅以 `docs/subsystems/{web-client,slots,web-server,client-modules}.md` 与 `docs/upgrade-guide/`；依赖内部行为和运行表现单独标注
>
> 调查范围：Web 应用（`apps/web`）的界面基础设施：启动与加载链、前端运行时与模块系统、连接与传输、Typert 协议与网关、插槽与组件工厂、配置表单、国际化、主题、上下文菜单与文件动作、宿主集成（webserver/frontend-static/directory-picker/open-in-app）、HMR、CLI profile boot；聊天业务主链由相邻类目笔记承接。视觉效果、性能、键盘与无障碍行为、真实浏览器运行表现不在本次静态调查范围
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek Harness 的 Web 界面是一个"一切皆插件"的 Cordis 组合产物：一个零插件依赖的 shell 内核负责加载页与装配，全部 UI 能力以 client 插件包形式经插槽系统组合。仓库另有 CLI/TUI、Desktop 与 headless/ACP 表面，Web 面通过 `dsh --profile web` 从同一套插件底座启动。

浏览器端由启动清单和 client module table 装配插件，React 绑定由 `client/store`（无 React 的可观察源）、`ui-renderer`（ctx↔React 绑定）、`ui-session`（会话数据适配）与 `ui-slots`（插槽与组件工厂）四层承担。传输层上行是 Remote HTTP POST，下行统一为 API Gateway `/api/remote.mux` 上的逻辑 streams，由 generation-ready 握手和连续恢复状态机管理。

业务数据统一由"对象层"持有（会话事件窗口、流式累积、重连机器），表现组件只通过框架注入的 hooks 与 store 读取；Typert 编译器从 TypeScript 类型图生成协议描述符与 zod 编解码器，网关据此分发 `/api` 调用，客户端无需手工维护协议代码。

两处与运行安全相关的基础设施变化：Web 监听地址必须是本机某个具体 IP（通配地址在装载期拒绝），调用信任由 `webStartup` 服务的 `trustedHosts` 提供；索引页渲染携带页面所代表的 Peer，远程访问快照按 Peer 生成，而非一律用 owner 的快照。

## 系统边界与总体装配

**界面栈。** React 18 + CSS Modules；无组件库、无 Tailwind，自研 `@deepseek-ai/dsh-client-ui-primitives` 提供按钮、输入、菜单、弹窗、Toast、Markdown 等原子组件与图标。产品文案随 locale 打包，仓库内建 zh/en/ja/es/fr/de/ru/pt 八套字典。

**四层职责划分**（`packages/client/AGENTS.md`）：数据对象层（runtime，React-free，零 React import）持有全部业务状态；渲染机制（`ui-renderer` + `ui-session`）完成 ctx 到 React 的集成并合成会话数据来源；表现组件（各插件包的 `src/client/`，纯 props）不承载业务逻辑；store 只装跨条目共享或跨重挂载的交互状态（面板几何、草稿、选择）。

**装配。** 宿主组合由 `packages/bundle/web-app/cordis.patch.yml` 描述：在 `dsh-base` 之上插入 web 专用宿主行（webserver、web-app/startup、api 各 controller、mcp-manager、plugin-inventory、product-telemetry-otel、open-in-app 等），再插入数十个 `dsh-client-*` 浏览器插件行；文件内共 97 条 `name:` 行。应用面（surface）的 agent 平面通过 `disabled: true` 关闭进程级行，改由每个会话的 agent preset 组合。

**多入口。** 仓库内有 `apps/web`（浏览器 shell 构建入口）、`apps/desktop` 与 `apps/desktop-host`（桌面壳）、`apps/cli`（CLI/TUI 与 `dsh web` 服务）、`apps/plugin-market-generator`。`dsh --profile acp`、`--profile headless`、`--profile sdk` 等其它 profile 不加载 Web 行；`apps/web` 只提供构建产物，由 `apps/cli` 的 `dsh web` 服务。

## 1. 界面栈、公共组件与状态所有权

**插槽系统。** `packages/client/ui-slots` 是组合核心：`SlotMap` 经声明合并扩展，一次 `slots.register({ name, children?, store?, inject? }, Component)` 同时贡献组件、声明子插槽（声明即渲染授权，跨包冲突在加载期失败）、座位 store 与注入面。插槽名镜像组合路径（如 `tool.call.toolview`），别名为 `ui-tool` 的选择器仍可用。`kind` 决定基数与调度（single/list/keyed/chain），`scope` 决定会话数据上下文（root/session-maybe/session）。另有 `registerFactory()` 供可复用组件或装配使用，工厂子插槽受同一 `SlotMap` 检查与全局所有权约束。框架只渲染内置 `root` 插槽，其余全部由业务插件声明。

**Props 五份派生面**：运行时套件、渲染子插槽、可复用工厂、store、注入面；全部由框架派生，业务代码不得手写或本地重定义。标准座位含 `useSession`、`useSessions`、`useWorkspaces`、`useStore`、`renderSlot`、`renderFactorySlot`，工厂额外得到 `useFactorySlot`。

**三条活数据通道**：父级已知的数据走渲染点的 owner props；只有组件自己知道的走本地 state；跨条目或跨重挂载共享的走注册时声明的 store。派生数据是对框架 hook 数据的纯函数，不自建订阅（`packages/client/AGENTS.md` 规则 5）。

**布局根。** `ui-layout` 把 `AppFrame` 挂进 root 插槽，声明 sidebar、conversation、details、sidebar.right、shell.overlay 等子插槽并配备布局 store；渲染决策集中在 AppFrame（sidebar 折叠态与宽度、固定列位置、帧级浮层）。

**状态所有权。** 会话列表、会话对象、连接状态机在对象层（`runtime/src/client/sessions/`，`SessionManager` 与 `Session`）；布局面板宽度、选择、草稿在插件声明的 store；组件内部状态留本地。快照 store 引擎基于 zustand vanilla + immer，产物是裸可观察源（getSnapshot/subscribe），选择器 hook 由 `ui-renderer` 在绑定点合成（`packages/client/store/src/*`）。发布节流分两档：结构更新走微任务批，可见流式块走动画帧批。

**渲染绑定。** `ui-renderer` 是唯一 ctx↔React 桥：按来源缓存 observable hook、按 session 合成标准套件、提供会话上下文。每个插槽条目外包一层错误边界：单个注册项渲染或注入崩溃不拖累兄弟，装配错误（缺 provider）重新抛出保持 fail-loud。

## 2. 弹窗、浮层、菜单与文件动作

**Modal。** 自研受控组件（`ui-primitives/src/Modal.tsx`）：portal 到 body（避免祖先 stacking context 盖过遮罩）、Esc 与遮罩点击关闭、`role="dialog"` + `aria-modal` + `aria-label`。无命令式弹窗注册表、无全局 Overlay Host；Modal 内未发现焦点陷阱与焦点归还逻辑，该行为依赖浏览器默认，未验证。业务消费面覆盖 workspace 选择器、模型设置、agent preset、目录选择等。对照组件 `ImageLightbox`（ui-attachment）在卸载时把焦点还给触发元素。

**上下文菜单与文件动作。** 新增两个独立基础设施包：`ui-context-menu` 提供声明式上下文菜单服务（条目按目标对象注册，命令 id 与快捷键复用），`ui-file-actions` 把文件/目录动作注册成可在菜单、命令面板与侧栏复用的动作。二者随 web-app 组合默认装载，业务包通过注册而不各自实现右键菜单。

**侧栏。** `ui-sidebar` 是左栏容器；右侧新增 `ui-sidebar-right` 作为右侧面板宿主，`ui-sidebar-files`、`ui-sidebar-terminal`、`ui-sidebar-browser`、`ui-sidebar-documentpreview` 作为条目注册。`ui-dockkit` 提供停靠/浮层几何基础。

**其他交互基础件**：`ui-input-trigger`（输入框 `@`/`/` 触发器）、`ui-commands`（斜杠命令面）、`ui-secret-mask`（敏感值遮罩）、`ui-shortcuts`（快捷键参考）、`ui-entry-customization`（入口外观定制）、`ui-trajectory`（回合轨迹视图）、`ui-reference`（会话/文件引用卡）、`ui-user-questions`（提问卡）、`ui-open-in-app`（在外部应用打开）。

## 3. 加载链、运行时与模块系统

- **shell 内核**（`packages/client/web`）：负责加载页、启动清单、注入应用、拖拽区域与 Loader 状态。启动审核只把必需条目的未激活视为致命错误；可选条目导入或激活失败会统一告警，活跃兄弟继续运行。若失败项导致必需项等待缺失服务，仍拒绝启动（`src/boot-client.ts:15-33,96-134`）。
- **client module table**（`client/modules`，`ctx.clientModules`/`ctx.modules`）：把可加载的浏览器插件模块映射到 URL，支持按需与并行装载；宿主侧 `extensions/cordis-client-runner` 提供客户端插件仓库与清单。
- **HMR**：`client/hmr` 消费开发期重载协议（SSE），`boot/hmr` 提供宿主侧；仅在开发构建生效，`DSH` 发布构建不装载。
- **文件上传**（`client/file-upload`）：原始 Blob 与字节流请求体在页面线程之外发送，避免大图阻塞渲染。
- **快捷键**（`client/shortcuts`）：命令注册表，UI 面由 `ui-shortcuts` 呈现。

## 4. 连接、传输与协议

**上行**：Remote 调用是 HTTP POST，路径前缀由 Gateway 生成；**下行**：所有订阅统一到 `/api/remote.mux`（`packages/api/gateway/src/stream-protocol.ts:7`）上的逻辑 streams，带 generation-ready 握手与断线续订。

**浏览器鉴权**：`client/connection` 负责浏览器与宿主的认证握手、重连状态机与事件投递；`browser-auth.ts` 记录 mux 路径。运行期信任由 `webStartup` 服务提供——`connection` 行从 `ctx.webStartup.trustedHosts` 读取 `--trusted-host` 授权列表，旧的 `webRuntime` 服务与 `web-runtime` 行的 `trustedHosts` 配置已移除（`docs/upgrade-guide/v0.2.1-alpha.1/web-listener-trust-config`）。监听 host 必须是本机接口的具体 IPv4/IPv6 地址，`0.0.0.0` 或 `::` 在装载期拒绝。

**Typert**：`packages/typert/{protocol,generator}` 从 TypeScript 类型图生成协议描述符与 zod 编解码器；服务类以 `@Remote` 标注方法，网关按描述符分发 `/api` 调用并在边界完成校验与错误映射。新增的 Remote 服务沿用该机制（例如 agent preset registry、plugin inventory、forge 面板）。

## 5. 配置表单与设置面

`packages/client/schema-form` 已不存在；schema 驱动的配置表单并入 `packages/client/ui-settings`（`src/client/{config-form,config-form-types,schema,settings-mirror}.ts`）：按命名空间读写设置文档、支持原子多字段更新与 schema 校验，并用 mirror 防止静默覆盖并发修改。`ui-settings` 只提供扩展点（设置外观、页面、头部动作、插件页签、引导）而不渲染界面，外壳由单独的呈现包提供；页面按域拆成 `ui-settings-{general,models,agent-loop,shell,web-search,subagent,session-log,plugins,plugin-inventory,account}`，由 `dsh-client-modules` 装配。宿主侧 `packages/boot/config-editor` 仍提供配置文档读写与 revision 校验，供设置面板保存 `cordis.patch.yml` 片段。

## 6. 国际化与主题

- **locale**（`packages/client/locale`，`ctx.locale`）：语言偏好与消息字典，字典按包放在 `locale/<lang>.json` 并按 i18n 伴侣文件校验；内建 zh/en/ja/es/fr/de/ru/pt。`LocaleRuntime` 提供 `t()` 与切换通知，插件在 apply 期注册自己的字典命名空间。
- **theme**（`ui-theme`）：应用所选配色主题；主题变量是 CSS 自定义属性，`base.css` 与 CSS Modules 消费。仓库文档 `docs/web-styling.md` 规定样式约定与 UI 半径等 token。

## 7. 宿主集成

- **webserver**（`host/webserver`）：HTTP 服务与索引页渲染。`renderIndex(html, peer)` 与 `collectIndexInjections(peer)` 现在都接收页面所代表的 Peer，`webserver/index-inject` 事件把同一 Peer 传给监听器，因此索引里的远程访问快照属于该 Peer，而不是一律 owner 快照（`docs/upgrade-guide/v0.2.1-rc.2/webserver-index-peer`）。
- **frontend-static**：静态资源与指纹缓存策略。
- **directory-picker**：`directory-picker`（seam）加 `directory-picker-native`、`directory-picker-browse`、`directory-picker-auto` 三个实现，由宿主按平台选择。
- **open-in-app**（`host/open-in-app`）：把文件或目录交给平台默认程序/编辑器打开，UI 面是 `client-ui-open-in-app`。
- **plugin-inventory**（`host/plugin-inventory`）：已安装插件清单投影，供设置与市场页消费。
- **product-telemetry-otel**（`host/product-telemetry-otel`）：产品遥测出口，与 `telemetry/otel` 分开。

## 8. profile、启动与退出

- **CLI 启动**（`apps/cli/src/{bin,profile-boot,process-shutdown}.ts`）：`dsh --profile web` 解析 profile 与 patch 覆盖，装载 `boot/app-boot` 的 profile 图，打印 `dsh web: <url>` 并可选打开浏览器。`--dump-config` 打印组合后的 patch；`--no-open` 抑制自动打开。
- **启动**：`web-app/startup` 行提供 `webStartup`（监听 host/port、`trustedHosts`、公开 URL），`web-app` bundle 行组装 Web 表面；`boot-app` 负责 Loader 树、include 合并与入口激活审计（`assertEntriesActivated`）。
- **退出**：`process-shutdown` 依次停止 Web 服务、flush 会话、销毁插件树。

## 9. 设计取舍与已确认边界

- **插件即 UI**：UI 组件、状态、命令、菜单条目都以插件注册进入插槽与命令表，产品面没有集中式路由或页面注册表；代价是装配错误在加载期而非运行期暴露，需要清晰的插槽声明规则。
- **框架派生 props，业务不造 hook**：把"谁拥有数据、谁订阅"变成结构约束，业务组件不会出现第二套订阅机制；代价是每个新数据面都要先扩框架。
- **会话数据不进 store**：共享 store 只容纳 UI 状态，避免把会话日志复制成第二事实源。
- **监听地址必须具体**：以可绑定性换安全默认，禁止通配绑定暴露端口到网络。
- **索引按 Peer 生成**：同一份 HTML 对不同 Peer 可能不同，换取远程访问快照与访问身份一致。
- **协议由类型生成**：无需手工维护 RPC 客户端；代价是构建链依赖 Typert 生成器与版本一致的协议描述符。
- **无组件库与 CSS 框架**：自研 primitives 保证视觉一致与体积可控，代价是通用交互（焦点管理、无障碍）需要逐组件补齐——Modal 的焦点行为即为已确认的待观察项。

## 10. 未验证事项

- 未在真实浏览器运行：加载时序、模块装载失败回退、HMR 重载、拖拽区域、流式发布节流的实际表现均为静态确认。
- 键盘可用性、焦点管理与无障碍属性只做了代码级抽查（Modal 已标注焦点陷阱缺失）。
- Typert 生成器的类型分析边界与网关错误映射细节未逐行核对。
- 插槽错误边界的失败隔离程度、store 生命周期与插件卸载顺序未验证。
- Desktop（Electron）壳与 Web 面共用多少客户端插件未细读。
- context-menu / file-actions 的注册与命令复用细节只读包级入口。

## 11. 关键源码索引

- 组合：`packages/bundle/web-app/cordis.patch.yml`（97 条行）、`packages/bundle/web-app/src/{index,startup,public-url}.ts`、`packages/bundle/web-app/presets/*.patch.yml`
- shell 与启动：`packages/client/web/src/{boot,boot-client,boot-page,seed,mount,apply-injections}.ts`、`apps/web/src/main.ts`、`packages/boot/app-boot/src/index.ts`
- 插槽与渲染：`packages/client/ui-slots/src/*`、`packages/client/ui-renderer/src/*`、`packages/client/ui-session/src/*`、`packages/client/store/src/*`
- 连接与协议：`packages/client/connection/src/{index,browser-auth}.ts`、`packages/api/gateway/src/{index,stream-protocol}.ts`、`packages/api/remotes/src/*`、`packages/typert/{protocol,generator}/src/*`
- 交互基础：`packages/client/ui-primitives/src/*`、`ui-layout/src/client/index.ts`、`ui-context-menu/src/*`、`ui-file-actions/src/*`、`ui-sidebar-right/src/*`、`ui-dockkit/src/*`
- 表单与设置：`packages/client/ui-settings/src/client/{config-form,schema,settings-mirror}.ts`、`packages/boot/config-editor/src/*`、`packages/client/ui-settings*/src/*`
- 国际化与主题：`packages/client/locale/src/*`、`packages/client/ui-theme/src/*`、`docs/web-styling.md`
- 宿主集成：`packages/host/webserver/src/index.ts`、`frontend-static/src/index.ts`、`directory-picker*/src/*`、`open-in-app/src/*`、`plugin-inventory/src/*`、`product-telemetry-otel/src/*`
- CLI：`apps/cli/src/{bin,profile-boot,process-shutdown}.ts`、`packages/boot/cmdline/src/index.ts`
- 文档：`docs/subsystems/{web-client,slots,web-server,client-modules,client-resources}.md`、`docs/upgrade-guide/v0.2.1-alpha.1/web-listener-trust-config`、`docs/upgrade-guide/v0.2.1-rc.2/webserver-index-peer`
