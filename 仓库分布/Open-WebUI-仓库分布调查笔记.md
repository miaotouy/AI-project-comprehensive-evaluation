# Open WebUI 仓库分布调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`d3e8bf3405e848cfba377814d0aa7ba7290e414d`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Python/Svelte 构建、静态资源、部署说明与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-08-27）：Git 跟踪文件 5059 个；可识别源码 1032 文件 / 359189 行；文档 17 文件 / 6599 行；测试 3 文件 / 112 源码行。主线提交节奏：历史跨度 58 天共 6 次，折算 3.1 次/30天，近90天 6 次（浅克隆，历史可能不完整）。

## 结论摘要

Open WebUI 是 Python 后端与 Svelte 前端合仓的 Web 应用。当前 5,059 个跟踪文件中静态资源仍是主要组成，所以总文件数主要反映资源规模；可识别源码仍集中在 `backend/open_webui` 和 `src/lib`。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 5059 |
| 可识别源码 | 1032 文件 / 359189 行 |
| 文档 | 17 文件 / 6599 行 |
| 测试 | 3 文件 / 112 源码行 |

Svelte 122,159 行（35.3%）、Python 109,779 行（31.7%）、JavaScript 77,706 行（22.5%）、TypeScript 23,960 行（6.9%）。这里 JavaScript 较多，前端并非纯 TypeScript。仓内文档主要是根 README/CHANGELOG 等文件，完整用户文档不在当前 `docs` 目录展开。

## 测试与跨平台边界

`package.json` 和 `pyproject.toml` 声明 Vitest/Pytest 依赖与命令，但当前 Git 跟踪快照按统一规则只识别到 2 个测试文件；应解读为“仓内显式测试资产很少”，不能据此推断外部 CI 或私有测试。产品是响应式 Web/PWA，通过 pip、Docker、Kubernetes 等运行；README 所列原生桌面应用位于另一个仓库（`README.md:52,102`），本仓不含其平台代码。

## 关键源码索引

- `backend/open_webui/`：Python API、模型与服务
- `src/lib/`、`src/routes/`：Svelte 前端
- `pyproject.toml:180-210`：前后端合并打包
