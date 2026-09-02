# Godot 主界面与分级 LLM 内容渲染可行性调查笔记

> 对比对象：Godot 原生 Control/RichTextLabel、RmlUi、litehtml、Ultralight，以及 AIO Hub、SillyTavern 的消息渲染机制
>
> 对比更新日期：2026-09-02
>
> 依据：Godot、RmlUi、Ultralight 官方文档，litehtml、Godot-HTML、Godot-RmlUi 项目资料，以及 AIO Hub `36fbcc6cb5bc9eb7691b3bf9d3e9bd5f3063d3d8`、SillyTavern `8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8` 的现有调查笔记
>
> 对比方法：按内容能力、流式生命周期、Godot 布局接入、输入、资源开销和不可信代码隔离统一比较；实现事实、架构推断和待原型验证项分别标注
>
> 对比范围：Godot 承担完整应用界面，普通 Markdown 与静态 HTML/CSS 由无脚本后端渲染，仅显式声明的可执行 LLM 内容块进入 Ultralight；不讨论把完整 Vue/SillyTavern 工作台嵌入游戏引擎
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

在上述边界内，这套架构具有较高可行性，而且比“Godot 场景加完整 Web 工作台”更符合游戏引擎的强项。Godot 可以拥有窗口、导航、消息列表、消息壳、输入框、主题、弹窗和所有业务状态；HTML 引擎只是消息文档中的局部渲染后端。绝大多数文本不进入浏览器运行时，Ultralight View 的数量由屏幕上正在交互的 JavaScript Artifact 决定，而不是由消息数量决定。

建议把消息渲染明确分为三层：

| 内容层 | 推荐后端 | 主要用途 | 不应承担的职责 |
|---|---|---|---|
| 原生内容 | Godot Control、RichTextLabel 和专用控件 | Markdown、代码、引用、表格、媒体、思考块、工具结果 | 任意 HTML/CSS 兼容 |
| 静态标记 | RmlUi、litehtml 或基于 Godot Control 的受控布局器 | 无脚本 HTML/CSS、角色卡样式化片段、较复杂文档布局 | JavaScript、宿主权限、完整浏览器行为 |
| 可执行 Artifact | Ultralight View 封装成普通 Godot Control | 明确声明需要 JavaScript 的小应用、Canvas、交互图表 | 主聊天 UI、普通 Markdown、默认自动执行模型输出 |

技术难点不在于“Godot 能否显示一张网页纹理”。Ultralight 官方就提供 CPU Surface 上传纹理和自定义 GPUDriver 两条游戏集成路径。真正需要提前定契约的是：三个后端共用同一份增量文档 IR；动态内容怎样把高度反馈给 Godot 列表；离屏 Artifact 怎样冻结和恢复；模型 JavaScript 怎样限制网络、文件、剪贴板和原生桥，并在死循环或内存失控时可被终止。

桌面原型可评为高可行。生产级桌面应用在完成进程隔离、长列表和输入验证后可评为中高可行。Ultralight 当前公开许可的 Free/Pro 档只覆盖 Windows、macOS、Linux，不覆盖移动端和主机；现有两个 Godot 集成项目也都有未完成项，因此不能把同一判断直接外推到 Godot 的全部导出平台。

## 1. 架构边界

### 1.1 Godot 是应用本体

主场景树可以保持为标准 Godot UI：

```text
ChatWorkspace (Control)
├─ Navigation / SessionSidebar
├─ MessageViewport
│  └─ VirtualMessageList
│     └─ MessageItem
│        ├─ Header / Actions
│        └─ MessageDocumentControl
│           ├─ NativeBlockControl
│           ├─ StaticMarkupControl
│           └─ JsArtifactControl
├─ Composer (TextEdit + native controls)
└─ Overlay / Dialog / Toast hosts
```

路由、焦点、快捷键、拖放、消息选择、编辑、生成状态和滚动锚定都由 Godot 持有。即使某条消息含有 Artifact，它也只是 `MessageDocumentControl` 中一个报告最小尺寸的子控件。这个边界避免 Web 页面反过来控制主应用窗口，也使普通聊天输入完全不依赖 Ultralight 的编辑和 IME 接入质量。

### 1.2 完整主链路

```text
LLM delta
  -> Replayable stream source
  -> incremental parser
       stable nodes + pending tail
  -> typed MessageDocument IR
       block id + revision + phase + capabilities
  -> renderer router
       native       -> Godot controls
       html-static  -> static markup backend
       html-app     -> JsArtifactControl / Ultralight
  -> height cache + virtual message list
  -> Godot viewport
```

三个后端不应各自读取原始消息再猜语法。解析、节点身份、完成状态、资源引用和用户动作先在共享 IR 中确定，后端只消费自己负责的节点。否则同一段流式输出可能在后端切换时重新挂载，导致折叠状态、选择状态、滚动位置和 Artifact 运行实例一起丢失。

## 2. 统一文档 IR 与内容分流

### 2.1 最小契约

IR 不必复刻完整 DOM，但至少需要表达以下信息：

```text
MessageDocument
  message_id
  revision
  phase: pending | complete | error
  blocks[]
    id
    kind: paragraph | code | table | media | html_static | html_app | ...
    phase: pending | stable | complete
    source_range
    payload
    capabilities
    content_hash
```

节点 ID 必须跨增量更新稳定，phase 用于区分仍可能被后续 token 改写的尾部和已经能安全复用的节点。`content_hash` 用于确认一个可执行 Artifact 的源码版本；消息被编辑或重新生成后，应创建新 revision，不在原 JavaScript 上热拼接未知代码。

AIO Hub 的现有实现可以提供思路：流来源与持久化正文分离，解析器维护 stable/pending 边界，Patch 层保留节点身份并合并高频文本追加。可复用的是这些状态和更新契约，不是 Vue 组件或 iframe 页面本身。相关机制见 [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)。

### 2.2 用显式类型选择执行面

不应搜索 `<script>` 来判断一段 HTML 是否“需要 JS”。活动内容还可能藏在事件属性、`javascript:` URL、SVG 事件、iframe、表单提交或后续载入资源中。反过来，包含脚本文本的代码示例也不应被执行。

建议在模型输出协议中提供两种明确围栏，解析后持久化为结构化 part：

````markdown
```html-static
<section class="character-sheet">...</section>
```

```html-app
<button id="roll">Roll</button>
<script>...</script>
```
````

普通 Markdown 中的原始 HTML 默认进入静态、清洗后的路径。`html-app` 才拥有申请可执行环境的资格；它仍不自动获得网络、文件、剪贴板或 Godot API。旧角色卡或旧消息没有显式类型时，可以提供兼容转换和用户预览，但不应通过启发式检测后静默执行。

分流单位应是完整 Artifact 块，不能把同一个 HTML 文档里的 `<script>` 单独剥给 Ultralight、再让另一个后端绘制它所操作的 DOM。一个 `html-app` 块的 HTML、CSS、JavaScript 和 Canvas 全部留在同一 View；同一条消息中位于块外的 Markdown、图片和静态片段仍由原生或静态后端承载。需要跨块影响整条消息样式或 DOM 的脚本不进入这套能力模型，除非把相关内容显式包装为同一个 Artifact。

### 2.3 流式阶段不运行半成品程序

普通文本和静态标记可以在 pending 尾部持续重排。可执行块则应采用提交语义：

1. 围栏未闭合时显示源码、轻量预览或“生成中”占位，不创建 View。
2. 围栏闭合后固定源码 hash，完成清洗和能力检查。
3. 默认由用户点击运行；受信任角色或本地模板可以单独允许自动运行。
4. 运行中的源码不接受 token 级热补丁。内容修订产生新实例，旧实例先销毁或冻结。
5. 控制台错误、加载失败和进程终止回流到该 block 的运行状态，不改写原始消息文本。

这个策略让流式解析仍然细腻，同时避免每个 delta 重载 JavaScript、重复注册事件、丢失局部状态或执行尚未闭合的标签。

## 3. 普通内容和静态 HTML/CSS 后端

### 3.1 后端比较

| 方案 | 输入模型 | 主要优势 | 主要代价 | 本架构中的位置 |
|---|---|---|---|---|
| Godot RichTextLabel | BBCode/结构化调用 | 与 Control、主题、输入和布局结合最直接；支持图片、表格、选择和滚动等常用富文本能力 | 不是 HTML/CSS；复杂布局需要转换或专用控件 | Markdown 默认后端 |
| 自定义 Godot Control | typed IR | 业务块、工具结果、媒体和交互可获得最一致的原生体验 | 每种语义都需实现测量、绘制和交互 | 高频、产品化节点 |
| RmlUi | RML/RCSS，语法类似 HTML/CSS | 宿主接收顶点、索引、纹理和绘制命令，适合接入游戏渲染管线；没有浏览器脚本运行时 | 不是任意网页兼容层；Godot 渲染、字体、输入和资源接口仍需接好 | 应用定义受控标记方言时优先评估 |
| litehtml | HTML/CSS 文档 | 专注解析与布局，没有 JavaScript；通过 `document_container` 让宿主决定字体、图片和绘制 | 宿主要补齐绘制、资源、选择、复制等产品能力；CSS 覆盖需实测 | 需要消费既有静态 HTML 时优先评估 |
| Ultralight | HTML/CSS/JS | 活动 Web 内容能力最完整，已有游戏纹理集成路径 | View、脚本生命周期和安全成本最高 | 只用于 `html-app` |

Godot 原生实现“近似 HTML/CSS 效果”是合理路线。聊天 Markdown 的常用结构很有限，标题、段落、列表、引用、表格、代码、图片和折叠块都可由 IR 映射到 RichTextLabel 或专用 Control。模型输出不需要先转成 HTML，再让另一个引擎还原这些语义。

RmlUi 与 litehtml 解决的是不同问题。若产品愿意定义一个可控的 HTML-like 方言，RmlUi 的宿主渲染接口更贴近游戏 UI。若需要兼容大量已经存在的静态 HTML/CSS 片段，litehtml 的输入模型更自然。首个原型应只选其中一个；渲染路由保留 adapter 接口即可，不宜一开始同时承担两套字体、资源、选择和 CSS 差异。

### 3.2 静态不等于可信

无 JavaScript 的 HTML/CSS 仍可能加载远端图片、使用 `@import`、创建表单或 iframe、覆盖大面积界面、构造超大布局并消耗 CPU/内存。静态后端之前仍需要结构化清洗和资源策略：

- 删除事件属性、脚本协议、iframe、object、embed、表单提交和不支持的 SVG 活动元素。
- CSS 只允许已实现的属性，拒绝 `position: fixed/sticky`、超大尺寸和逃逸消息边界的定位。
- URL 先归一化，再交给统一 ResourceResolver；默认只开放消息附件、应用资产和经策略允许的 HTTPS 资源。
- 字体、图片和媒体异步就绪后，通过 block ID 触发尺寸失效，不能直接在列表中任意改写滚动位置。
- 每个静态块有样式根和主题变量映射，不允许模型样式命中 Godot 主界面或相邻消息。

这里追求的是视觉和文档语义的近似，不是浏览器像素级一致。角色卡样式、旧 CSS 预设和复杂表格需要用一组真实语料做截图对比，才能决定 RmlUi、litehtml 或自定义 Control 的覆盖比例。

## 4. Ultralight 作为 JsArtifactControl

### 4.1 显示路径

Ultralight 官方游戏集成文档给出两条路径：CPU renderer 把 View 绘制到 Surface，宿主在 dirty bounds 变化时把 BGRA 预乘 alpha 像素上传为纹理；GPU renderer 则由宿主实现较低层的 GPUDriver。前者最适合验证架构，后者适合在大量路径、图片或动画确实成为瓶颈后再评估。

Godot 侧可以把一个活动块封装为 `JsArtifactControl`：

```text
Ultralight Renderer singleton
  -> one View per active Artifact
  -> Surface / dirty bounds
  -> Godot ImageTexture
  -> JsArtifactControl draws texture
  -> Godot input translated back to View events
```

现有 [Godot-HTML](https://github.com/Decapitated/Godot-HTML) 已证明 Godot 4.3+ GDExtension、Ultralight 1.4、鼠标键盘输入和 JavaScript/GDScript 互操作可以接通。其项目清单仍把 GPU 加速 View、RenderTarget/ImageSource 和远端页面对 C++ bridge 的隔离列为未完成项，因此它更适合作为原型基础和实现参考，尚不能直接视为完整生产组件。

### 4.2 尺寸握手

Artifact 必须像普通 Control 一样参与消息布局，不能成为悬浮在聊天表面之上的独立窗口。建议尺寸协议如下：

1. Godot 父容器确定可用逻辑宽度，并结合 DPI 得到 View 像素宽度。
2. `JsArtifactControl` 调整 View 尺寸，文档随宽度重排。
3. 页面中的受控 bootstrap 用 ResizeObserver 或宿主求值读取文档高度。
4. 高度经过节流、像素取整和小幅抖动阈值后，更新 Control 的最小高度。
5. 高度超过策略上限后固定外部高度，Artifact 内部滚动。

需要防止“宽度变化 -> 出现滚动条 -> 可用宽度变化 -> 高度变化”的反馈环。列表高度缓存以 block revision 和宽度区间为键；异步高度变化时保留当前视口锚点。折叠 Artifact、切换主题和字体就绪都应走同一条尺寸失效通道。

### 4.3 输入与焦点

Godot 要把鼠标移动、按下、滚轮、键盘和焦点事件转换到 View 坐标，同时处理 DPI、裁剪和消息列表滚动偏移。还需明确光标形状、剪贴板、Tab 焦点、弹出菜单、链接打开、文件选择和拖放由谁接管。

主 Composer 使用 Godot TextEdit。Godot 文档公开了 IME 应用/取消、选区、剪贴板和虚拟键盘等接口，因此主聊天输入不会被 Ultralight 集成中的 CJK IME 缺口阻塞。Artifact 内部若允许 input、textarea 或 contenteditable，则仍需单独验证组合输入、候选窗位置、选区和剪贴板；现有 Godot 集成项目的资料不足以证明这些路径已经完整。

### 4.4 View 数量和冻结

不应为历史上的每个 `html-app` 常驻一个 View。建议原型从“只有可见且已展开的 Artifact 才活动”开始，并记录创建耗时、峰值内存和切换抖动。2 至 4 个活动实例可作为最初的测试上限，不是未经基准即可写死的产品常量。

离屏后可按以下层级降级：

| 状态 | 保存内容 | 资源行为 |
|---|---|---|
| active | View、JS heap、纹理 | 正常 Update/Render 和输入 |
| suspended | View 与状态，停止可见帧刷新 | 仅在策略允许时处理计时器 |
| frozen | 最近纹理快照、源码 revision、可选业务状态 | 销毁 View，Godot 显示静态纹理 |
| disposed | 源码和消息元数据 | 再次展开时全新运行 |

从 frozen 恢复默认是重新运行，并向用户显示状态已重置。只有 Artifact 自己通过受控协议导出纯数据状态时，才尝试恢复；不能序列化任意 JS heap。View 池若存在，也必须清空页面、存储、历史和 bridge，避免不同消息之间继承状态。

## 5. JavaScript Artifact 的安全边界

### 5.1 同进程限制不足以处理不可信代码

DOM 清洗可以限制静态标记，却不能让任意 JavaScript 变可信。即使页面没有 Godot bridge，死循环、内存扩张、定时器风暴、超大 Canvas 和解码负载仍可能拖慢或终止宿主进程。把 Ultralight 作为 GDExtension 直接装进主进程，适合可信模板和早期原型，不构成对模型生成代码的强隔离。

生产级建议把 Artifact renderer 放到独立受限进程。Godot 通过 IPC 发送源码、视口尺寸和输入事件，渲染进程返回像素帧、dirty rect、光标和经过白名单的业务消息。进程应有内存/CPU 限额、超时和强制终止能力；网络、文件和子进程在操作系统层默认禁止。单个 Artifact 失控时，宿主显示错误卡和重新运行按钮，主聊天与未保存输入仍然存活。

### 5.2 能力模型

推荐把权限分成宿主可审计的消息，而不是向页面注入宽泛原生对象：

| 能力 | 默认 | 开放方式 |
|---|---|---|
| 本地消息内 DOM/Canvas/计时器 | 允许 | Artifact 自身使用 |
| 读取随消息附带的只读资产 | 允许白名单 | 虚拟 scheme + 内容 hash |
| 外部 HTTPS 请求 | 禁止 | 用户或模板按域名授权，宿主代理 |
| 打开外部链接 | 询问 | 发送 URL 给 Godot 校验并调用系统浏览器 |
| 剪贴板写入 | 询问或仅手势触发 | 发送纯文本请求给 Godot |
| 文件读写、shell、Godot 对象访问 | 禁止 | 不提供通用桥；具体业务另做窄接口 |
| 持久化 | 每 Artifact 配额、独立命名空间 | 只存 JSON/Blob，不能共享应用凭据 |

每个 Artifact 应使用独立 origin 或存储命名空间，不继承登录态、cookie 或其他消息的数据。CSP 可以作为补充，但不能替代宿主资源策略和进程隔离。

Ultralight 的 2026 年定价页明确写明：Free 档没有 Network Request Filter、没有 JavaScript JIT、渲染上限 60 FPS，并限制为年营业额和融资均低于 10 万美元的独立开发者；Pro 为每应用每年 3000 美元且只面向年营业额低于 1000 万美元的小公司。若设计依赖 Network Request Filter 实现域名拦截，Free SDK 不能满足该方案；是否存在足以实现“完全禁网”的其他底层路径，仍需在所选 SDK 版本中验证。独立进程的操作系统网络限制可以减少对该 API 的依赖。

定价页还把 Free/Pro 定义为 application use only，并限制在商业引擎、库或插件中再分发。把 Ultralight 链入最终应用，与把 Godot 集成层作为通用插件分发，不应视为同一个许可场景。正式产品和可复用集成项目都应以签约时的许可文本为准。

## 6. AIO Hub 与 SillyTavern 的可复用边界

### 6.1 AIO Hub

AIO Hub 对本方案最有价值的是消息渲染器的生命周期经验：

- `ReplayableMessageStreamSource` 隔离高频流与持久化消息。
- stable/pending AST 让已稳定节点保留身份，只重解析尾部。
- Patch 队列节流并合并连续文本追加。
- HTML 预览等待内容稳定、回传高度和错误，并按消息深度冻结旧实例。
- 测试台使用真实流源和生产渲染器观察节点状态、复杂混排和样式逃逸。

这些机制可以迁移成语言无关的 MessageDocument 与 renderer lifecycle。Vue AST renderer、CodeMirror 和 iframe 则不需要进入 Godot。AIO 当前活动 HTML 使用允许 scripts、same-origin、forms、popups 和 modals 的 iframe，宿主 CSP 关闭，不能直接充当本方案的不可信 JavaScript 安全基线。

### 6.2 SillyTavern

SillyTavern 说明酒馆生态确实需要兼容原始 HTML、消息级 CSS、正则改写、reasoning、媒体和扩展事件。它适合提供真实语料和兼容性测试维度。当前主链把累计全文反复经过 Showdown、DOMPurify 和 CSS 作用域改写，再覆盖主文档 DOM；这种字符串和 DOM 生命周期不适合直接移入 Godot。

可借鉴的是“格式化顺序本身属于协议”的认识。若要导入 SillyTavern 角色卡或消息，兼容层应先固定宏、正则、Markdown、HTML 清洗和 CSS 改写的顺序，再产出统一 IR；不能让三个渲染后端各自实现一份近似顺序。现有实现依据见 [`../消息渲染器/SillyTavern-消息渲染调查笔记.md`](../消息渲染器/SillyTavern-消息渲染调查笔记.md)。

## 7. 建议的最小原型顺序

### 阶段一：先证明统一消息文档

- 定义 typed IR、稳定 block ID、pending/stable/complete 生命周期和 revision。
- 用 AIO/SillyTavern 的代表性 Markdown、HTML、样式、代码围栏和残缺流构建固定语料。
- 实现 Godot 原生 Markdown 子集、流式追加和消息列表高度缓存。
- 验证复制、链接、图片异步加载、折叠块和滚动锚定。

这一阶段不接 Ultralight。若原生消息在长回复流式更新时已经频繁重排或跳动，引入 Web View 只会放大问题。

### 阶段二：只选一个静态布局后端

- 选择 RmlUi 或 litehtml，实现统一的 measure、mount、update、dispose 和 resource resolver adapter。
- 先支持固定白名单的标签与 CSS 属性，不追求浏览器全集。
- 对真实角色卡和消息片段做 Godot 截图与浏览器参考图对照。
- 记录字体回退、中文断行、表格、图片、选择复制和主题切换差异。

选择标准不是演示页能否显示，而是目标语料中有多少内容无需降级、错误是否可见、宿主补齐交互的成本是否可控。

### 阶段三：接入单个 Ultralight Artifact

- 先用 CPU Surface 和 ImageTexture，完成 dirty bounds 上传。
- 测试 Counter、Canvas 动画、DOM 动态增高、内部滚动、链接和表单输入。
- 打通 Godot 宽度到 View、文档高度回到 Control 的双向协议。
- 实现 focus、鼠标捕获、DPI、键盘和关闭时资源释放。
- 同时记录包体、首次创建时间、单 View 增量内存、空闲 CPU 和动画帧成本。

### 阶段四：做失控测试再决定进程模型

- 无限循环、递归定时器、内存扩张、超大 Canvas、解码炸弹和频繁 resize。
- 验证网络、file URL、虚拟文件系统、剪贴板、外链和 bridge 均按默认拒绝执行。
- 创建/销毁大量 revision，检查 View、纹理和 JavaScript 状态是否泄漏。
- 冻结离屏实例并恢复，验证快照清晰度、状态提示和列表滚动稳定性。
- 主动杀死 renderer，确认 Godot 主界面和 Composer 不受影响。

只有最后一项成立，才证明它是“不可信 LLM Artifact 后端”；否则它只是能显示可信网页的小型嵌入组件。

## 8. 当前项目与依赖成熟度

| 对象 | 已确认能力 | 当前边界 |
|---|---|---|
| Godot RichTextLabel | BBCode、图片、表格、选择、滚动跟随、线程化处理等 | HTML/CSS 需转换；复杂消息列表仍需自行做生命周期管理 |
| Godot TextEdit | IME、选区、剪贴板、虚拟键盘等公开接口 | 只能证明 Godot 主输入具备接入面，目标平台体验仍需运行验证 |
| RmlUi | MIT；宿主实现 RenderInterface，消费顶点、索引、纹理和绘制命令；提供 IME 接入说明 | 语法和 CSS 兼容不等于浏览器；Godot-RmlUi 的字体、编辑器和部分平台支持仍未完成 |
| litehtml | New BSD；HTML/CSS 布局库，无 JavaScript，宿主实现 document_container | 没有现成的完整 Godot 产品层；绘制、资源和交互工作量由宿主承担 |
| Ultralight | CPU Surface 和 GPUDriver 两条游戏接入路径，支持 HTML/CSS/JS 与原生互操作 | 许可、平台、输入、安全和性能均需按 SDK 档位验证 |
| Godot-HTML | Godot 4.3+、Ultralight 1.4 GDExtension；已有基本显示、输入和互操作 | GPU View、Godot RenderTarget/ImageSource、远端页面 bridge 隔离仍列为待办 |
| Godot-RmlUi | 已有 Canvas 基础绘制、Godot 文件/纹理、GUI 输入和 GDScript 事件 | 字体系统、编辑器以及 macOS/Linux 状态仍列为未完成 |

已有集成项目足以降低“能否连起来”的技术不确定性，却没有消除维护风险。正式选型前要确认最近提交、目标 Godot/SDK 版本、平台构建、许可证以及项目是否仍活跃；本次没有在目标应用中编译或运行这些扩展。

## 9. 未验证事项

- Godot 原生 Markdown、RmlUi 和 litehtml 在目标中文/日文/emoji 字体栈上的字形、断行和选择一致性。
- 静态 HTML/CSS 真实语料覆盖率，以及从浏览器 CSS 降级到所选后端时的可接受差异。
- Godot-HTML 在目标 Godot 版本、渲染后端和 Windows/macOS/Linux 打包环境中的构建状态。
- Ultralight View 创建/销毁成本、每实例内存、dirty rect 上传成本和透明混合表现。
- Artifact 内 CJK IME、候选窗、辅助功能树、屏幕阅读器和触摸输入。
- Free SDK 下彻底禁用网络的可用机制，以及 Pro Request Filter 的精确语义。
- 独立 renderer 进程的可分发许可、GPU 共享纹理可行性和崩溃恢复延迟。
- Godot 自定义虚拟消息列表在动态高度、历史加载、分支切换和异步媒体更新下的滚动锚定。

## 10. 资料索引

### 官方与项目资料

- [Godot RichTextLabel](https://docs.godotengine.org/en/stable/classes/class_richtextlabel.html)
- [Godot TextEdit](https://docs.godotengine.org/en/stable/classes/class_textedit.html)
- [RmlUi 文档](https://mikke89.github.io/RmlUiDoc/)
- [RmlUi RenderInterface](https://mikke89.github.io/RmlUiDoc/pages/cpp_manual/interfaces/render.html)
- [RmlUi IME 接入](https://mikke89.github.io/RmlUiDoc/pages/cpp_manual/ime.html)
- [litehtml](https://github.com/litehtml/litehtml)
- [Ultralight 游戏集成](https://docs.ultralig.ht/docs/integrating-with-games)
- [Ultralight 定价与许可档位](https://ultralig.ht/pricing)
- [Godot-HTML](https://github.com/Decapitated/Godot-HTML)
- [Godot-RmlUi](https://github.com/ashifolfi/Godot-RmlUi)

### 本地调查依据

- [`../消息渲染器/AIO-Hub-消息渲染器调查笔记.md`](../消息渲染器/AIO-Hub-消息渲染器调查笔记.md)
- [`../消息渲染器/SillyTavern-消息渲染调查笔记.md`](../消息渲染器/SillyTavern-消息渲染调查笔记.md)
