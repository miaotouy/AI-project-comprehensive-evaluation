# Dify 仓库分布调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`e568478f8f2b95efc189b698c2f4386a7dbe1c3e`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 pnpm workspace、Docker Compose、Web/API/Agent 入口与测试目录
>
> 调查范围：模块、语言、文档、测试、部署与跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 把后端、前端与运行面收在同一个仓库，构成一个 LLM 应用开发平台：`api` 用 Python 承担服务、数据模型、任务和 Provider，`web` 用 TypeScript 承担管理与运行界面，共享契约与 UI 集中在 `packages`，Agent 与命令行运行面由同仓的独立子目录提供。当前快照有 15,833 个 Git 跟踪文件、12,655 个可识别源码文件 / 2,645,433 行源码；测试文件 4,950 个，主要分布在前端、后端、共享包与端到端测试四个方向。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 15,833 |
| 可识别源码 | 12,655 文件 / 2,645,433 行 |
| 文档 | 218 文件 / 72,441 行 |
| 测试 | 4,950 文件 / 1,278,607 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `api` | 4,883 / 1,255,018 |
| `web` | 8,524 / 1,031,119 |
| `packages` | 1,302 / 248,322 |
| `dify-agent` | 257 / 47,581 |
| `cli` | 233 / 21,089 |
| `dify-agent-runtime` | 79 / 14,410 |

仓库根部声明 `pnpm@12.16.1`，由 `pnpm-workspace.yaml` 定义工作区，自托管发行入口的 Docker Compose 放在 `docker/`。`packages/contracts` 是共享契约的主要区域，含 250 个文件、187,162 行，规模已明显超过前端组件包；前端组件包为 `packages/dify-ui`，配套包还包括 openapi-content-mapper、tooling 与 dev-proxy，分别负责内容映射、构建工具链和开发代理。

## 语言、文档与测试

Python 1,301,129 行、TypeScript 1,249,132 行、JavaScript 62,021 行，前三者合计占可识别源码约 98.7%。TypeScript 主要来自 `web` 与共享包，Python 主要来自 `api`；此快照中 Python 行数已超过 TypeScript。Go 代码集中在 Agent 运行时和辅助组件。

文档共 218 个文件，主要分布在以下区域：

| 区域 | 文档文件 |
| --- | ---: |
| `docs` | 50 |
| `web` | 40 |
| `packages` | 26 |
| `api` 源码旁说明 | 20 |
| `dify-agent` | 18 |

测试文件同样按区域分布，测试树覆盖前后端与 Agent 运行面；本次未运行测试。

| 区域 | 测试文件 |
| --- | ---: |
| `web` | 2,366 |
| `api` | 2,058 |
| `e2e` | 168 |
| `packages` | 138 |
| `dify-agent` | 91 |

除 `api`、`web`、`packages` 三个主体外，仓库还保留了几个承担独立职责的目录：

- `e2e`：168 个端到端测试文件
- `sdks`：Node 与 PHP 客户端
- `scripts` 与 `dev`：开发脚本和本地环境
- `.agents` 与 `skills`：Agent 技能材料

端到端测试与 Agent 技能材料已从主代码目录分拆出来。

## 跨平台与工程配套

产品主要以 Web 服务、自托管 Docker 和 CLI 形态交付。核心部署单元是 `web` 与 `api`；CLI、Agent 及其运行时提供独立运行入口，`sdks` 保存 Node 与 PHP 等客户端。CI、部署与开发配套集中在 `.github/workflows`、`docker/` 以及开发容器和脚本目录中。README 的安装路径与仓库构建配置均为静态确认结果，未进行实际部署验证。

## 已确认边界与未验证事项

- 统计包含 Git 跟踪的前端资源、翻译、文档和测试夹具；未静默排除大型资源。
- 主线提交历史为浅克隆（按 first-parent 计 2,221 次提交，跨度 2026-08-15 至 2026-11-04 共 82 天，约 813 次/30 天）；统计仅覆盖当前浅克隆可见的 first-parent 主线，每个合并点计一次。
- 本次未运行 Docker Compose、Web 构建、Python 服务、CLI 或端到端测试。

## 关键源码索引

- `package.json`、`pnpm-workspace.yaml`：Node/pnpm 工作区与前端脚本
- `api/`：Python 服务核心、模型、任务与 Provider
- `web/`：Web 前端与运行界面
- `packages/contracts/`、`packages/dify-ui/`：共享契约与前端组件
- `dify-agent/`、`dify-agent-runtime/`、`cli/`：Agent 与 CLI 运行面
- `e2e/`：端到端测试
- `docker/docker-compose.yaml`：自托管部署入口
