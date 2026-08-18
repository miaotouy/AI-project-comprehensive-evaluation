# DeepSeek-Harness 对话导出与分享调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`
>
> 调查更新日期：2026-08-16
>
> 代码快照：`47f943859bef60e4160492346772ded9b24f765a`（分支：`master`）
>
> 调查方式：静态源码阅读；读取 `packages/session-query/session-log-export` 的浏览器插件与 `/export` 命令、`packages/host/apiproxy` 的下载端点与流式 ZIP 实现、`packages/session/session-persistence` 的 raw artifact 契约与 JSONL 后端、`packages/session-query/session-query` 的血缘追踪与表面折叠、`packages/core/session` 的 surface 与消息派生、spill/attachment 存储、apps/cli 与 apps/web、session-telemetry，以及相关单元测试与 Web e2e；未运行应用
>
> 调查范围：ZIP 导出的入口、导出源与内容口径、附件与 spill 处理、格式与往返、隐私与失败语义、transcript 派生机制、CLI 与 Web 的导出/分享入口检索；排除：会话 CRUD 与压缩机制本体、会话查询工具面向模型的消费路径、telemetry 后端 SDK 的批次与重试行为
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek-Harness 的对话交付能力收敛为一条浏览器下载链路，属于 `E1 数据交换`：

- **唯一导出能力是 Web 端“Session log”下载**：会话头按钮与 `/export` 斜杠命令共用同一个浏览器下载控制器，先 `HEAD` 预检，再让浏览器下载管理器接管 `GET /api/session.export`，得到流式 ZIP。该端点只在 Web bundle 挂载，是 host 专属下载面（无 RPC 信封），UI 侧不缓冲 ZIP 字节（`session-log-export/src/client/controller.ts:111-130`）。
- **ZIP 内容是持久化工件的逐字原文**：每个会话的日志文件以 `session.jsonl` 原始文件名进入归档（`readRaw` 解码后的确切字节，绝不从解析后事件重建），子代理后代放在 `subagents/<id>/` 下，被引用图片按内容寻址去重后放在 `media/<attachmentId>.<ext>` 下，不写 manifest（`host/apiproxy/src/session-export.ts:1-20`）。浏览器恒定传 `includeDescendants=true`，覆盖整棵后代会话树，但不包含祖先会话。
- **内容口径是“全量原始日志”**：ZIP 携带全部事件原文（含 reasoning、工具调用与结果、usage、被替换遮蔽的节点），不做过滤、脱敏或重建；这与 UI 实时对话视图（基于 surface 折叠的派生消息）是两条不同的数据路径。
- **没有分享能力**：在 `packages/` 与 `apps/` 按 gist、navigator.share、分享等关键词检索均未见产品级分享功能；无 URL、远端对象、访问控制或撤销语义。交付物是本地文件，目标是个人存档与迁移，不面向人际传播或公开发布。
- **导出格式即持久化格式**：ZIP 内就是后端落盘的那份 JSONL 文本，头行 `type:"session"` 携带 `version`，无独立导出 schema。往返语义等于“把文件放回持久化路径即可被后端重新读取”，客户端没有任何导入入口。
- **CLI 无会话导出**：`--dump-config`/`--dump-default-config` 是配置组合诊断（打印 profile 装配树，与对话无关），`apps/cli/reference/` 是 CLI 行为参考文档而非命令；headless 单次任务把最后一条助手文本打印到 stdout，属于终端交付而非文件导出。
- **邻接能力**：`dsh-session-telemetry` 以 `full | feedback-only | disabled` 三种共享策略把会话事件投影交给 OTel 后端，属于观测/研究方向的会话数据交接，与用户可见的对话导出分属两条管线，本次只记录边界。

## 系统边界与完整主链

```text
事实源：SessionStore 内存日志 + sessionPersistence 的每会话 JSONL artifact
  （<root>/<项目key>/<会话id段>/session.jsonl，物理可为 .jsonl.zstd）
  ├─ Web 会话头 "Session log" 按钮 ─────────┐
  ├─ Web 斜杠命令 /export ──────────────────┤
  │                                          ▼
  │                    SessionLogDownloadController（浏览器，每会话一个 in-flight 下载）
  │                    HEAD /api/session.export?sessionId=<id>&includeDescendants=true
  │                    成功 → 把 GET URL 交给浏览器下载管理器（不缓冲字节）
  ▼
  Host：fetch handler 直接路由 GET/HEAD /api/session.export（无信封）
  ├─ 缺服务 → 500；后端无 raw artifact → 501；根会话缺失 → 404
  ├─ SessionStore.flush 持久化屏障 → readRaw 读逐字文本
  ├─ sessionQuery.traceSession 取后代血缘 → 逐个 flush + readRaw
  ├─ 解析各 artifact 行内 image 引用 → attachments.readImage 读字节
  └─ fflate 流式 Zip（压缩级别 0-9，默认 6）→ chunked Response
      根 session.jsonl → subagents/<id>/session.jsonl → media/<attachmentId>.<ext>
```

浏览器侧的另一条读取链（实时对话视图）不经过导出：UI 通过 `sessions` 域 RPC 读历史页（原始事件 + 宿主计算的渲染意图），派生消息由客户端从事件重建。导出 ZIP 与 UI 视图共享同一份持久化日志，但一个给原文、一个给派生视图。

## 1. 入口、用户目标与导出源

两个入口共享同一个下载控制器与同一个模态框（`session-log-export/src/client/index.ts:37-49`）：

- 会话头右侧的 `Session log` 按钮（带下载图标，注册进 `conversation.session.header.utilities` 槽位），点击直接发起下载（`HeaderAction.tsx`）。
- 斜杠命令 `/export`：宿主注册于 `session-log-export/src/index.ts:19-25`，带参数时返回错误（“不接受路径”）；本地 `command/executed` 事件在 `result.kind === 'success'` 时才触发下载，其他浏览器标签页只渲染 durable 命令行、不重复下载（e2e 验证：观察者标签页下载数为 0）。

导出粒度只有“整会话树”一个级别：根会话 + 全部子代理后代（fork/subagent 形成的 `parentSession` 血缘），无单消息、连续范围、选区或批量会话入口（在 `packages/` 检索 export 类命令只命中本命令）。ZIP 条目顺序为：根 artifact → 后代按血缘先序 → 全部去重后的媒体对象（`session-export.ts:203-266`）。

## 2. 范围选择、内容口径与字段过滤

内容口径是“持久化原始数据”，且是后端物理编码解码后的**逐字文本**，不是事件重建：JSONL 后端的 `readRaw` 把文件字节（zstd 先逐帧解码）按 UTF-8 还原，并校验头行与 id（`session-persistence-jsonl/src/index.ts:252-282`）。因此：

- 所有事件类型全量保留，包括 reasoning、流式 chunk、usage、错误、turn 边界、被 surface 替换遮蔽的旧节点——导出不做 surface 状态过滤，也不做字段裁剪。
- 后端特有的序列化也保留：chunk 打包存储行（`text-chunks` 等）按写入字节原样存在，导入后仍可被布局无关的读取端解码。
- 与“人类 transcript”的区别：核心会话模块的 surface 折叠（`core/session/src/surface.ts`）把事件分为 append-origin（进入用户已见对话）与 replacement（仅模型可见）两类，`deriveMessages()` 只从 surface 节点派生模型消息；而 ZIP 导出的是整个事件日志，两类事件都在其中，没有按此区分。
- 无明显“隐藏内容”过滤：被压缩/替换掉的节点以事件原文存在于 artifact，导出时原样带出。UI 的过滤是查看侧行为，导出侧不存在。

## 3. 附件、资源与离线封装

- 图片附件是唯一被导出的非文本资源。事件数据中 `type:"image"` 内容块携带附件引用（id 与媒体类型），导出端在每行 artifact 文本的多种载体（直接 content、消息 content、插入消息、assistant 块）里收集引用并去重，再从附件存储按引用读出并校验字节，写入 `media/<attachmentId>.<ext>`（`session-export.ts:117-178,260-265`）。扩展名白名单为 png/jpg/webp/gif。
- 附件存储是 `$DSH_HOME/attachments/v1/objects/<sha256前2位>/<sha256>` 内容寻址目录（`attachment-local/src/index.ts:53`），同一图片被多个会话引用时归档中只出现一次。
- spill 长文本（工具超长输出的落盘文件）**不在导出范围内**：spill 存于私有 0700 的进程临时目录 `session-<hash>/<随机>-<安全名>`（`spill-local/src/store.ts:20-28,75-111`），会话日志里只留模型可见的定位符文本（SpillLocator 与取回指引），ZIP 不收集 spill 文件本体；日志文本中原样出现的本地路径、远端 URL 保持为文本，不转换、不内联。
- 归档自带自描述：无 manifest，每个文件要么是带自身头行的会话日志，要么以 `media/<id>.<ext>` 路径与日志内的引用对应；ZIP 是本地单文件，离线可打开。

## 4. 格式、schema 与往返能力

- 交付格式只有 ZIP 容器内的 JSONL 一种。全仓检索 `pdf`、`toPng`、`html2canvas`、`jspdf` 均无命中，未发现 Markdown/HTML/PDF/PNG 导出或打印链路。
- 无独立导出 schema 版本：JSONL 头行即持久化头行（`type:"session"` 携带 `version`、id、createdAt 及血缘、预设等可选字段，见 `session-persistence-jsonl/src/format.ts:51-64`）；会话格式版本当前保持 `0`，仓库明确不作兼容承诺（根 AGENTS.md）。
- 往返：导出物就是持久化格式本身的字节副本，放回 `<root>/<项目key>/<会话id段>/session.jsonl` 布局即可被 JSONL 后端重新读取（布局见 `format.ts:176-208`，测试 `jsonl.spec.ts:1229-1241` 验证 session 专属目录的可扩展性）。仓库内没有任何用户级导入命令或 `session.import` RPC（检索无命中）；往返完全发生在文件系统层。
- 依赖约束：导出需要持久化、session-query、附件三个服务同时挂载，且持久化后端必须声明 `supportsRawArtifacts`（当前只有 JSONL 后端实现）；SQLite 后端没有 per-session 原始工件，部署时端点返回 501（`api-proxy.ts:3644-3656`）。

## 5. 分享稿编辑、编排与预览

不适用。不存在区别于聊天现场的分享稿编辑器：没有选区、内容开关、布局/主题/水印等导出前编排，没有预览步骤。模态框只报告“准备中 / 下载已开始 / 失败”三种状态（`Dialog.tsx`），不提供任何内容控制。

## 6. 图片、HTML、PDF 与富内容生成

不适用。导出不产生 HTML/PDF/图片等阅读交付物，也没有离屏渲染或截图链路；唯一的“富内容”处理是 ZIP 内媒体条目按字节原样打包，日志文本原样压缩。

## 7. 生成历史、版本与持久化

不适用。每次下载都是对当前持久化状态的新副本，覆盖/追加语义、旧版本保留、重新生成比较等概念均未出现；浏览器侧不记录下载历史，host 侧也不保留导出日志。`command/run` 与 `command/done` 成对事件进入会话日志（斜杠触发时先 flush 再读取，所以同一 ZIP 里包含触发它的命令记录），这是日志事实，不是导出版本管理。

## 8. 分享载体、访问控制与撤销

本次未找到任何分享形态。在 `packages/` 与 `apps/` 下检索分享相关关键词（gist、navigator.share、ShareSheet、分享、shareUrl、shareLink 等，排除 register 子串误报）均无命中；host 下载域只有 `sessionLog` 一个方法（`api/downloads.ts`），fetch 层只对 `/api/session.export` 开放 GET/HEAD。结论：本项目只交付浏览器本地下载文件，无远端快照、公开页面、受控链接或剪贴板分享，也就没有访问控制、撤销、过期、克隆等治理语义。浏览器下载的文件最终落在用户本机（下载目的地在浏览器侧选择，host 不返回文件路径，README 明确此限制）。

## 9. 隐私、安全与内容治理

- 导出前无隐私提示、无脱敏、无内容确认：ZIP 原样携带全部事件文本，可能包含文件路径、bash 输出、read 出的文件内容等（与 telemetry 的“无内置脱敏规则”性质类似，但导出侧连脱敏扩展点都没有）。
- 输入侧有基础硬化：会话 id 在生成归档文件名与 `subagents/<id>/` 路径段时做字符清洗（非字母数字 `_-` 一律替换为 `_`，`session-export.ts:190-201`），防止 `../` 等路径形塑归档条目；错误响应不回显异常原文（准备失败统一返回固定文案，避免把绝对路径带进浏览器错误条，`api-proxy.ts:3668-3672`）。
- 媒体扩展名走白名单映射，未知媒体类型不会产出任意后缀的条目（`session-export.ts:93-98`）。

## 10. 性能、失败恢复与测试

- 内存边界：ZIP 用 fflate 流式压缩，host 从不持有完整归档；响应队列 64 KiB 高水位，生产端按 16 KiB 码元/字节分块 push 并等待消费拉取（文本分块避免在 surrogate pair 中间切分），慢消费者只累积固定量（`session-export.ts:268-456`）。
- 失败语义：准备期失败（缺服务/缺根会话）在流开始前以 500/404 干净应答，`HEAD` 预检让浏览器在交出 GET 前发现这些失败；流中失败（后代缺 artifact、图片读失败、取消）fail-loud——终止压缩器并让下载失败，绝不静默少导出（README 与 `session-export.ts:435-441`）。
- 取消：请求 abort 与响应消费取消共用一个生产信号，同时终止活跃压缩器并以取消（而非 500）传播；浏览器侧每会话只允许一个 in-flight 下载，重复手势共享同一操作，关闭模态不取消下载，插件 dispose 时中止预检并等待归零（`controller.ts:78-129`）。
- 测试：`host/apiproxy/tests/session-export.spec.ts` 覆盖根 artifact 逐字、HEAD 预检、后代条目、live flush、媒体收集与去重、压缩级别、取消与 fail-loud；Web e2e `apps/web/tests/navigation-panes.e2e.ts:291-369` 用真实 host 流验证按钮与 `/export` 双入口产出同一 ZIP（无后代/图片时恰含一个 `session.jsonl`，内容含种子会话 id），并验证斜杠触发时 ZIP 内含对应的命令记录对。

## 11. 设计取舍与已确认边界

- **导出即持久化快照，不是派生物**：选择把后端工件逐字打包，保真最高（分支、压缩、替换、序列化细节全部保留），代价是消费方需要自己解析 JSONL；没有面向人读的转换层。
- **导出与分享解耦**：浏览器下载只负责“拿到文件”，分享、查看器、访问治理全部不存在——这与 Pi 的“导出 HTML + Gist 链接分享”路线形成对照：本项目的交付边界停在文件系统。
- **host/浏览器职责分工**：host 负责流式压缩与字节生产（同源 `/api` 路由、无信封），浏览器负责预检、保存与模态反馈；`IApiClient` 不暴露下载方法，外部进程拿不到这条路径（`api/downloads.ts:1-6`）。
- **内容口径的全量性**：导出包含被 surface 遮蔽的旧节点与压缩摘要源事件，这是“可重建任何时刻状态”的设计取向；对只想看当前对话的用户来说，ZIP 比可见对话更大且更敏感。
- 后端耦合：导出能力依赖持久化后端的 raw artifact 存在，SQLite 部署下该功能整体不可用（501），这是已声明的边界（README Known Limitations）。

## 12. 未验证事项

- 浏览器下载管理器的实际行为：GET 流中失败（后代/媒体读取错误）由浏览器报告而非模态框，其具体呈现未运行验证。
- 大会话、大图片下的下载耗时、内存峰值与浏览器兼容性（README 声明了设计边界，无运行数据）。
- SQLite 后端部署下的 501 实测表现与错误文案展示。
- `HEAD` 预检与 GET 之间日志继续增长时，两次读取字节不一致的窗口行为（实现读取两遍，但无运行验证）。
- telemetry 导出的 OTel 后端行为、批次与重试策略（仓库外 SDK 职责）。
- ZIP 内条目在中文文件名、非 UTF-8 系统上的解压兼容性（附件扩展名来自白名单，会话 id 已清洗，推测安全，未验证）。

## 13. 关键源码索引

- `packages/session-query/session-log-export/src/client/index.ts`（插件装配、`command/executed` 触发下载、槽位注册）
- `packages/session-query/session-log-export/src/client/controller.ts`（HEAD 预检、每会话单 in-flight、取消与 dispose）
- `packages/session-query/session-log-export/src/index.ts`（`/export` 命令注册与参数拒绝）
- `packages/session-query/session-log-export/src/client/HeaderAction.tsx` / `Dialog.tsx`（按钮与模态）
- `packages/host/apiproxy/src/session-export.ts`（ZIP 条目生成、媒体收集、分块流、容量门）
- `packages/host/apiproxy/src/api-proxy.ts:3640-3693`（`downloads.sessionLog`：错误路径、flush、501/404）
- `packages/host/apiproxy/src/fetch/handler.ts:260-271`（GET/HEAD 直通路由）
- `packages/host/apiproxy/src/api/downloads.ts` / `downloads.schema.ts`（下载域契约与查询参数校验）
- `packages/session/session-persistence/src/index.ts`（`SessionRawArtifact`、`readRaw`、`supportsRawArtifacts` 契约）
- `packages/session/session-persistence-jsonl/src/index.ts:252-282`（JSONL `readRaw` 逐字读取）与 `src/format.ts`（头行、路径布局）
- `packages/session-query/session-query/src/tracing.ts`（`traceSession` 祖先/后代血缘）
- `packages/core/session/src/surface.ts`（append-origin 与 replacement、`foldSurface`）与 `src/index.ts:726-747`（`deriveMessages`）
- `packages/attachment/attachment-local/src/store.ts`（内容寻址存储）与 `packages/spill/spill-local/src/store.ts`（spill 私有目录）
- `apps/cli/src/args.ts` + `dump-config.ts`（CLI 模式：profile/dump-config/plugin/web，无会话导出）与 `apps/cli/reference/README.md`
- `packages/bundle/headless/src/index.ts`（stdout 打印最后助手文本）
- `packages/bundle/web-app/cordis.patch.yml:69-71`（Web bundle 挂载导出插件）
- `packages/session/session-telemetry/README.md`（共享策略与脱敏瀑布，邻接能力）
- `packages/host/apiproxy/tests/session-export.spec.ts`、`apps/web/tests/navigation-panes.e2e.ts:291-369`（测试证据）
