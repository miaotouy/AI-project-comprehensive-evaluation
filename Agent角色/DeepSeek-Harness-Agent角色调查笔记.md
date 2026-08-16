# DeepSeek Harness Agent 角色配置调查笔记

> 调查对象：`../../deepseek-harness`（重点 `packages/preset/agent-presets`、`packages/preset/persona`、`packages/core/system-prompt`、`packages/core/agent`、`packages/core/scope`、`apps/cli/config/agent-presets`、`packages/context/agent-instructions`）
>
> 调查更新日期：2026-08-16
>
> 代码快照：`47f943859bef60e4160492346772ded9b24f765a`（分支：`master`）
>
> 调查方式：只读静态源码阅读，梳理 preset 发现/挂载/加入链路、scope 分层、system prompt 组装与会话日志记录；未运行交互会话，未执行测试
>
> 调查范围：角色实体与存储、创建与会话绑定、生效优先级、system-prompt 组装、模型与生成参数、工具与子 Agent 授权、资产与变量、导入导出、运行时可见性、与 pi 的关系；排除工具执行与审批细节、LLM Provider 渠道管理、Web 客户端 UI 内部实现
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

DeepSeek Harness 没有传统聊天应用意义上的“角色卡”。它的角色体系是 **per-session 的 agent 组合**：一个 **preset** 是存放一份 `agent.cordis.yml`（顶层插件行列表）的目录，目录名即 preset id；每个 preset 在进程内只挂载一次（standing mount），所有选择它的会话通过 **scope 父链**加入这份组合，共享同一批工具注册、prompt section 和插件实例（插件内部按 Session/Agent 键存状态，因此会话之间仍然隔离）。

三条主机制：

1. **preset 分层**：`ctx.agentPresets` 服务负责发现（root 扫描、健康检查）、挂载（单飞 + 文件 stamp 换代）与加入（`mount` 绑定 agent 到 standing key、`composeFrom` 让子 agent 加入父的组合）。挂载前审计三件事：目标必须有 agent scope、每一行必须激活、不得向 root realm 发布服务（`packages/preset/agent-presets/src/mount.ts:332-381`）。
2. **system prompt 组装**：`ctx.systemPrompt` 是按 scope 分层的注册表（section / context / tools / variables），组装时按 agent → preset standing → global 的链就近覆盖；`harness:identity`（-100）→ `deployment:persona`（0）→ 工具指引（100-199）按 order 拼接，`complete` section 可整篇替换（`packages/core/system-prompt/src/index.ts:467-542`）。persona 插件（`dsh-persona`）只是把 `deployment:persona` 槽位注册进 preset 自己的层，从而覆盖部署级 persona。
3. **模型与生成参数不属角色**：preset 不绑定模型；默认模型由独立的 `agent-default-model` 插件经 settings 分层提供，会话级选择挂在组装与请求两个 waterfall 上（`packages/core/agent/src/model-selection.ts:39-70`）。

与 pi 的关系：两项目唯一交集在 LLM 层——harness 把 `@earendil-works/pi-ai` 作为可选 LLM 适配器（`packages/llm/llm-pi-ai`），与 pi 的角色/提示词体系没有继承关系；本次未在 preset 层找到任何对 pi 的 agent 配置（SYSTEM.md、AGENTS 链进 system prompt）的参考。

## 总体生效链路

```text
session.create（Web 网关 api-proxy，packages/host/apiproxy/src/api-proxy.ts:2167）
  -> ensureSession
     resume 路径：resolveSessionPreset({header, events}) 从日志取值（api-proxy.ts:1651）
     create 路径：composeAgent(presetId?) -> presets.resolve() 取 preset id（api-proxy.ts:1227-1248）
  -> ctx.agents.create({ meta.agentPreset, setup })（api-proxy.ts:1669-1678）
     agent 未发布时执行 setup：
       presets.mount(agentCtx, id)（preset/agent-presets/src/index.ts:275-288）
         ensureStanding：createScope(selfCtx, {agentPreset: id}) 建 standing 子树（index.ts:491-534）
           mountPreset：PresetTree(Include) 把 agent.cordis.yml 挂进 standing scope（mount.ts）
         bindScopeParent(agentKey, standing.key)（index.ts:286）
  -> 每步请求前（agent-loop/src/agent.ts:225-243）：
     systemPrompt.assemble(assembleContextFor(agent))
       层链解析 agent key -> preset standing key -> 全局（system-prompt/index.ts:467-542）
     renderPrompt(assembly)（agent.ts:337）
  -> llm 请求 { system, tools, history }
```

子 agent 不同：`applyChildComposition` 在创建窗口内调用 `composeFrom(childCtx, parent.ctx)` 加入父 agent 的组合，再叠加自己的 persona 与工具过滤（`packages/subagent/subagent/src/child-agent.ts:163-175`），并在子会话 header 上记录父的组合 id。

## 1. 角色数据模型与存储

- **角色实体**：preset。`AgentPreset` 携带 id（目录名）、trust（`system`/`user`，从所在 root 继承）、path（composition 绝对路径）与可选 broken 原因；id 必须是 `[a-z0-9][a-z0-9-]*`，这是路径包含边界而不是风格规则（`packages/preset/agent-presets/src/preset.ts:18-41`）。无版本字段、无 schema 校验——除了一次浅形状检查（顶层必须是带 name 的插件行列表，`discovery.ts:55-76`）。
- **composition 文件**：`agent.cordis.yml`，用 loader 自己的 YAML 方言解析（含 `!!js`），所以健康检查不会把 loader 能接受的文件判为 broken（`discovery.ts:86-106`）。目录里的 `preset.yml` 只放显示文本（name/description/order），id 与 trust 不可在此写入（`metadata.ts:10-18`）。
- **扫描根**：roots 是配置的扫描目录（前一个 root 赢重复 id），再加上默认追加的 `<dshHome>/.agent-presets` 用户 root（`discovery.ts:41`；`index.ts:133-135`）。
- **shipped root**：随部署内置的根是 `apps/cli/config/agent-presets/`，由 CLI 启动器在装配时以 system trust 补入（`apps/cli/src/profile-boot.ts:35, 159-166`）。内置 preset 四个：standard、minimal、code、cordis（后两个有中文显示名与 order）。
- **默认 preset 是用户设置**：roster 插件把 `agent-presets` settings namespace 的 `default` 作为 `config.default` 之上的用户层；值按读取时解析，热重载立即影响新会话，运行中会话不受影响（`index.ts:141-146, 191-193`）。
- **删除策略**：`remove()` 只删第一个 `user` root 下的 preset，已加入的会话保留其 standing mount；删除当前默认时清空该设置以暴露部署默认（`index.ts:400-416`）。

## 2. 创建、选择与会话绑定

- **创建 = 复制**：`copy(from, id, name)` 整目录复制（composition、metadata、skills、资产），拒绝非法 id、已占用的 id、未知源；复制后收紧权限位、解引用符号链接、重写 `preset.yml`（去掉 name 与 order），且不挂载验证（`index.ts:380-393`；README Authoring 节）。
- **绑定在会话创建期**：唯一受支持的调用点是 agent factory 的 `setup(agentCtx)` hook——agent 尚未发布时加入组合，拒绝则整个创建回滚（`index.ts:18-21`；`api-proxy.ts:1243-1246`）。网关把解析出的 id 写进会话 header（`meta.agentPreset`），JSONL 与 SQLite 两个持久化格式都保存该字段（`packages/session/session-persistence-jsonl/src/format.ts:43, 62`）。
- **header 与日志之分**：header 记“创建时”的 preset，`resolveSessionPreset` 返回“运行中”的值（最后一条 `agent-preset/selected` 事件胜出，否则回退 header，`packages/preset/agent-presets/src/session.ts:48-54`）。会话列表、resume、fork、历史渲染全部读日志而非 header，因为 blank 期切换后历史是在新组合下产生的（`api-proxy.ts:541-551, 1649-1661`）。
- **切换仅限 blank 会话**：`agentPreset.select` 先检查会话从未有 `turn/start`，`recompose` 通过 roster 持有的唯一 re-link 能力换父链；提交成功后才把切换事件追加进日志，再以非 scoped 的客户端事件重发该事实（`api-proxy.ts:3086-3113`；`types.ts:13`）。
- **切换的锁定**：已开始的会话换组合被网关以 `agent-preset-locked` 拒绝，这是产品规则而非机制限制——已记录的工具调用无法用新组合重放。
- **冷读（无 agent）**：`standingKeyFor(id)` 只确保 standing mount、不创建 agent/session/turn，让历史渲染在无实时 agent 时也能按日志中的 preset 解析注册（`index.ts:485-488`；`api-proxy.ts:1600-1615`）。

## 3. 提示词字段、优先级与输出契约

- **注册表输入**：`PromptSection`（name/order/text/complete）、`PromptContext`（动态上下文，组装成 user 角色快照）、tool-schema provider、prompt variable 四类；section 同名时 scoped 覆盖全局，同层重复注册抛错（`packages/core/system-prompt/src/index.ts:52-75, 373-455`）。
- **顺序约定**：order -100 是 harness 身份段（“You are an AI agent powered by DeepSeek Harness.”），0 是 `deployment:persona` 槽位（`PERSONA_ORDER`），plan 模式 50，工具指引 100-199（如 bash 的 105）（`system-prompt/index.ts:128-131, 357-369`；`plan-mode/src/index.ts:225-228`；`tool-bash/src/index.ts:236-238`）。
- **部署 persona**：由 system-prompt 插件的 `config.persona` 配置提供（web-app bundle 填入 "You are a coding agent powered by the {{model}} model" 模板，`packages/bundle/web-app/cordis.patch.yml:16-19`）。
- **影子机制**：`dsh-persona` 行以同名 `deployment:persona` 槽注册进 preset 自己的 scope 层，实现按会话覆盖（`packages/preset/persona/src/index.ts:60-67`）。`complete: true` 使该 section 成为唯一提示词——minimal preset 用这招只留 persona 一句话（`apps/cli/config/agent-presets/minimal/agent.cordis.yml:8-13`）。
- **输出契约**：`renderPrompt` 对 sections 做严格 `{{variable}}` 插值（未知或未定义变量抛错）、过滤空段、以空行拼接（`system-prompt/index.ts:212-217, 258-295`）。
- **内置变量**：agent-loop 注册 `provider`/`model`/`cwd` 三个变量（`packages/core/agent-loop/src/index.ts:351-353`），会话模型选择再通过组装 waterfall 覆盖前两者（`agent/src/model-selection.ts:39-53`）。
- **专家改写口**：`system-prompt/assemble` 是 scope 过滤的 waterfall，返回值权威；但 effective complete section 在 waterfall 之后被还原为唯一 section（`system-prompt/index.ts:532-541`）。invariant companion 在同一事件上断言：roster 存在时，任何要发请求的 agent 必须已加入某 preset（`packages/preset/agent-presets/src/invariant.ts:60-71`）。

## 4. 模型、Provider 与生成参数

- **preset 不绑定模型**：composition 里没有模型字段。Agent 级 `AgentOptions` 只有 provider/model/maxTokens（`packages/core/agent/src/runtime-types.ts:24-30`）。
- **默认值**：`agent-default-model` 插件把 `provider`/`model`/可选 `reasoningEffort` 作为 settings namespace 分层提供，组合入口是 base（`packages/core/agent-default-model/src/index.ts:40-46, 64-104`）。网关每次 create/resume 用 `defaults.defaultModelSelection()` 作为 AgentOptions（`api-proxy.ts:1111-1115`）。
- **会话级选择**：`selectionFor` 把会话选择挂在 `system-prompt/assemble`（注入变量）与 `agent/request`（改写请求路由）两个 scoped waterfall；读取优先级为“本次进程内已选 > 会话日志最近的请求 header > 默认”（`api-proxy.ts:1154-1181`）。
- **子 agent 继承**：子 agent 路由继承父的 provider/model/maxTokens，除非请求显式覆盖（`child-agent.ts:68-83`）。思考等级与温度等其余采样参数不由角色持有，走 LLM 适配层。

## 5. 工具、知识库、记忆与子 Agent

- **工具由 preset 行声明**：composition 里的工具插件行注册进 standing scope 的 tool registry；一个 preset 会向模型暴露哪些工具，由该 preset 的插件行集合决定（standard 覆盖 shell、文件系统、后台任务、skills、目标、plan 模式、子 agent、工作流与 web 等能力，`apps/cli/config/agent-presets/standard/agent.cordis.yml`）。工具 schema 经 tool provider 进入组装；`toolOrder` 配置可固定模型可见顺序（`system-prompt/index.ts:140-178, 201`）。
- **服务 realm 规则**：preset 若发布服务，必须放在带 `isolate` realm 的 `cordis:group` 里（entry-local 实例）；发布进 root realm 的行在挂载时被拒、随后被 invariant 持续复查（`mount.ts:189-203, 361-367`；`invariant.ts:33-44`）。standard preset 的 plan-mode、compaction、delegation 都是这样分组的（`standard/agent.cordis.yml:104-125, 137-155, 174-233`）。
- **子 Agent**：同进程子 agent 通过 `composeFrom` 加入父组合（不是重新 mount），因此永远和父同一代组合；再叠加子自己的 persona section、工具过滤和固定委托声明（`child-agent.ts:163-175`）。`subagent:delegation` 是 order 120 的动态上下文而非 section，保持父子 system prompt 一致（`child-agent.ts:135-139`）。
- **知识库与记忆**：无向量知识库；等价物是 preset 可携带的 skills 目录（cordis preset 自带两个 skills）与 `agent-instructions` 注入的工作区指令。记忆即会话日志 + 压缩（standard preset 的 compaction 组），无跨会话自动记忆。
- **工作区指令是 user 角色消息，不是 system prompt**：`dsh-agent-instructions` 按 `AGENTS.md`/`CLAUDE.md`（及 `.local` 变体）候选加载，作为带 `agent-instructions` source 的用户消息进入请求，并在文件被 read/write/edit 触碰后增量更新（`packages/context/agent-instructions/src/index.ts:322-348`；`config.ts:11-13`）。这是与 pi 最显著的分叉（见第 9 节）。

## 6. 资产、变量、开场白与用户档案

- **preset 可携带资产**：目录复制语义下，skills 目录与任意文件随 preset 移动；相对路径插件从 preset 自己目录解析（`mount.ts:65-92`）。`copy()` 明确把 assets 列为复制范围（README Authoring 节）。
- **头像/开场白/快捷回复**：本次未找到——preset 无此字段，composition 是纯插件列表，`preset.yml` 只有 name/description/order。
- **变量**：仅系统 `{{variable}}` 模板（persona 文本引用 `{{model}}`/`{{cwd}}` 等），无用户自定义占位符语法。
- **用户档案**：无用户档案对象；`AGENTS.md` 链经 agent-instructions 进入请求，接近“项目档案”的语义。

## 7. 导入、导出、迁移与兼容性

- **作者化是 copy-only**：composition 文本从不跨接口传递，`read()` 只读文件原文，写操作只有复制/删除（`index.ts:361-393, 400-416`）。没有导入导出格式、没有“从文本创建”的入口。
- **composition 是输入而非持久化目标**：挂载子树把 loader 的 `write()` 覆盖为 no-op，防止插件卸载把共享文件截断成 `[]`（`mount.ts:110-112`）。
- **健康与降级**：broken preset（缺文件、YAML 解析失败、形状错误）留在 roster 上并带原因显示，挂载路径统一拒绝；metadata 读失败降级为无显示文本，不影响挂载（`discovery.ts:139-170`；`metadata.ts:56-64`）。
- **未知 preset 与默认值**：`resolve()` 对不存在的 id 抛 `UnknownPresetError` 并列出可用 id；settings 里存一个暂不存在的默认值被允许（目录是活的），真正解析时才失败（`index.ts:213-221`；README Config 节）。
- **版本与兼容**：session header 的 `agentPreset` 是可选字符串字段，JSONL/SQLite 都持久化；老日志没有该字段时按默认 preset 渲染（`api-proxy.ts:1604-1609`）。

## 8. 配置界面、输出契约与可见字段

- **网关端点**：`agentPresets.list` 返回 id/trust/isDefault/name/description/broken，`select` 执行 blank-only 切换，另有 read/copy/remove/openDocument 作者化端点（`api-proxy.ts:3061-3129`；`packages/client/connection/README.md` 记录了浏览器侧的权限边界）。Web 端存在对应的选择与作者化 e2e 测试（`apps/web/tests/agent-preset-selection.e2e.ts`、`agent-preset-authoring.e2e.ts`），UI 组件本身本次未细读。
- **运行时可见性**：会话列表条目携带 `agentPreset`（取自日志，`api-proxy.ts:535-551`）；切换通过非 scoped 事件广播；历史渲染用 standing key 解析工具 presenter。模型可见性来自会话选择器与 footer 类显示（Web 端），本次未确认具体组件。
- **历史快照语义**：header 冻结创建值 + `agent-preset/selected` 日志事件，两者足以在冷读时重建会话运行时的组合；system prompt 正文不进日志（模型可见 ⟺ 日志可重建 规则只要求组合可重建）。assistant 消息保留 provider/model 元数据（`agent-loop/src/agent.ts:373-379`）。

## 9. 与 pi 的继承与差异

**继承点仅限 LLM 层**：harness 以 `@earendil-works/pi-ai@0.82.1` 为依赖（`pnpm-workspace.yaml:60`），`packages/llm/llm-pi-ai` 把它包装成两条 LLM 适配器之一（另一条是直连 DeepSeek API 的 `llm-deepseek`）。这是 Provider 渠道层的关系（模型目录、thinking level、多协议），与角色/提示词体系无关。本次未找到任何代码、文档或配置把 preset 与 pi 的 agent 配置（SYSTEM.md、APPEND_SYSTEM.md、`~/.pi/agent/` 设置）联系起来。

按本类别横向比较维度，两项目差异：

| 维度 | pi（534bcbff） | DeepSeek Harness（47f9438） |
| --- | --- | --- |
| 角色实体 | 无对象；文件约定（SYSTEM.md/APPEND_SYSTEM.md/AGENTS 链/skills） | preset：目录 + `agent.cordis.yml` 插件行列表 + 可选 `preset.yml` |
| 存储粒度 | 全局 `~/.pi/agent/` + 项目 `.pi/`，按 cwd 解析 | 配置 roots + `<dshHome>/.agent-presets`，按 preset id 解析 |
| 会话绑定 | 资源随会话 cwd 解析，无选择入口 | 会话创建时 mount 绑定 scope 父链，Web 端可选可切（blank 期） |
| 提示词优先级 | SYSTEM.md 整篇替换 → APPEND → project_context → skills → cwd | 注册表 section 按 order 拼装，scoped 覆盖全局，complete 整篇替换 |
| 模型绑定 | 会话级状态 + 全局/项目设置深合并 | 会话级选择 + settings 分层默认（agent-default-model 插件） |
| 工具授权 | 会话级激活列表（默认 read/bash/edit/write） | preset 插件行声明 + toolOrder，服务须 isolate realm |
| 知识与记忆 | AGENTS 链进 system prompt 的 `<project_context>` 块 | AGENTS.md/CLAUDE.md 经 agent-instructions 以 user 角色消息注入；会话日志 + compaction |
| 导入格式 | 无（文件即配置） | 无（copy-only 作者化） |
| 历史快照 | system prompt 不随会话保存，仅 HTML 导出含快照 | header 记创建值 + `agent-preset/selected` 日志事件，冷读可重建组合 |

两者共同的取向是“没有角色 UI 驱动的人格对象，配置即代码/文件”；分叉点是 harness 把角色能力彻底插件化（composition 决定工具与提示词），并把工作区指令移出 system prompt、作为可追踪的 user 角色上下文。

## 10. 设计取舍与已确认边界

- **standing mount 一次挂载、多会话共享**：组合的插件实例、注册与投影单元只存在一份，会话隔离靠插件内部按 Session/Agent 键。代价是换代组合（文件 stamp 变化）不被回收——README 标注了无加入计数可判断最后离开者（`packages/preset/agent-presets/README.md` Known Limitations）。
- **文件 stamp 是唯一编辑感知**：换代只看 `agent.cordis.yml` 的 mtime+size，改 skill 文件或资产不会换代；已加入会话保留旧组合，文件被删也不影响运行中会话（`index.ts:491-512`）。
- **blank-only 切换是产品规则而非机制限制**：防止已记录工具调用被新组合重放；网关在拥有完整会话历史处强制。
- **host plane 与 agent plane 分离**：注册表、沙箱、审批、持久化、模型路由留在 host composition；preset 只允许注册模型可见的行与服务。未加入组合的 agent 会面对空全局层（invariant 在组装时失败）。
- **发现不做缓存**：每次 `list()`/`resolve()` 重读目录，进程运行期创作的 preset 立即可见；代价是每次读取一次 readdir（README Known Limitations）。
- **挂载拒绝三件事**：无 scope 的目标（工具会全局化）、未激活的行（等待缺失服务）、root realm 服务泄露（进程级碰撞）。

## 11. 未验证事项

- 未实际运行会话或真实 API 请求，拼装与挂载链路均为静态确认；KV cache 前缀稳定性声明（README Model Experience）未运行验证。
- Web 客户端选择器/作者化 UI 的具体交互未细读（仅确认网关端点与 e2e 测试存在）。
- `DSH_TOOLS_MODE` 环境临时开关（`packages/bundle/web-app/cordis.patch.yml:41`）与 code preset 的相互作用未验证。
- settings 文档热重载对默认 preset 与默认模型的即时生效仅静态确认。
- agent-instructions 的发现细节（文件发现、字节预算、去重）只读了入口与配置，未逐行核对 `files.ts`/`state.ts`。
- 会话日志“模型可见 ⟺ 可重建”规则对 preset 组合的实际重建（冷读渲染）未用持久化样本验证。

## 12. 关键源码索引

- `packages/preset/agent-presets/src/index.ts:275-288`：mount；`316-325`：composeFrom；`458-472`：recompose；`491-534`：ensureStanding
- `packages/preset/agent-presets/src/mount.ts:332-381`：挂载审计；`65-92`：specifier 解析；`110-112`：write no-op
- `packages/preset/agent-presets/src/discovery.ts:139-186`：root 扫描与健康；`session.ts:48-54`：resolveSessionPreset
- `packages/core/system-prompt/src/index.ts:467-542`：assemble；`212-217`：renderPrompt；`128-131`：persona 槽位
- `packages/preset/persona/src/index.ts:60-67`：persona section 注册
- `packages/core/agent-loop/src/agent.ts:225-243, 332-341`：每步组装入口；`packages/core/agent-loop/src/index.ts:351-353`：内置变量
- `packages/core/agent/src/model-selection.ts:39-70`：会话模型选择注入
- `packages/core/agent-default-model/src/index.ts:64-104`：默认模型设置
- `packages/core/scope/src/index.ts:72-82, 137-147`：scope 父链与创建
- `packages/host/apiproxy/src/api-proxy.ts:1227-1248`：composeAgent；`1651-1678`：resume/create 绑定；`3086-3113`：切换与日志
- `packages/subagent/subagent/src/child-agent.ts:163-175`：子 agent 加入
- `packages/context/agent-instructions/src/index.ts:322-348`：工作区指令注入
- `apps/cli/src/profile-boot.ts:159-166`：shipped root 注入；`apps/cli/config/agent-presets/standard/agent.cordis.yml`：内置组合示例
