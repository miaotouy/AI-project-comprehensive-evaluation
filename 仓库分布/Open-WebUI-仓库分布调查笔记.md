# Open WebUI 仓库分布调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`0a7c15832fb30b1903753e83f81dc7d27e5b0944`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Python/Svelte 构建、静态资源、部署说明与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-09-16）：Git 跟踪文件 5061 个；可识别源码 1033 文件 / 360591 行；文档 17 文件 / 6634 行；测试 3 文件 / 112 源码行。主线提交节奏：历史跨度 68 天共 10 次，折算 4.41 次/30天，近90天 10 次（浅克隆，历史可能不完整）。

## 结论摘要

Open WebUI 是 Python 后端与 Svelte 前端合仓的 Web 应用。当前 5,061 个跟踪文件中静态资源仍是主要组成，所以总文件数主要反映资源规模；可识别源码仍集中在 `backend/open_webui` 和 `src/lib`。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 5061 |
| 可识别源码 | 1033 文件 / 360591 行 |
| 文档 | 17 文件 / 6634 行 |
| 测试 | 3 文件 / 112 源码行 |

Svelte 130,131 行（36.1%）、Python 113,970 行（31.6%）、JavaScript 77,707 行（21.6%）、TypeScript 26,225 行（7.3%）；占比按可识别源码总行数 360,591 计算。前端以 Svelte 与 JavaScript 为主，TypeScript 占比较小。仓内文档主要是根 README/CHANGELOG 等文件，完整用户文档不在当前 `docs` 目录展开。

## 测试与跨平台边界

`package.json` 和 `pyproject.toml` 声明 Vitest/Pytest 依赖与命令，但当前 Git 跟踪快照按统一规则只识别到 3 个测试文件；应解读为“仓内显式测试资产很少”，不能据此推断外部 CI 或私有测试。产品是响应式 Web/PWA，通过 pip、Docker、Kubernetes 等运行；README 所列原生桌面应用位于另一个仓库（`README.md:52,102`），本仓不含其平台代码。

## 关键源码索引

- `backend/open_webui/`：Python API、模型与服务
- `src/lib/`、`src/routes/`：Svelte 前端
- `pyproject.toml:180-210`：前后端合并打包
