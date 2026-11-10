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

1. **preset 由组合里的插件行定义**：一行 `@deepseek-ai/dsh-agent-preset` 就是一份 preset 声明，注册表直接从 Cordis 组合里接收它，既不扫描目录，也不接收 preset 路径（`packages/preset/agent-preset/src/index.ts`、`packages/preset/agent-preset-registry/README.md`）。
2. **注册表负责修订与绑定**：注册时每份声明建出一个 scope 与内存 Loader 树；声明被更新或删除，旧修订随之退役，Agent、子 Agent 与临时历史读取各持引用，最后一个引用释放时才销毁旧树（`agent-preset-registry/src/index.ts:97-180`）。
3. **system prompt 按 scope 分层组装**：提示词注册表按 scope 分层保存 section、动态 context 与 variable，组装时沿 agent → preset scope → global 的父链就近覆盖；`deployment:persona-prefix` 与 `deployment:persona-suffix` 各占固定槽位，其余 section 按 order 拼接，带 complete 标记的 section 可以整篇替换（`packages/core/system-prompt/src/index.ts:125-140, 620-700`）。persona 行做的只是把该槽位注册进 preset 自己的层，用它覆盖部署级 persona。
4. **模型与生成参数不属角色**：preset 里没有模型字段，默认模型由独立的 `agent-default-model` 插件经 settings 分层提供；会话级选择由 agent-loop 持有的 modelSelection 投影与 agent.model（AgentModel）对象承载，并在每步准备时冻结（`packages/core/agent/src/model-selection.ts:72-160`）。

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

- **角色实体是一份 preset 声明**：注册表条目携带身份 `id` 和 `plugins` 行列表，另有 name、description、order 三个可选显示字段；会话日志记录的身份就是 id，声明行的 Loader id 只用于寻址编辑（`packages/preset/agent-preset/src/index.ts`）。
- **注册表配置**：只有部署默认 `default` 与 volatile 的用户默认 `selectedDefault` 两项；读取时的 defaultId 先取用户值，未设置再退回部署值（`agent-preset-registry/src/index.ts:58, 82`）。
- **载入时机**：声明随组合急切加载，修改只影响之后创建的 Agent，运行中的 Agent 继续使用自己那份组合修订（README Summary）。
- **激活审计**：审计检查声明的 imports、缺失的服务与泄露到全局的服务；等待 Host 服务的行保持挂载，Host Loader 树稳定后每次读取与绑定都会重新审计，启动顺序因此不影响结果，审计失败会阻止新的绑定（`agent-preset-registry/src/mount.ts`）。
- **服务隔离**：preset 的服务提供者与它的消费者必须共享同一个 `cordis:group` 隔离 realm；entry-local 隔离不会穿透到 Agent 注册 scope，`agentPresets.serviceFor()` 是显式读取保留组合的通道（README 实现节）。
- **Shipped 组合与用户默认**：Web 端的定义来自 `dsh-web-app` bundle，standard、minimal、ptc、cordis 四个 shipped preset 各自用一份 patch 文件插入声明行；用户在 Web 编辑器保存的改动以同一个 Loader id 覆盖该行的 `config.plugins`（`packages/bundle/web-app/presets/standard.patch.yml`）。
- **增删都走组合 patch**：注册表不扫描目录，也没有 copy()、remove() 这类文件操作和 preset.yml 显示文件；新建 preset 或覆盖 shipped preset 都是装一次 bundle patch，作者化在会话内完成（`plugin_manager`）。

## 2. 创建、选择与会话绑定

- **绑定发生在会话创建期**：session-controller 的 Agent owner 在 create/resume 之前解析 preset，把挂载动作放进 agent factory 发布前的 setup 阶段；挂载失败会让这次创建或恢复整体失败（`packages/api/session-controller/src/agent.ts`）。
- **记录值与选择事件**：会话日志保留请求的 preset id，之后的切换以 `agent-preset/selected` 事件追加；读取时 presetForSession(session) 同步返回最新记录值，没有记录则为 null。冷读渲染用 acquireScope(id) 取得修订租约，用完调用 dispose 释放（`agent-preset-registry/src/index.ts:89, 389`）。
- **切换只在 blank 会话允许**：select() 对同一会话串行执行，先看 turnBoundaryOf() 报出的开放回合与历史回合数，已经开过回合就返回 `agent-preset/locked`；通过检查后 recompose() 换掉父链并追加选择事件。会话记录的 preset 与 Agent 正在运行的修订一致时直接返回，不记事件也不发 tools/change（`agent-preset-registry/src/index.ts:365-387`）。
- **默认 preset 来自用户设置**：ui-agent-preset 通过 Remote settings 写入 agent-preset-registry 命名空间的 `selectedDefault`，取值在读取时解析；新会话立即采用，运行中的会话不受影响（`packages/client/ui-agent-preset/src/client/settings-store.ts:35`）。
- **部署没有组合 preset roster 时**：复用记录过 preset 的会话会得到 ApiSessionPresetConflict（`session-controller/src/agent.ts:42-48`）；请求未知或非法的 preset 分别抛 `agent-preset/not-found` 与 `agent-preset/invalid`。

## 3. 提示词字段、优先级与输出契约

- **注册表的输入有三类**：section（含 name、order、text 与 complete 标记）、动态 context（组装成一条 user 角色快照）与 prompt variable。工具 schema 走另一条通道进入组装，不经过这个瀑布。同名 section 遵循 scoped 覆盖全局，同层重复注册直接抛错（`packages/core/system-prompt/src/index.ts:434-620`）。
- **顺序约定**：`deployment:persona-prefix` 与 `deployment:persona-suffix` 各占固定槽位，前者是身份段，后者追加在一方指引之后；plan 模式提示段的 order 为 50，工具指引占 100 到 199（`packages/core/system-prompt/src/index.ts:196-205`）。
- **persona 行只应挂在 scope 内**：dsh-persona 挂进 preset 会遮蔽该会话的部署 persona，挂到全局一层则与注册表自身的 persona 注册冲突并直接报错。可配字段有 prefix（必填）、suffix、complete 与 includeRuntimeContext，其中 complete 让 prefix 成为唯一提示词，includeRuntimeContext 关闭该 scope 的运行时上下文快照（`packages/preset/persona/src/index.ts`）。
- **部署 persona**：由 system-prompt 插件自身的 config 提供；Web bundle 的 standard preset 把 `You are a coding agent powered by the {{model}} model.` 用作 persona prefix（`packages/bundle/web-app/presets/standard.patch.yml`）。
- **输出契约**：renderPrompt 对 sections 做严格 `{{variable}}` 插值，未知或未定义的变量会抛错，空段被过滤，各段之间以空行拼接（`packages/core/system-prompt/src/index.ts:296`）。
- **内置变量**：会话模型选择变量由组装侧注入；内置的 `{{cwd}}` 提示词变量已经移除，会话执行目录改由 working-directory 以 user 上下文的形式提供（`docs/subsystems/working-directory.md`）。
- **自定义组装的入口**：system-prompt/assemble 是一个按 scope 过滤的 waterfall，输入是只含 sections、contexts、variables 的 `PromptPresentation`，返回结果里的 tools 字段会被忽略；工具声明由 ctx.tools 的 prompt provider 负责。
- **上下文刷新**：动态上下文 provider 在请求准入阶段会再求值一次，时机在 pre-step 监听与路由准备之后，因此 provider 要按每步可能多次求值来写（`docs/upgrade-guide/v0.2.1-alpha.1/working-directory/guide.md`）。

## 4. 模型、Provider 与生成参数

- **模型属于 Agent 运行参数**：composition 里没有模型字段，Agent 级选项只有 provider、model、maxTokens 这类运行参数（`packages/core/agent/src/runtime-types.ts`）。
- **默认值**：agent-default-model 插件把 provider、model 与可选 reasoning effort 作为 settings namespace 分层提供，Session Controller 在 create/resume 时据此建立初始选择。
- **会话级选择**：agent-loop 持有持久的 modelSelection 投影，并为每个 Agent 构造 agent.model（AgentModel）对象。select() 追加 `model/selection` 事件，current() 读取当前值，重启后从投影恢复，未被使用过的选择也一并恢复。该选择在每步准备时冻结，这一步及其重试沿用同一路由；agent/request 瀑布已弃用，监听器不能再改 provider、model 或 effort（`packages/core/agent/src/model-selection.ts:72-160`）。
- **子 agent 继承**：子 agent 默认继承父的路由；打开 modelSelection 配置后，模型可以在委派时选择路由字段，modelDiscovery 则提供一个 scope 内唯一的 list_subagent_models 发现工具，两者默认关闭（`packages/subagent/tool-subagent/src/index.ts:58-100`）。
- **思考等级与温度**：由 LLM 适配层按 ReasoningEffortId 词汇处理，角色声明里没有对应字段。

## 5. 工具、知识库、记忆与子 Agent

- **工具由 preset 行声明**：composition 里的工具插件行注册进 preset scope 的 tool registry，一个 preset 向模型暴露哪些工具，就由这组插件行决定；工具 schema 经 tool provider 进入组装，toolOrder 配置可以固定模型可见顺序。standard preset 覆盖的能力包括（`packages/bundle/web-app/presets/standard.patch.yml`）：

  - shell 与文件系统
  - 后台任务
  - skills
  - 目标
  - plan 模式
  - 子 agent
  - 团队任务
  - 时序类工具

- **服务 realm 规则**：preset 发布服务时必须把它放进带隔离 realm 的 `cordis:group`；发布到 root realm 的行在挂载时就被拒绝，每次绑定前激活审计还会复查一遍。
- **子 Agent 组合**：spawn 子 agent 时用 agentPreset 指定自己的组合，可选的多个组合经 allowedAgentPresets 暴露给父模型；旧的 persona 与 toolFilter 配置已被拒绝。fork 子 agent 继承父的 preset，无法单独换 persona 或裁剪工具（`docs/upgrade-guide/v0.2.1-alpha.1/subagent-preset-composition/guide.md`）。
- **知识库与记忆**：没有向量知识库，接近这项能力的是 preset 可携带的 skills 目录，dsh-agent-preset 自带四套技能包，工作区指令则由 agent-instructions 注入；记忆就是会话日志加压缩，跨会话没有自动记忆。

  - agent-experience
  - cordis-plugin-development
  - editing-cordis-compositions
  - cordis-composition-reference

- **工作区指令以 user 角色消息注入**：dsh-agent-instructions 按 AGENTS.md、CLAUDE.md 及其 .local 变体逐个加载候选文件，把内容作为带 agent-instructions source 的用户消息放进请求，并在文件被 read、write、edit 触碰后增量更新（`packages/context/agent-instructions/src/index.ts`）。
- **指令预算按链计算**：maxBytes 分别约束用户全局链（`$DSH_HOME/AGENTS.md` 与共享 agents 根）和项目链，一条同时装下两条链的消息最多可达到配置值的两倍，基座配置是 65536。maxBytes 还参与基线身份的计算，改动之后每个恢复会话都会收到一次完整替换基线（`packages/context/agent-instructions/src/config.ts`）。
- **harness home 统一解析**：指令加载器从 resolveDshHome() 取得 harness home，解析 `$DSH_HOME`，未设置时落到 `~/.dsh`，dshHome 字段已不再接受（`docs/upgrade-guide/v0.2.1-alpha.1/instruction-home-override/guide.md`）。

## 6. 资产、变量、开场白与用户档案

- **preset 可携带资产**：声明行的 plugins 只能引用包名与配置，资产跟着包一起发布；dsh-agent-preset 的 skills/ 目录就是这样随包发出去，再由 skill-filesystem 挂载。
- **头像、开场白与快捷回复**：本次未找到相关字段，声明行可填的只有 id、plugins、name、description、order。
- **变量**：只有系统的 `{{variable}}` 模板（如 persona 文本引用 `{{model}}`），没有用户自定义的占位符语法；`{{cwd}}` 已整体移除。
- **用户档案**：没有用户档案对象；`AGENTS.md` 链由 agent-instructions 带入请求，语义上接近「项目档案」。

## 7. 作者化、安装与兼容性

- **作者化走声明编辑加 bundle 安装**：注册表只维护声明，不写文件；read Remote 把某条声明的子插件列表渲染成 entry-list YAML（含 `!!js` 条件）交给客户端展示，反方向没有接口接收 YAML 写回。新建或覆盖 preset 都是一次 bundle patch：insert 一条 `@deepseek-ai/dsh-agent-preset` 声明行，或者按该行的 id 打补丁，再用 `plugin_manager` 装进 profile（`agent-preset-registry/README.md`）。
- **组合作为输入**：声明行携带的 plugins 由内存 Loader 树装载，注册表的运行期变更留在内存，不回写文件。
- **健康与降级**：失败的声明仍留在 roster 上可见；激活失败会拦住新的绑定，已绑定 Agent 的旧修订照常使用。
- **修订回收**：更新或删除声明会让上一修订退役；旧修订的实现不跨进程重启保留（Known Limitations）。
- **未知 preset 与默认值**：resolve() 遇到未知 id 直接抛错；settings 里可以先存一个暂时不存在的默认值，等真正解析时才失败。
- **版本与兼容**：会话日志记录 preset id 与 blank 期内的选择事件，两者都没有的旧日志保留空值。profile patch 里遗留的 modeSelectionEnabled 字段被声明表忽略，注册表既不读也不改写它。
- **安全边界**：YAML 与插件都能执行 Host 代码，preset 本身不提供沙箱隔离；用户覆盖会整份替换子插件列表，builtin 列表后续的变化不会自动合并进来（Known Limitations）。

## 8. 配置界面、输出契约与可见字段

- **浏览器侧的远程接口**：AgentPresetRegistry 作为 Typert Remote 服务对外暴露 list、resolve、read、select 等方法，客户端由 ui-agent-preset 包消费；blank-only 切换与选择幂等这两条规则在服务端强制执行（`packages/client/ui-agent-preset`）。
- **运行时可见性**：会话列表条目携带由投影与记录得出的 agentPreset，Web 端的新会话 chip、会话头标签与 Settings roster 读的是同一个值。冷读场景用 acquireScope() 的修订租约解析 scoped 能力，无需恢复 Agent（`agent-preset-registry/src/index.ts:389`）。
- **组合盘点**：inspectCompositions() 返回注册表保留的所有修订，按 Agent context 过滤时只返回该 Agent 精确对应的修订；每条 AgentPresetInspection 记录 preset id、分离出来的活动模块引用与解析基址，以及泄露的服务名（`composition-inventory.ts`）。
- **历史快照语义**：日志冻结 preset id 与选择事件，两者足以在冷读时重建会话的运行时组合，system prompt 正文不写进日志；assistant 消息则保留 provider、model 元数据。

## 9. 与 pi 的继承与差异

**继承点仅在 LLM 层**：harness 把 `@earendil-works/pi-ai`（1.3.0）作为依赖，由 `packages/llm/llm-pi-ai` 包装成 LLM 适配器之一；同一层另有直连 DeepSeek API 的 llm-deepseek、账号态的 llm-deepseek-account 与 API-key 态的 llm-deepseek-api-key（`pnpm-workspace.yaml`）。这层关系覆盖模型目录、thinking level 与多协议，落在 Provider 渠道层，角色与提示词体系独立于它。本次未找到任何代码、文档或配置把 preset 与 pi 的 agent 配置（SYSTEM.md、APPEND_SYSTEM.md、`~/.pi/agent/` 下的设置）联系起来。

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

- **声明式 preset 走组合 patch**：preset 与其它插件行共用同一套 Loader 机制，编辑、覆盖、启停都走组合 patch；新增 preset 由作者产出 bundle，没有把目录拷出来即可复用的轻量路径。
- **修订制而非原地重载**：更新声明会新建修订并让旧修订自然退出，运行中的 Agent 保留旧组合，避免会话中途换掉已记录的工具集合；代价是旧实现不跨重启保留。
- **blank-only 切换是产品规则而非机制限制**：防止已记录工具调用被新组合重放；判断依据是 turn boundary 投影，服务端强制。
- **host plane 与 agent plane 分离**：注册表、沙箱、审批、持久化、模型路由留在 host composition；preset 只允许注册模型可见的行与服务，泄露检测由激活审计兜底。
- **急切加载**：所有声明的内存树在组合加载期建立，使会话创建不必等待装载；代价是启动期开销随 preset 数量增长。
- **模型选择每步冻结**：以"该步及其重试使用同一路由"换取可重放与可审计。

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
