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

Dify 是前后端合仓的 LLM 应用开发平台：`api` 以 Python 承担服务、数据模型、任务和 Provider，`web` 以 TypeScript 承担管理与运行界面，`packages` 提供共享契约与 UI，`dify-agent`/`dify-agent-runtime` 和 `cli` 形成 Agent 与命令行运行面。当前快照有 15,833 个 Git 跟踪文件、12,655 个可识别源码文件 / 2,645,433 行源码；测试文件 4,950 个，主要集中在 `web`、`api`、`e2e` 和 `packages`。

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

仓库根部声明 `pnpm@12.16.1` 与 `pnpm-workspace.yaml`；Docker Compose 位于 `docker/`，可作为自托管发行入口。`packages/contracts`（250 文件 / 187,162 行）是共享契约的主要区域，规模已明显超过前端组件包；`packages/dify-ui` 提供前端组件，另有 `packages/openapi-content-mapper`、`packages/tooling` 与 `packages/dev-proxy` 等构建/映射配套包。

## 语言、文档与测试

Python 1,301,129 行、TypeScript 1,249,132 行、JavaScript 62,021 行，前三者合计占可识别源码约 98.7%。TypeScript 主要来自 `web` 与共享包，Python 主要来自 `api`；此快照中 Python 行数已超过 TypeScript。Go 代码集中在 Agent 运行时和辅助组件。

文档共 218 个文件，主要位于 `docs`（50 个）、`api` 源码旁说明（20 个）及 `packages`（26 个）、`web`（40 个）与 `dify-agent`（18 个）。测试识别到 `web` 2,366 个、`api` 2,058 个、`e2e` 168 个、`packages` 138 个和 `dify-agent` 91 个，测试树覆盖前后端与 Agent 运行面；本次未运行测试。

除 `api`、`web`、`packages` 主体外，仓库还保留了独立的 `e2e`（168 文件）、`sdks`（Node/PHP 客户端）、`scripts`、`dev` 与 `.agents`、`skills` 目录，说明端到端测试与 Agent 技能材料已从主代码目录分拆出来。

## 跨平台与工程配套

产品主要以 Web 服务、自托管 Docker 和 CLI 形态交付。`web` 与 `api` 是核心部署单元，`cli`、`dify-agent` 和 `dify-agent-runtime` 提供独立运行入口；`sdks` 保存 Node/PHP 等客户端。`.github/workflows`、`docker/`、`.devcontainer/` 和 `scripts/` 形成 CI、部署与开发配套边界。README 的安装路径与仓库构建配置均为静态确认结果，未进行实际部署验证。

## 已确认边界与未验证事项

- 统计包含 Git 跟踪的前端资源、翻译、文档和测试夹具；未静默排除大型资源。
- 主线提交历史为浅克隆（按 first-parent 计 2,221 次提交，跨度 2026-08-15 至 2026-11-04 共 82 天，约 813 次/30 天），不能据此代表完整项目历史。
- 本次未运行 Docker Compose、Web 构建、Python 服务、CLI 或端到端测试。

## 关键源码索引

- `package.json`、`pnpm-workspace.yaml`：Node/pnpm 工作区与前端脚本
- `api/`：Python 服务核心、模型、任务与 Provider
- `web/`：Web 前端与运行界面
- `packages/contracts/`、`packages/dify-ui/`：共享契约与前端组件
- `dify-agent/`、`dify-agent-runtime/`、`cli/`：Agent 与 CLI 运行面
- `e2e/`：端到端测试
- `docker/docker-compose.yaml`：自托管部署入口
