# DeepSeek Harness Agent 角色配置调查笔记

> 调查对象：`https://github.com/deepseek-ai/deepseek-harness`（重点 `packages/preset/agent-preset`、`packages/preset/agent-preset-registry`、`packages/preset/persona`、`packages/core/system-prompt`、`packages/core/agent`、`packages/core/scope`、`packages/bundle/web-app/presets/`、`packages/context/agent-instructions`）
>
> 调查更新日期：2026-11-05
>
> 代码快照：`8bd073392eef6f54e921a093b95076248eb08cbb`（分支：`master`）
>
> 调查方式：只读静态源码阅读，梳理 preset 声明/注册/挂载/选择链路、scope 分层、system prompt 组装与会话日志记录；辅以 `docs/upgrade-guide/` 的迁移说明；未运行交互会话，未执行测试
>
> 调查范围：角色实体与存储、创建与会话绑定、生效优先级、system-prompt 组装、模型与生成参数、工具与子 Agent 授权、资产与变量、作者化与安装路径、运行时可见性、与 pi 的关系；排除工具执行与审批细节、LLM Provider 渠道管理、Web 客户端 UI 内部实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek Harness 没有传统聊天应用意义上的"角色卡"。角色体系是 **per-session 的 agent 组合**：一个 **preset** 是一行声明式插件配置（`@deepseek-ai/dsh-agent-preset`），其 `config.plugins` 是子插件行列表，`config.id` 是稳定身份；注册表 `ctx.agentPresets` 为每个声明急切创建一个 registry 拥有的 scope 与内存 Loader 树，选择它的会话通过 **scope 父链**加入这份组合，共享同一批工具注册、prompt section 与插件实例（插件内部按 Session/Agent 键存状态）。

四条主机制：

1. **preset 是普通插件行而非目录**：注册表既不扫描目录也不接收 preset 路径——定义就是 Cordis 组合里的 `@deepseek-ai/dsh-agent-preset` 行（`packages/preset/agent-preset/src/index.ts`；`packages/preset/agent-preset-registry/README.md`）。
2. **注册表管修订与绑定**：`register()` 建 scope 与内存树，更新或删除声明会退役旧修订；Agent、子 Agent 与临时历史读取各持引用，最后一个引用释放时才销毁旧树（`agent-preset-registry/src/index.ts:97-180`）。
3. **system prompt 按 scope 分层组装**：`ctx.systemPrompt` 是按 scope 分层的注册表（section / context / variables），组装时按 agent → preset scope → global 的链就近覆盖；`deployment:persona-prefix` 与 `deployment:persona-suffix` 各占固定槽位，其余 section 按 order 拼接，`complete` section 可整篇替换（`packages/core/system-prompt/src/index.ts:125-140, 620-700`）。persona 行只是把该槽位注册进 preset 自己的层，从而覆盖部署级 persona。
4. **模型与生成参数不属角色**：preset 不绑定模型；默认模型由独立的 `agent-default-model` 插件经 settings 分层提供，会话级选择由 agent-loop 拥有的 `modelSelection` 投影与 `agent.model`（`AgentModel`）承载，并在每步准备时冻结（`packages/core/agent/src/model-selection.ts:72-160`）。

与 pi 的关系：两项目唯一交集在 LLM 层——harness 把 `@earendil-works/pi-ai`（当前 1.3.0）作为可选 LLM 适配器（`packages/llm/llm-pi-ai`），与 pi 的角色/提示词体系没有继承关系；本次未在 preset 层找到任何对 pi 的 agent 配置（SYSTEM.md、AGENTS 链进 system prompt）的参考。

## 总体生效链路

```text
Cordis 组合加载 preset 声明行（bundle patch 或用户 patch）
  -> @deepseek-ai/dsh-agent-preset[Service.init] -> ctx.agentPresets.register(definition)
       register：建 registry 拥有的 scope + 内存 Loader 树，激活审计后可绑定
       更新/删除：旧修订退休，引用归零后销毁（agent-preset-registry/src/index.ts:97-180）

Session Controller Remote：session.create({ workspaceId/cwd, agentPreset? })
  -> ApiSessionAgents.createOrAdopt：解析请求或默认 preset（agent.ts:220-260）
     resume 路径：从记录值恢复，缺失定义直接拒绝
     复用路径：日志记录与 Agent 当前修订一致时不重挂、不记事件
  -> ctx.agents.create/resume({ meta.agentPreset, setup })
       setup 内 presets.mount(agentCtx, id) -> 绑定 agent scope 父链
  -> 每步请求前（agent-loop/src/agent.ts:292 起）：
       toolSet = ctx.tools.resolve({ agent, modelSelection, signal })
       systemPrompt.assemble(assembleContextFor(agent))
         层链解析 agent scope -> preset scope -> 全局（system-prompt/index.ts:620-700）
       renderPrompt(assembly)（system-prompt/index.ts:296）
  -> system/message 表面协调 + 工具/配置头快照
      deriveMessages() -> 冻结请求 { messages, tools, provider, model }
```

子 agent 有两条路径：显式 `agentPreset` 时 `presets.mount(childCtx, id)` 挂一个独立 preset；未指定时 `composeFrom(childCtx, parent.ctx)` 加入父的当前代组合（`packages/subagent/subagent/src/child-agent.ts:179-201`）。恢复出的历史子会话没有保存 preset 时退回宿主组合。

## 1. 角色数据模型与存储

- **角色实体**：preset 声明。注册表条目携带 `id`、`plugins` 行列表与可选显示字段 `name`/`description`/`order`；`id` 是会话日志记录的身份，声明行的 Loader id 只用于寻址编辑（`packages/preset/agent-preset/src/index.ts`）。
- **注册表配置**：只有 `default` 与 volatile 的 `selectedDefault`。前者是部署默认，后者是用户默认，`defaultId` 先读用户值再退回部署值（`agent-preset-registry/src/index.ts:58, 82`）。
- **载入时机**：声明随组合急切加载，修改影响之后创建的 Agent；运行中的 Agent 保留自己已有的组合修订（README Summary）。
- **激活审计**：审计 imports、缺失服务与全局泄露的服务；等待 Host 服务的行保持挂载，并在 Host Loader 树稳定后对每次读取与绑定重新审计，因此启动顺序不决定结果；审计失败阻止新绑定（`agent-preset-registry/src/mount.ts`）。
- **服务隔离**：preset 服务提供者与其消费者必须共享同一个 `cordis:group` 隔离 realm；entry-local 隔离不穿透 Agent 注册 scope，`agentPresets.serviceFor()` 是显式读取保留组合的通道（README 实现节）。
- **用户默认与 shipped 组合**：Web 定义来自 `dsh-web-app` bundle，四个 shipped preset 以 `presets/{standard,minimal,ptc,cordis}.patch.yml` 插入 `@deepseek-ai/dsh-agent-preset` 行（`packages/bundle/web-app/presets/standard.patch.yml`）。用户从 Web 编辑器保存的改动以同一个 Loader id 覆盖该行的 `config.plugins`。
- **没有目录级增删**：注册表不扫描目录，没有 `copy()`/`remove()` 文件操作，也没有 `preset.yml` 显示文件。新建 preset 或覆盖 shipped preset 都通过 bundle patch 安装（`plugin_manager`），作者化在会话内完成。

## 2. 创建、选择与会话绑定

- **绑定在会话创建期**：Session Controller 的 Agent owner 在 create/resume 前解析 preset，并把 mount 放进 agent factory 的 pre-publication `setup`；挂载失败会让创建或恢复整体失败（`packages/api/session-controller/src/agent.ts`）。
- **日志与投影之分**：记录保留请求的 preset id，后续选择追加 `agent-preset/selected` 事件，`presetForSession(session)` 同步读出最新记录值或 null（`agent-preset-registry/src/index.ts:89`）。冷读渲染用 `acquireScope(id)` 拿到修订租约，用完 `dispose`（`:389`）。
- **切换仅限 blank 会话**：`select()` 按会话串行化，先检查 `turnBoundaryOf()` 的开放回合与历史回合数，已开过回合即返回 `agent-preset/locked`；随后 `recompose()` 换父链并追加选择事件。若会话已记录该 preset 且 Agent 正跑当前修订，则直接返回、不记事件也不发 `tools/change`（`:365-387`）。
- **默认 preset 是用户设置**：`ui-agent-preset` 经 Remote settings 更新 `agent-preset-registry` 命名空间的 `selectedDefault`，值按读取时解析，新会话立即生效，运行中会话不受影响（`packages/client/ui-agent-preset/src/client/settings-store.ts:35`）。
- **无 roster 的部署**：当部署没有组合任何 preset roster 时，复用记录过 preset 的会话会得到 `ApiSessionPresetConflict`（`session-controller/src/agent.ts:42-48`）；请求未知名或非法 preset 抛 `agent-preset/not-found` 与 `agent-preset/invalid`。

## 3. 提示词字段、优先级与输出契约

- **注册表输入**：section（name/order/text/complete）、动态 context（组装成 user 角色快照）与 prompt variable 三类；工具 schema 不再属于组装瀑布的输入。section 同名时 scoped 覆盖全局，同层重复注册抛错（`system-prompt/index.ts:434-620`）。
- **顺序约定**：`deployment:persona-prefix` 与 `deployment:persona-suffix` 各占固定槽位，前者是身份段，后者追加在一方指引之后；plan 模式提示段 order 50；工具指引 100-199（`system-prompt/index.ts:196-205`）。
- **persona 行**：`dsh-persona` 是 scope-only 行——挂进 preset 内即遮蔽该会话的部署 persona，挂全局会与注册表自身的 persona 注册冲突并 fail loud。配置含 `prefix`（必填）、`suffix`、`complete`（让 prefix 成为唯一提示词）与 `includeRuntimeContext`（关闭该 scope 的运行时上下文快照）（`packages/preset/persona/src/index.ts`）。
- **部署 persona**：由 system-prompt 插件自身的 `config` 提供；Web bundle 的 standard preset 用 `You are a coding agent powered by the {{model}} model.` 作为 persona prefix（`packages/bundle/web-app/presets/standard.patch.yml`）。
- **输出契约**：`renderPrompt` 对 sections 做严格 `{{variable}}` 插值（未知或未定义变量抛错）、过滤空段、以空行拼接（`system-prompt/index.ts:296`）。
- **内置变量**：会话模型选择变量由组装侧注入；内置 `{{cwd}}` 提示词变量已移除，会话执行目录改由 working-directory 作为 user 上下文提供（`docs/subsystems/working-directory.md`）。
- **专家改写口**：`system-prompt/assemble` 是 scope 过滤的 waterfall，输入类型是只有 sections/contexts/variables 的 `PromptPresentation`，返回的 `tools` 字段被忽略；真正的工具声明由 `ctx.tools` 的 prompt provider 提供。
- **上下文刷新**：动态上下文 provider 在请求准入阶段再求值一次（pre-step 监听与路由准备之后），因此 provider 不能假设每步只求值一次（`docs/upgrade-guide/v0.2.1-alpha.1/working-directory/guide.md`）。

## 4. 模型、Provider 与生成参数

- **preset 不绑定模型**：composition 里没有模型字段。Agent 级选项只有 provider/model/maxTokens 等运行参数（`packages/core/agent/src/runtime-types.ts`）。
- **默认值**：`agent-default-model` 插件把 provider、model 与可选 reasoning effort 作为 settings namespace 分层提供；Session Controller 在 create/resume 时据此建立初始选择。
- **会话级选择**：agent-loop 拥有持久 `modelSelection` 投影，并为每个 Agent 构造 `agent.model`（`AgentModel`）；`select()` 追加 `model/selection` 事件，`current()` 读取当前值，重启后从投影恢复（含未使用过的选择）（`packages/core/agent/src/model-selection.ts:72-160`）。选择在**每步准备时冻结**，该步与其重试沿用它；`agent/request` 瀑布已弃用，监听器不能再改 provider/model/effort。
- **子 agent 继承**：子 agent 默认继承父的路由；`modelSelection` 配置允许模型在委派时选择路由字段，`modelDiscovery` 提供一个 scope 内唯一的 `list_subagent_models` 发现工具，两者默认关闭（`packages/subagent/tool-subagent/src/index.ts:58-100`）。
- **思考等级与温度**：仍不由角色持有，走 LLM 适配层与 `ReasoningEffortId` 词汇。

## 5. 工具、知识库、记忆与子 Agent

- **工具由 preset 行声明**：composition 里的工具插件行注册进 preset scope 的 tool registry；一个 preset 向模型暴露哪些工具，由该 preset 的插件行集合决定（standard 覆盖 shell、文件系统、后台任务、skills、目标、plan 模式、子 agent、团队任务与时序等能力，`packages/bundle/web-app/presets/standard.patch.yml`）。工具 schema 经 tool provider 进入组装，`toolOrder` 配置可固定模型可见顺序。
- **服务 realm 规则**：preset 若发布服务，必须放在带隔离 realm 的 `cordis:group` 里；发布进 root realm 的行在挂载时被拒，并在每次绑定前由激活审计复查。
- **子 Agent 组合**：spawn 子 agent 用 `agentPreset` 指定自己的组合，多个可选组合通过 `allowedAgentPresets` 暴露给父模型；旧的 `persona`/`toolFilter` 配置已被拒绝。fork 子 agent 继承父的 preset，不能独立改 persona 或裁剪工具（`docs/upgrade-guide/v0.2.1-alpha.1/subagent-preset-composition/guide.md`）。
- **知识库与记忆**：无向量知识库；等价物是 preset 可携带的 skills 目录（`dsh-agent-preset` 自带 agent-experience、cordis-plugin-development、editing-cordis-compositions、cordis-composition-reference 四套）与 `agent-instructions` 注入的工作区指令。记忆即会话日志加压缩，无跨会话自动记忆。
- **工作区指令是 user 角色消息，不是 system prompt**：`dsh-agent-instructions` 按 `AGENTS.md`/`CLAUDE.md`（及 `.local` 变体）候选加载，作为带 `agent-instructions` source 的用户消息进入请求，并在文件被 read/write/edit 触碰后增量更新（`packages/context/agent-instructions/src/index.ts`）。
- **指令预算按链计算**：`maxBytes` 现在分别约束用户全局链（`$DSH_HOME/AGENTS.md` 与共享 agents 根）与项目链，一条同时装两条链的消息最多可达配置值的两倍；基座配置为 65536。`maxBytes` 属于基线身份的一部分，改动后每个恢复会话都会收到一次完整替换基线（`packages/context/agent-instructions/src/config.ts`）。
- **harness home 统一解析**：指令加载器不再接受 `dshHome` 字段，改经 `resolveDshHome()` 解析 `$DSH_HOME` 或 `~/.dsh`（`docs/upgrade-guide/v0.2.1-alpha.1/instruction-home-override/guide.md`）。

## 6. 资产、变量、开场白与用户档案

- **preset 可携带资产**：声明行的 `plugins` 只能引用包名与配置，资产随包发布——`dsh-agent-preset` 的 `skills/` 目录即随包发布、由 `skill-filesystem` 挂载。
- **头像/开场白/快捷回复**：本次未找到——声明行只有 `id`/`plugins`/`name`/`description`/`order`，没有头像、开场白或快捷回复字段。
- **变量**：仅系统 `{{variable}}` 模板（persona 文本引用 `{{model}}` 等），无用户自定义占位符语法；`{{cwd}}` 已整体移除。
- **用户档案**：无用户档案对象；`AGENTS.md` 链经 agent-instructions 进入请求，接近"项目档案"的语义。

## 7. 作者化、安装与兼容性

- **作者化是声明式编辑 + bundle 安装**：注册表只写声明，不写文件；`read` Remote 把某条声明的子插件列表渲染回 entry-list YAML（含 `!!js` 条件）供客户端展示，没有任何接口接受 YAML 写回。新建或覆盖 preset 都是一次 bundle patch：`insert` 一条 `@deepseek-ai/dsh-agent-preset` 行，或以该行 id 打补丁，再用 `plugin_manager` 装进 profile（`agent-preset-registry/README.md`）。
- **组合是输入而非持久化目标**：声明行携带的 `plugins` 由内存 Loader 树装载，注册表不把运行期变更写回文件。
- **健康与降级**：失败的声明仍留在 roster 上可见；激活失败阻止新的绑定，但不影响已绑定 Agent 的旧修订。
- **修订回收**：更新或删除声明会退役上一修订；旧修订实现不跨进程重启保留（Known Limitations）。
- **未知 preset 与默认值**：`resolve()` 对未知 id 抛错；settings 里存一个暂不存在的默认可被接受，真正解析时才失败。
- **版本与兼容**：会话日志记录 preset id 与 blank 期选择事件；没有该记录且没有选择事件的旧日志保留空值。profile patch 里遗留的 `modeSelectionEnabled` 字段被声明表忽略——注册表既不读也不改写。
- **安全边界**：preset 不是安全沙箱，YAML 与插件都能执行 Host 代码；用户覆盖替换整份子插件列表，不会自动合并 builtin 列表的后续变化（Known Limitations）。

## 8. 配置界面、输出契约与可见字段

- **浏览器远程面**：`AgentPresetRegistry` 是 Typert Remote 服务，暴露 list/resolve/read/select 等方法，由 `packages/client/ui-agent-preset` 消费；blank-only 切换与选择幂等规则在服务端强制。
- **运行时可见性**：会话列表条目携带从投影与记录得出的 `agentPreset`；Web 的新会话 chip、会话头标签与 Settings roster 消费同一值。冷读服务可用 `acquireScope()` 的修订租约解析 scoped 能力而不恢复 Agent（`agent-preset-registry/src/index.ts:389`）。
- **组合盘点**：`inspectCompositions()` 返回注册表保留的所有修订，按 Agent context 过滤时只给它的精确修订；每条 `AgentPresetInspection` 含 preset id、分离的活动模块引用与解析基址、泄露服务名（`composition-inventory.ts`）。
- **历史快照语义**：日志冻结 preset id 与选择事件，两者足以在冷读时重建会话运行时组合；system prompt 正文不进日志。assistant 消息保留 provider/model 元数据。

## 9. 与 pi 的继承与差异

**继承点仅限 LLM 层**：harness 以 `@earendil-works/pi-ai@1.3.0` 为依赖（`pnpm-workspace.yaml`），`packages/llm/llm-pi-ai` 把它包装成 LLM 适配器之一（另有直连 DeepSeek API 的 `llm-deepseek`、账号态 `llm-deepseek-account` 与 API-key 态 `llm-deepseek-api-key`）。这是 Provider 渠道层的关系（模型目录、thinking level、多协议），与角色/提示词体系无关。本次未找到任何代码、文档或配置把 preset 与 pi 的 agent 配置（SYSTEM.md、APPEND_SYSTEM.md、`~/.pi/agent/` 设置）联系起来。

| 维度 | pi | DeepSeek Harness |
| --- | --- | --- |
| 角色实体 | 无对象；文件约定（SYSTEM.md/APPEND_SYSTEM.md/AGENTS 链/skills） | preset 声明行：`config.id` + `config.plugins` 子插件列表 + 显示字段 |
| 存储粒度 | 全局 `~/.pi/agent/` 加项目 `.pi/`，按 cwd 解析 | 组合内声明行；注册表不扫描目录，没有文件级实体 |
| 会话绑定 | 资源随会话 cwd 解析，无选择入口 | 会话创建时绑定 preset scope 父链，Web 端可选可切（blank 期） |
| 提示词优先级 | SYSTEM.md 整篇替换 → APPEND → project_context → skills → cwd | 注册表 section 按 order 拼装，scoped 覆盖全局，`complete` 整篇替换 |
| 模型绑定 | 会话级状态加全局/项目设置深合并 | 会话级 `model/selection` 投影加每步冻结加 settings 分层默认 |
| 工具授权 | 会话级激活列表（默认 read/bash/edit/write） | preset 插件行声明加 step 级准入条件加服务须隔离 realm |
| 知识与记忆 | AGENTS 链进 system prompt 的 `<project_context>` 块 | AGENTS.md/CLAUDE.md 经 agent-instructions 以 user 角色消息注入；会话日志加 compaction |
| 作者化 | 文件即配置，用户直接编辑 | bundle patch 安装声明行，`plugin_manager` 落盘 |
| 历史快照 | system prompt 不随会话保存，仅 HTML 导出含快照 | 日志记 preset id 加选择事件，冷读可重建组合 |

两者共同的取向是"没有角色 UI 驱动的人格对象，配置即代码/文件"；分叉点是 harness 把角色能力彻底插件化（preset 决定工具与提示词），并把工作区指令移出 system prompt、作为可追踪的 user 角色上下文。

## 10. 设计取舍与已确认边界

- **声明式 preset 取代目录约定**：preset 与其它插件行共用同一套 Loader 机制，编辑、覆盖、启停都走组合 patch；代价是不再有"把目录拷出来就是新 preset"的轻量复制路径，作者化必须产出 bundle。
- **修订制而非原地重载**：更新声明会新建修订并让旧修订自然退出，运行中的 Agent 保留旧组合，避免会话中途换掉已记录的工具集合；代价是旧实现不跨重启保留。
- **blank-only 切换是产品规则而非机制限制**：防止已记录工具调用被新组合重放；判断依据是 turn boundary 投影，服务端强制。
- **host plane 与 agent plane 分离**：注册表、沙箱、审批、持久化、模型路由留在 host composition；preset 只允许注册模型可见的行与服务，泄露检测由激活审计兜底。
- **急切加载**：所有声明的内存树在组合加载期建立，使会话创建不必等待装载；代价是启动期开销随 preset 数量增长。
- **模型选择每步冻结**：以"该步及其重试使用同一路由"换取可重放与可审计；旧的"整个 turn 固定"约定已被取代。

## 11. 未验证事项

- 未实际运行会话或真实 API 请求，拼装、修订回收与选择链路均为静态确认。
- Web 客户端 preset 列表与编辑器的具体交互未细读（仅确认 Remote 方法与 settings 写入点）。
- `selectedDefault` 的 settings 分层序列化行为（volatile 字段如何随 settings 文档持久化）未逐行核对。
- 冷读 `acquireScope()` 修订租约在长事务下的回收时机未验证。
- agent-instructions 的文件发现、字节预算与去重细节只读了入口与配置，未逐行核对内部状态模块。
- 会话日志对 preset 组合的实际冷读重建未用持久化样本验证。

## 12. 关键源码索引

- `packages/preset/agent-preset/src/index.ts`：声明行插件、`Config`（id/name/description/order/plugins）、`Service.init` 注册
- `packages/preset/agent-preset-registry/src/index.ts`：register（97）、presetForSession（89）、inspectCompositions（180）、resolve（220）、readDocument（234）、mount（297）、composeFrom（313）、composedPreset（333）、serviceFor（340）、recompose（350）、select（365）、acquireScope（389）、compositionInventory（403）
- `packages/preset/agent-preset-registry/src/mount.ts`：内存树挂载、`auditRows` 与泄露检测；`composition-inventory.ts`：`AgentPresetInspection`
- `packages/preset/persona/src/index.ts`：persona prefix/suffix 槽位注册与 `complete` 语义
- `packages/core/system-prompt/src/index.ts`：`PromptPresentation`（125）、`PromptAssembly`（132）、section 常量（196-205）、`renderPrompt`（296）、`assemble`（620-700）
- `packages/core/agent/src/model-selection.ts`：`modelSelection` 投影（72）、`AgentModel`（98-160）、`installModelSelection`（157）
- `packages/api/session-controller/src/agent.ts`：preset 解析、复用与 create/resume 绑定、`ApiSessionPresetConflict`
- `packages/subagent/subagent/src/child-agent.ts:179-201`：子 Agent 的 preset 挂载与 `composeFrom`
- `packages/subagent/tool-subagent/src/index.ts:58-100, 152-200`：`agentPreset`/`allowedAgentPresets`/`modelSelection`/`modelDiscovery` 配置与旧字段拒绝
- `packages/context/agent-instructions/src/{index,config}.ts`：工作区指令注入与按链预算
- `packages/bundle/web-app/presets/{standard,minimal,ptc,cordis}.patch.yml`：shipped preset 声明
- `packages/client/ui-agent-preset/src/client/settings-store.ts:35`：用户默认写入
