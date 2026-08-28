# Dify 生成式输出与运行时调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-28
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：静态阅读工作流应用生成器、GraphEngine 入口、运行/节点记录模型、service/console API、聊天与控制台日志投影、归档服务与流事件实体；未启动 worker 或执行图
>
> 调查范围：workflow run 的身份、运行、流、暂停/停止、日志与公开调用；普通聊天消息呈现另见消息渲染器笔记
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

对 Dify 而言，独立的生成运行对象是 workflow run，不是一条 assistant message。Workflow 应用创建 workflow execution 与 node execution repository，并将图运行时交给 `WorkflowEntry`；run ID 用于读取详情、节点 trace 和日志，task ID 是流式停止的句柄。WorkflowRun 自身保存状态、公开 outputs、错误、耗时、token、调用来源和时间，节点执行另保存输入、输出、过程数据与状态。工作流输出可回到 WebChat，但运行记录、节点记录和消息属于不同对象层。

## 系统边界与运行主链

```text
WebApp / service API 提供 inputs、files、response_mode
  -> WorkflowRunApi 验证已发布 workflow 与终端用户
  -> AppGenerateService 选择 WorkflowAppGenerator
  -> 按 workflow app config 规范化文件和输入
  -> 创建 workflow / node execution repository
  -> WorkflowEntry / GraphEngine 执行并产出 GraphEngineEvent
  -> blocking 返回 JSON，streaming 转换为 SSE
  -> run 详情、节点执行和日志由专用服务查询/归档
```

service API 将 response mode 定义为 blocking 或 streaming，默认 blocking；前者返回 JSON，后者返回 `text/event-stream` 和 `ChunkWorkflowEvent`（`controllers/service_api/app/workflow.py:75-80,285-293`）。这将同步结果与事件消费作为 API 契约，而不是由前端自行猜测。

## 1. 输入、配置与运行记录初始化

`WorkflowAppGenerator.generate` 先在文件访问作用域内处理 files（`workflow/app_generator.py:166-181`），再由 `WorkflowAppConfigManager` 取得应用配置（184-188 行），以变量定义准备用户输入（207-212 行）。service API 对文件类型的校验强于部分内部调用，说明输入边界依赖 invoke source，不能只凭调试画布推断公开 API 的接受范围。

生成器依次决定触发来源：调试为 `DEBUGGING`，应用运行为 `APP_RUN`（238-244 行），然后创建 workflow execution 与 node execution repository（244-258 行）。单节点/单循环调试也会建带 DEBUGGING 来源的 repository（485-612 行）。运行记录可以区分公开应用执行与控制台调试；本次未确认所有日志表面是否展示该来源。

## 2. 图运行、变量与执行环境

`WorkflowAppGenerator._generate` 把 app、workflow、user、运行实体、两个 repository、streaming、variable loader、root node、layers 与 graph state 交给下层（321-420 行）。`WorkflowEntry` 是图入口，其 `run` 产生 `GraphEngineEvent`（`core/workflow/workflow_entry.py:97-185`），配置开启时可叠加 observability layer（179-180 行）。终态的内部 node outputs 经公开 contract 投影后写回 WorkflowRun；这解释了为什么最终 API 输出和各节点的完整过程数据不是同一个 JSON 对象。

图变量包括公开输入、文件、应用变量、节点输出和 runtime state，不等同于聊天 history。LLM、Agent、工具、知识库和人工输入可作为节点参与，但节点 schema、顺序和错误策略由 DSL 决定；本次不把某个节点的行为推广为所有 workflow。

## 3. 输出、流事件与暂停

事件契约包含 workflow start/finish/pause、人工输入、节点 start/finish/retry、迭代、循环、文本 chunk、reasoning chunk 与文本替换（`core/app/entities/task_entities.py:206-773`）。因此 UI 可同时表示最终文本、节点过程、暂停与表单；公开聊天是否展示每种事件取决于具体应用表面。

workflow/advanced chat 的流式调用会从 workflow run ID 使用 `MessageBasedAppGenerator.retrieve_events` 回收事件（`app_generate_service.py:255-262,311-318`）。run 记录因此是执行者与 API 消费者的连接点；blocking 路径直接返回映射结果，调用者不应期待 task stop。

## 4. 停止、恢复与任务边界

`/workflows/tasks/<task_id>/stop` 只支持 streaming（`workflow.py:513-517`）。控制器同时写 legacy `AppQueueManager` stop flag，并通过 `GraphEngineManager` 发送 stop command（550-555 行），表明运行时保留新旧兼容双通道。前端在 task ID 到达后可调用停止，但先结束本地 responding 状态。

生成器有 `resume`，可带回 graph runtime state、variable loader 和既有 repositories（274-319 行）。这确认了暂停/恢复交接点；未执行图，不能确认哪些节点可恢复、恢复后是否重复投递事件或实际保留了多长时间。

## 5. 查询、日志、归档与保留

service API 可按 workflow run ID 取得详情（`workflow.py:121-276`），控制台的 run/节点列表和详情要求 app 管理权限，`WorkflowRunService` 再按 tenant/app/run ID 查询 run、count 和节点 trace（`api/controllers/console/app/workflow_run.py:108-368`、`api/services/workflow_run_service.py:112-210`）。消息日志中的 `workflow_run_id` 会打开同一 run detail 与 node-execution 路径；控制台 workflow log 也显示状态、耗时和 token。这确认 outputs 不只在原始 SSE 中短暂存在，后续可由 run ID 回读并在多个日志面投影。

节点执行的 inputs、outputs 与 process data 可以直接留在数据库，也可以通过 offload 记录转存到 UploadFile/对象存储；读取 detail 时依该引用回载完整内容。这样做是因为节点开始与完成要分别保存 inputs/outputs，不能等待完成后合并而牺牲运行中可观察性（`api/models/workflow.py:793-1221`）。它是执行审计的容量设计，不意味着用户获得可编辑文件工作区。

归档并非只有后台目录：控制台先列出月度 archive bundle，再创建或复用 download task；任务由 Redis 状态和 Celery 准备过程驱动，状态依次可为 pending、processing、ready 或 failed，完成后控制器才重定向至预签名下载 URL（`controllers/console/workflow_run_archive.py:94-182`，`services/retention/workflow_run/archive_{log_service,download_preparation,download_task}.py`）。准备任务把归档 bundle 整理为面向用户的 CSV ZIP，bundle 索引避免请求时直接枚举对象存储。

当前快照的最新提交正重构 workflow run archive application service，显示归档仍在演进。静态路径能确认下载任务的状态收口和控制台访问边界；未运行存储/retention 任务，不能声明实际归档介质可用性、恢复时限、下载权限效果或清理成功率。

## 6. 输出对象、投影与可维护性边界

Dify 在本类目中可确认两层不同对象：消息中的 Markdown、代码和附件属于 G0/G1 内容投影；workflow definition 所产生的 workflow run、node execution、变量与事件流则是具稳定 ID、独立查询和归档面的运行记录。后者可被公开聊天或 API 消费，并能经历文本 chunk、节点开始/结束、暂停、人工输入、失败/完成和停止。公开页只是其中一个投影面；blocking API、消息/控制台日志、节点详情和归档下载可消费同一运行层的不同结果形态。

这不等于 Dify 已确认提供了 HTML/JS Artifact 沙箱、可编辑文档画布、持续桌面活对象或“模型读取对象源码后定向维护”的完整闭环。本笔记的结论应收敛为**可寻址工作流执行记录**，而非泛称生成式 Artifact 或工作区：run 可以被查询、日志化和归档，却没有在本轮发现可在同一 run outputs 上编辑、版本化、接收 patch 或由模型再次定位维护的产品路径。已发布图的编辑/版本语义属于控制台 workflow 与 DSL 专项，不能由 run 的稳定 ID 推断。

## 已确认边界与未验证事项

- 已确认发布 workflow、tenant/user scope、repository 与 GraphEngine 的静态主链；控制台调试有独立触发来源。
- 停止 API 只面向 streaming；它是否中断模型、插件、MCP 和外部 HTTP 需运行验证。
- 未验证节点重试、并行、循环、暂停、人工输入、恢复、长图性能和多实例幂等性。
- workflow run、node execution、conversation/message 为不同事实对象，公开聊天文本不替代 workflow 日志；大节点数据的对象存储回载、归档 CSV ZIP、预签名 URL 和 retention 清理也没有运行验证。
- 未找到对已完成 run outputs 的编辑、版本、patch、模型回流或持续工作区语义，不能按稳定 ID 抬升为 Artifact。

## 关键源码索引

- `api/controllers/service_api/app/workflow.py:75-557`：调用、响应模式、详情和停止 API
- `api/services/app_generate_service.py:290-318`：workflow 分派与事件回收
- `api/core/app/apps/workflow/app_generator.py:150-680`：输入、repository、运行与恢复
- `api/core/workflow/workflow_entry.py:97-185`：GraphEngine 入口与观测层
- `api/models/workflow.py:793-1221`、`api/core/workflow/workflow_run_outputs.py`：WorkflowRun/节点输出、状态与大数据 offload 契约
- `api/controllers/console/app/workflow_run.py:108-368`、`api/services/workflow_run_service.py:112-210`：按 app/tenant 查询 run、节点 trace 和权限边界
- `web/app/components/base/message-log-modal/`、`web/app/components/app/workflow-log/`：聊天/控制台对 run 与节点记录的投影
- `api/services/retention/workflow_run/`：归档与恢复任务
