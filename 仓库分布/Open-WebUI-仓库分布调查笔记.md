# Open WebUI 仓库分布调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`01f4282f1ffe0d6212f58d3afbeae21fffd0c4be`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Python/Svelte 构建、静态资源、部署说明与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Open WebUI 是 Python 后端与 Svelte 前端合仓的 Web 应用。5,031 个跟踪文件中有 3,870 个位于 `static`，所以总文件数主要反映静态资源规模；可识别源码仍集中在 `backend/open_webui`（196,710 行）和 `src/lib`（141,095 行）。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 5,031 |
| 可识别源码 | 1,011 文件 / 346,049 行 |
| 文档 | 11 文件 / 6,211 行 |
| 本次识别到的测试 | 2 文件 / 43 源码行 |

Svelte 122,159 行（35.3%）、Python 109,779 行（31.7%）、JavaScript 77,706 行（22.5%）、TypeScript 23,960 行（6.9%）。这里 JavaScript 较多，前端并非纯 TypeScript。仓内文档主要是根 README/CHANGELOG 等文件，完整用户文档不在当前 `docs` 目录展开。

## 测试与跨平台边界

`package.json` 和 `pyproject.toml` 声明 Vitest/Pytest 依赖与命令，但当前 Git 跟踪快照按统一规则只识别到 2 个测试文件；应解读为“仓内显式测试资产很少”，不能据此推断外部 CI 或私有测试。产品是响应式 Web/PWA，通过 pip、Docker、Kubernetes 等运行；README 所列原生桌面应用位于另一个仓库（`README.md:52,102`），本仓不含其平台代码。

## 关键源码索引

- `backend/open_webui/`：Python API、模型与服务
- `src/lib/`、`src/routes/`：Svelte 前端
- `pyproject.toml:180-210`：前后端合并打包
