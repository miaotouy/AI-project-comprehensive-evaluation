# DeepSeek-Harness 对话导出与分享调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`0d1f50007f9bca3f52b06e1c3074fa14d5fb0720`（分支：`master`）
>
> 调查方式：静态源码阅读；读取 `packages/session-query/session-log-export` 的浏览器控制器、Fetch 路由与流式 ZIP 实现，核对 persistence read handle、session-query 血缘、surface 派生、附件/文件存储、CLI/Web 入口及相关测试；未运行应用
>
> 调查范围：ZIP 导出的入口、导出源与内容口径、附件与 spill 处理、格式与往返、隐私与失败语义、transcript 派生机制、CLI 与 Web 的导出/分享入口检索；排除：会话 CRUD 与压缩机制本体、会话查询工具面向模型的消费路径、telemetry 后端 SDK 的批次与重试行为
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek-Harness 的对话交付能力收敛为一条浏览器下载链路，属于 `E1 数据交换`：

- **唯一导出能力是 Web 端“Session log”下载**：会话头按钮与 `/export` 斜杠命令共用同一个浏览器下载控制器，先 `HEAD` 预检，再让浏览器下载管理器接管 `GET /api/session.export`，得到流式 ZIP。该端点只在 Web bundle 挂载，是 host 专属下载面（无 RPC 信封），UI 侧不缓冲 ZIP 字节（`session-log-export/src/client/controller.ts:111-130`）。
- **ZIP 内容改为从 persistence read handle 序列化当前逻辑日志**：不再要求后端暴露 raw artifact，也不保证逐字保留物理压缩或旧代编码。每个会话采用当前代规范文件名，后代放在子目录；图片写入 `media/`，通用上传文件按 digest 路径写入 `files/`，大文件以有界块压缩（`packages/session-query/session-log-export/src/archive.ts`）。
- **内容口径是当前逻辑事件全量**：仍包含 reasoning、工具调用与结果、usage 和被 surface 遮蔽的节点，不做对话级过滤或脱敏；但旧格式会先迁移到当前逻辑表示，因此不能再把归档描述为存储工件的逐字副本。
- **没有分享能力**：在 `packages/` 与 `apps/` 按 gist、navigator.share、分享等关键词检索均未见产品级分享功能；无 URL、远端对象、访问控制或撤销语义。交付物是本地文件，本次检索未找到任何分享或发布入口，可见用途限于个人存档与迁移。
- **导出格式使用当前会话格式**：文件名随当前版本为 `session.v3.jsonl`，事件由 handle 读出后编码；没有用户级导入入口，也不能再声称把 ZIP 文件原位放回即可逐字恢复旧介质布局。
- **CLI 无会话导出**：`--dump-config`/`--dump-default-config` 是配置组合诊断（打印 profile 装配树，与对话无关），`apps/cli/reference/` 是 CLI 行为参考文档而非命令；headless 单次任务把最后一条助手文本打印到 stdout，属于终端交付而非文件导出。
- **邻接能力**：`dsh-session-telemetry` 以 `full | feedback-only | disabled` 三种共享策略把会话事件投影交给 OTel 后端，属于观测/研究方向的会话数据交接，与用户可见的对话导出分属两条管线，本次只记录边界。

## 系统边界与完整主链

```text
事实源：活动 Session + persistence read handle 返回的逻辑事件
  ├─ Web 会话头 "Session log" 按钮 ─────────┐
  ├─ Web 斜杠命令 /export ──────────────────┤
  │                                          ▼
  │                    SessionLogDownloadController（浏览器，每会话一个 in-flight 下载）
  │                    HEAD /api/session.export?sessionId=<id>&includeDescendants=true
  │                    成功 → 把 GET URL 交给浏览器下载管理器（不缓冲字节）
  ▼
  Host：session-log-export 注册精确 GET/HEAD Fetch route
  ├─ flush 活动根会话；persistence.open(id, 'read') 读取完整逻辑日志
  ├─ sessionQuery.traceSession 取后代血缘并逐个序列化当前格式
  ├─ 收集 image 与 generic file 引用，分别读取对象字节
  └─ fflate 流式 ZIP（压缩级别 0-9，默认 6）→ chunked Response
      根 session.v3.jsonl → subagents/<id>/session.v3.jsonl
      → media/<attachmentId>.<ext> + files/<digest-prefix>/<digest>/<name>
```

浏览器实时对话视图不经过导出：Session Controller 的 Remote journal 传原始 durable 记录与 transient assistant frames，客户端派生对话节点。ZIP 与 UI 共享逻辑会话事实源，但导出重新编码完整逻辑事件，UI 只投影当前窗口。

## 1. 入口、用户目标与导出源

两个入口共享同一个下载控制器与同一个模态框（`session-log-export/src/client/index.ts:37-49`）：

- 会话头右侧的 `Session log` 按钮（带下载图标，注册进 `conversation.session.header.utilities` 槽位），点击直接发起下载（`HeaderAction.tsx`）。
- 斜杠命令 `/export`：宿主注册于 `session-log-export/src/index.ts:19-25`，带参数时返回错误（“不接受路径”）；本地 `command/executed` 事件在 `result.kind === 'success'` 时才触发下载，其他浏览器标签页只渲染 durable 命令行、不重复下载（e2e 验证：观察者标签页下载数为 0）。

导出粒度只有“整会话树”一个级别：根会话 + 全部子代理后代（fork/subagent 形成的 `parentSession` 血缘），无单消息、连续范围、选区或批量会话入口。ZIP 条目依次覆盖根日志、后代日志、去重媒体与通用文件（`packages/session-query/session-log-export/src/archive.ts`）。

## 2. 范围选择、内容口径与字段过滤

内容口径是“当前格式下的完整逻辑日志”。导出端通过 read handle 取得 header 与事件，再用 `serializeSessionLog` 编码为规范 JSONL；它不是物理存储文件的逐字复制。因此：

- 所有事件类型全量保留，包括 reasoning、流式 chunk、usage、错误、turn 边界、被 surface 替换遮蔽的旧节点——导出不做 surface 状态过滤，也不做字段裁剪。
- 后端压缩帧、旧代行编码与物理 chunk 打包不会保留；旧格式先迁移为当前逻辑事件，再输出 v3 规范文件。
- 与“人类 transcript”的区别：核心会话模块的 surface 折叠（`core/session/src/surface.ts`）把事件分为 append-origin（进入用户已见对话）与 replacement（仅模型可见）两类，`deriveMessages()` 只从 surface 节点派生模型消息；而 ZIP 导出的是整个事件日志，两类事件都在其中，没有按此区分。
- 无明显“隐藏内容”过滤：被压缩/替换掉的节点以事件原文存在于 artifact，导出时原样带出。UI 的过滤是查看侧行为，导出侧不存在。

## 3. 附件、资源与离线封装

- 图片与通用上传文件都会导出。归档器从逻辑事件收集引用并去重：图片写入 `media/<attachmentId>.<ext>`，通用文件写入内容寻址的 `files/<digest-prefix>/<digest>/<name>`；大文件按有界块读取和压缩（`packages/session-query/session-log-export/src/archive.ts`）。
- 附件存储是 `$DSH_HOME/attachments/v1/objects/<sha256前2位>/<sha256>` 内容寻址目录（`attachment-local/src/index.ts:53`），同一图片被多个会话引用时归档中只出现一次。
- spill 长文本（工具超长输出的落盘文件）**不在导出范围内**：spill 存于私有 0700 的进程临时目录 `session-<hash>/<随机>-<安全名>`（`spill-local/src/store.ts:20-28,75-111`），会话日志里只留模型可见的定位符文本（SpillLocator 与取回指引），ZIP 不收集 spill 文件本体；日志文本中原样出现的本地路径、远端 URL 保持为文本，不转换、不内联。
- 归档无 manifest；每份会话日志自带 header，媒体与文件路径可由日志引用对应。ZIP 是本地单文件，离线可检查。

## 4. 格式、schema 与往返能力

- 交付格式只有 ZIP 容器内的 JSONL 一种。全仓检索 `pdf`、`toPng`、`html2canvas`、`jspdf` 均无命中，未发现 Markdown/HTML/PDF/PNG 导出或打印链路。
- 无独立导出 schema 版本：JSONL 使用会话格式 header，当前版本为 v3。导出固定为当前规范代，不保留来源介质是纯文本还是 zstd，也不保留旧代文件名。
- 仓库内没有用户级导入命令或 `session.import` Remote；导出物虽是可解析的当前格式日志，但没有受支持的整包恢复流程，不能把 ZIP 原位放回等同于导入。
- 依赖约束：导出需要持久化、session-query、附件与连接服务；日志通过 read handle 获取，因此任意实现当前 persistence 契约的后端均可使用。旧 SQLite 501 边界已经失效。

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
- 输入侧有基础硬化：会话 id 在归档路径段中清洗，通用文件名也经过安全处理；Connection 的认证、Host/Origin 检查先于 feature-owned Fetch route。准备失败使用固定 HTTP 错误语义，不把内部路径直接作为下载内容。
- 媒体扩展名走白名单映射，未知媒体类型不会产出任意后缀的条目（`session-export.ts:93-98`）。

## 10. 性能、失败恢复与测试

- 内存边界：ZIP 用 fflate 流式压缩，日志文本与通用文件均分块进入归档；背压限制 Host 不必持有完整 ZIP 或完整大文件（`packages/session-query/session-log-export/src/archive.ts`）。
- 失败语义：准备期失败在流开始前以 HTTP 状态返回，`HEAD` 预检让浏览器先发现；流中后代或附件读取失败会终止下载，不产出看似成功的截断归档。
- 取消：请求 abort 与响应消费取消共用一个生产信号，同时终止活跃压缩器并以取消（而非 500）传播；浏览器侧每会话只允许一个 in-flight 下载，重复手势共享同一操作，关闭模态不取消下载，插件 dispose 时中止预检并等待归零（`controller.ts:78-129`）。
- 测试：`session-log-export/tests/{route,archive}.host.spec.ts` 覆盖路由注册、HEAD、逻辑日志序列化、后代、live flush、图片与通用文件、背压、取消和 fail-loud；Client specs 覆盖按钮与 `/export` 共用控制器。

## 11. 设计取舍与已确认边界

- **导出是逻辑日志快照，不是物理工件副本**：完整事件语义、分支与被遮蔽节点保留，旧代编码、压缩帧和后端布局被规范化；消费方仍需解析 JSONL，没有面向人读的转换层。
- **导出与分享解耦**：浏览器下载只负责“拿到文件”，分享、查看器、访问治理全部不存在——这与 Pi 的“导出 HTML + Gist 链接分享”路线形成对照：本项目的交付边界停在文件系统。
- **Host/浏览器职责分工**：feature package 在 Connection 上注册认证 Fetch route，Host 负责逻辑读取与流式压缩，浏览器负责预检、保存与模态反馈；它不是 Typert Remote 方法。
- **内容口径的全量性**：导出包含被 surface 遮蔽的旧节点与压缩摘要源事件，这是“可重建任何时刻状态”的设计取向；对只想看当前对话的用户来说，ZIP 比可见对话更大且更敏感。
- 后端耦合：导出只依赖当前 `SessionPersistence` 的 read handle，不依赖 JSONL 物理工件；第一方当前只提供 JSONL 会话后端。

## 12. 未验证事项

- 浏览器下载管理器的实际行为：GET 流中失败（后代/媒体读取错误）由浏览器报告而非模态框，其具体呈现未运行验证。
- 大会话、大图片下的下载耗时、内存峰值与浏览器兼容性（README 声明了设计边界，无运行数据）。
- `HEAD` 预检与 GET 之间日志继续增长时，两次读取字节不一致的窗口行为（实现读取两遍，但无运行验证）。
- telemetry 导出的 OTel 后端行为、批次与重试策略（仓库外 SDK 职责）。
- ZIP 内条目在中文文件名、非 UTF-8 系统上的解压兼容性（附件扩展名来自白名单，会话 id 已清洗，推测安全，未验证）。

## 13. 关键源码索引

- `packages/session-query/session-log-export/src/client/index.ts`（插件装配、`command/executed` 触发下载、槽位注册）
- `packages/session-query/session-log-export/src/client/controller.ts`（HEAD 预检、每会话单 in-flight、取消与 dispose）
- `packages/session-query/session-log-export/src/index.ts`（`/export` 命令注册与参数拒绝）
- `packages/session-query/session-log-export/src/client/HeaderAction.tsx` / `Dialog.tsx`（按钮与模态）
- `packages/session-query/session-log-export/src/archive.ts`（handle 读取、当前格式序列化、引用收集与 ZIP 流）
- `packages/session-query/session-log-export/src/index.ts`（命令与精确 GET/HEAD Fetch route）
- `packages/session/session-persistence/src/{index,handle}.ts`（read handle 契约）
- `packages/session-query/session-query/src/tracing.ts`（`traceSession` 祖先/后代血缘）
- `packages/core/session/src/surface.ts`（append-origin 与 replacement、`foldSurface`）与 `src/index.ts:726-747`（`deriveMessages`）
- `packages/attachment/attachment-local/src/store.ts`（内容寻址存储）与 `packages/spill/spill-local/src/store.ts`（spill 私有目录）
- `apps/cli/src/args.ts` + `dump-config.ts`（CLI 模式：profile/dump-config/plugin/web，无会话导出）与 `apps/cli/reference/README.md`
- `packages/bundle/headless/src/index.ts`（stdout 打印最后助手文本）
- `packages/bundle/web-app/cordis.patch.yml:69-71`（Web bundle 挂载导出插件）
- `packages/session/session-telemetry/README.md`（共享策略与脱敏瀑布，邻接能力）
- `packages/session-query/session-log-export/tests/{route,archive}.host.spec.ts` 与 client specs（测试证据）
