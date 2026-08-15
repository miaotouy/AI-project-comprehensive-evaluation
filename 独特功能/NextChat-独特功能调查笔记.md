# NextChat 独特功能调查笔记

> 调查对象：`../../NextChat`（重点 `app/components/home.tsx`、`app/components/exporter.tsx`、`app/client/api.ts`、`app/components/search-chat.tsx`、`next.config.mjs`）
>
> 调查更新日期：2026-08-12
>
> 代码快照：`defdcdb55d850cd12c4c657eb83729fd66e215c0`（分支：`main`）
>
> 调查方式：局部补查。按代码路由反向盘点（`home.tsx` 全部路由面 + `app/api/` 全部路由 + 侧栏入口），对每个候选追源码主链并与现有十类笔记交叉核对；抽查 `exporter.tsx`/`api.ts`/`search-chat.tsx`/`next.config.mjs`；未启动应用与第三方服务
>
> 调查范围：第三批候选——Mask、Artifact、OpenAPI、MCP、分享路由；从代码路由反向盘点是否有独特产品面未被现有笔记覆盖
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 的 README 以部署与企业版为主，不是候选清单来源；按代码路由反向盘点后确认：**Mask、Artifact、OpenAPI 插件、MCP（含 MCP market 页面）、SD 图像面板与 Artifact 分享均已由现有类目笔记闭环覆盖**，不产生独特功能专项。反向盘点发现两个未覆盖的小产品面：

1. **会话分享（ShareGPT）**：导出预览面板的分享按钮 → `ClientApi.share` → 经 `next.config.mjs` 的 `/sharegpt` rewrite（Web 模式）或直连（桌面 App 模式）上传第三方接口，返回 `shareg.pt/<id>` 链接。入口与请求链已确认，但整条链依赖第三方平台且文档未提及，属外部依赖（暂缓）。
2. **会话全文搜索页**：侧栏入口的独立搜索页面，对全部会话消息做内存全量 `indexOf` 子串扫描并回显上下文片段。属普通会话检索能力，归并已有类目，不进入独特功能统计。

本次未找到超出现有类目的独特功能（“本次未找到”而非项目级否定）。

## 介绍声明与候选盘点

README 的 Features 章节（README.md:80-93）以部署、PWA、Markdown、prompt 模板（mask）为主；README 提到的 MCP 需要 `ENABLE_MCP=true` 构建（README.md:54-58）。按待查清单要求，候选来自代码路由而非 README。`home.tsx:160-220` 的路由面清单与候选状态：

| 路由/产品面 | 候选 | 状态 | 覆盖笔记 |
|---|---|---|---|
| `/chat`、`/new-chat` | 普通 Chat | 归并已有类目 | Chat、Chat UI、会话与消息管理 |
| `/masks` | Mask（prompt 模板/角色） | 归并已有类目 | Agent 角色笔记（整篇）、生成式输出笔记（enableArtifacts 开关） |
| `/plugins` | OpenAPI 插件工具 | 归并已有类目 | Agent 工具笔记 §1/§2 |
| `/mcp-market` | MCP 市场与连接 | 归并已有类目 | Agent 工具笔记 §3、Chat UI 笔记 §1 |
| `/artifacts/:id` | Artifact 预览与 KV 分享 | 归并已有类目 | 生成式输出笔记（整篇）、消息渲染器笔记 §5 |
| `/sd`、`/sd/new` | SD 图像生成面板 | 归并已有类目 | 生成式输出笔记 §3/§4/§8 |
| `/search-chat` | 会话全文搜索页 | 归并已有类目（普通检索） | 见下 |
| 导出面板分享按钮 | 会话分享（ShareGPT） | 入口确认 + 外部依赖（暂缓） | 见下 |

## 已归并到现有类目的能力

- **Mask**：`app/store/mask.ts` 的角色模型、内置 Mask 构建加载、会话复制语义、导入导出与 `#/new-chat?mask=<id>` 分享链接均由 Agent 角色笔记覆盖（§1-§6、§8），含“同步开关/可变副本”等边界结论。
- **Artifact**：HTML 探测、沙箱 iframe、Cloudflare KV 分享与独立路由由生成式输出笔记整篇覆盖。
- **OpenAPI/MCP**：OpenAPI operation → function schema 的转换与执行、MCP stdio 子进程与 `json:mcp:` 文本协议由 Agent 工具笔记覆盖。
- **会话全文搜索页**：侧栏入口（`app/components/sidebar.tsx:39`）→ `SearchChatPage`（`app/components/search-chat.tsx:18-68`）对全部会话消息做大小写归一后的子串扫描，命中片段取上下文 ±35 字符拼接，按命中内容长度排序，点击跳转会话。无索引、无正则、无消息级持久化。属于普通会话检索（现有会话与消息管理笔记 §5 未覆盖此页面，此处补齐归并结论），不进入独特功能统计。

## 声明不符、外部依赖与暂缓项

- **会话分享（ShareGPT）**：入口为导出预览面板的 Share 按钮（`app/components/exporter.tsx:357-407`），经 `ClientApi.share`（`app/client/api.ts:191-228`）上传：Web 模式 fetch `/sharegpt`，由 `next.config.mjs:96-97` 的 rewrites 转发到 `https://sharegpt.com/api/conversations`；桌面 App 模式直连 raw URL，返回 `https://shareg.pt/<id>`。请求体在用户消息后追加固定的"Share from NextChat"溯源消息（api.ts:198-205，注释声明用于数据清洗）。特点与边界：文档/README 未提及该能力；`/sharegpt` 不是 API 路由而是构建期 rewrite，静态导出部署下不可用（推断）；链路依赖第三方平台可用性与数据策略，未运行验证。按"仓库外 SaaS 依赖"处理为**暂缓**，不进入特色统计。
- README 未声明其他独特产品工作流；本次未发现“介绍声明与实现不符”的候选。

## 对特色贡献统计的影响

- 无候选达到主链确认且未归类；不新增特色贡献。ShareGPT 分享保留为入口确认/暂缓状态，供“外部 Agent 协议/社交分享”类聚类参考。

## 未验证事项

- ShareGPT 端到端流程（需网络、第三方服务与部署形态匹配）；静态导出模式下 `/sharegpt` rewrite 的可用性推断未实测。
- 搜索页的输入防抖（`setInterval` 轮询 input value）与实际交互、超长会话下全量扫描的性能未运行验证。

## 关键源码索引

- `app/components/home.tsx:160-220`（路由面全清单）
- `app/components/exporter.tsx:304-407`（导出预览与分享按钮）
- `app/client/api.ts:191-228`（share 请求与 shareg.pt 链接）
- `next.config.mjs:96-97`（/sharegpt rewrite）
- `app/components/sidebar.tsx:39`、`app/components/search-chat.tsx:18-68`（会话全文搜索页）
