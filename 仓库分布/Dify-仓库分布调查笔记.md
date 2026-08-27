# Dify 仓库分布调查笔记

> 调查对象：`https://github.com/langgenius/dify`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`a9319c86ee9468f6e1a56b3f22945a63b95c282f`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 pnpm workspace、Docker Compose、Web/API/Agent 入口与测试目录
>
> 调查范围：模块、语言、文档、测试、部署与跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Dify 是前后端合仓的 LLM 应用开发平台：`api` 以 Python 承担服务、数据模型、任务和 Provider，`web` 以 TypeScript 承担管理与运行界面，`packages` 提供共享契约与 UI，`dify-agent`/`dify-agent-runtime` 和 `cli` 形成 Agent 与命令行运行面。当前快照有 13,631 个 Git 跟踪文件、11,046 个可识别源码文件 / 2,236,494 行源码；测试文件 4,315 个，主要集中在 `web`、`api` 和 `e2e`。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 13,631 |
| 可识别源码 | 11,046 文件 / 2,236,494 行 |
| 文档 | 168 文件 / 47,442 行 |
| 测试 | 4,315 文件 / 1,166,075 源码行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `web` | 7,712 / 1,066,905 |
| `api` | 3,817 / 902,473 |
| `packages` | 903 / 142,929 |
| `dify-agent` | 269 / 44,718 |
| `cli` | 362 / 40,869 |
| `dify-agent-runtime` | 73 / 13,516 |

仓库根部声明 `pnpm@11.23.0` 与 `pnpm-workspace.yaml`；Docker Compose 位于 `docker/`，可作为自托管发行入口。`packages/contracts`（198 文件 / 111,313 行）是共享契约的主要区域，`packages/dify-ui` 提供前端组件。

## 语言、文档与测试

TypeScript 1,203,663 行、Python 944,117 行、JavaScript 57,556 行，前三者合计占可识别源码约 98.7%。TypeScript 主要来自 `web` 与共享包，Python 主要来自 `api`；Go 代码集中在 Agent 运行时和辅助组件。

文档共 168 个文件，主要位于 `docs`（45 个）及 `dify-agent` 文档（20 个），另有 API 源码旁的说明文件。测试识别到 `web` 2,145 个、`api` 1,680 个、`e2e` 158 个和 `dify-agent` 96 个，测试树覆盖前后端与 Agent 运行面；本次未运行测试。

## 跨平台与工程配套

产品主要以 Web 服务、自托管 Docker 和 CLI 形态交付。`web` 与 `api` 是核心部署单元，`cli`、`dify-agent` 和 `dify-agent-runtime` 提供独立运行入口；`sdks` 保存 Node/PHP 等客户端。`.github/workflows`、`docker/`、`.devcontainer/` 和 `scripts/` 形成 CI、部署与开发配套边界。README 的安装路径与仓库构建配置均支持静态确认，未进行实际部署验证。

## 已确认边界与未验证事项

- 统计包含 Git 跟踪的前端资源、翻译、文档和测试夹具；未静默排除大型资源。
- 主线提交历史为浅克隆（295 次提交，历史跨度 12 天），不能据此代表完整项目历史。
- 本次未运行 Docker Compose、Web 构建、Python 服务、CLI 或端到端测试。

## 关键源码索引

- `package.json`、`pnpm-workspace.yaml`：Node/pnpm 工作区与前端脚本
- `api/`：Python 服务核心、模型、任务与 Provider
- `web/`：Web 前端与运行界面
- `dify-agent/`、`dify-agent-runtime/`、`cli/`：Agent 与 CLI 运行面
- `docker/docker-compose.yaml`：自托管部署入口
