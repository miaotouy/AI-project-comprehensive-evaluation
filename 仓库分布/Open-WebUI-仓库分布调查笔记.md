# Open WebUI 仓库分布调查笔记

> 调查对象：`https://github.com/open-webui/open-webui`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`c38885a1a737da4968f157092f304f3b5481d0bf`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Python/Svelte 构建、静态资源、部署说明与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-11-04）：Git 跟踪文件 5274 个；可识别源码 1230 文件 / 424593 行；文档 39 文件 / 17172 行；测试 2 文件 / 59 源码行。主线提交节奏：历史跨度 127 天共 19 次，折算 4.49 次/30天，近90天 19 次（浅克隆，历史可能不完整）。

## 结论摘要

Open WebUI 是 Python 后端与 Svelte 前端合仓的 Web 应用。当前 5,274 个跟踪文件中静态资源仍是主要组成，所以总文件数主要反映资源规模；可识别源码集中在 `backend/open_webui`（218,861 行）与 `src`（204,028 行）。仓库根部另有独立的 `crypto/encryption` 组件，用于生成前端加密产物。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 5274 |
| 可识别源码 | 1230 文件 / 424593 行 |
| 文档 | 39 文件 / 17172 行 |
| 测试 | 2 文件 / 59 源码行 |

Svelte 165,882 行（39.1%）、Python 132,269 行（31.1%）、JavaScript 78,782 行（18.6%）、TypeScript 35,041 行（8.3%）、CSS 11,490 行（2.7%）；占比按可识别源码总行数 424,593 计算。前端仍以 Svelte 与 JavaScript 为主，TypeScript 占比相对上升，与 `src` 下新增的 API 客户端和工具模块一致。仓内文档主要是根 README/CHANGELOG 与多语言 README，完整用户文档不在当前 `docs` 目录展开。

除前后端主体外，仓库根部新增 `crypto/encryption`（Rust crate，经构建脚本 vendored 到前端）与 `scripts/encryption`，构成独立的加密组件发布链；`static` 目录保持 3,874 个文件，承载前端构建与 PWA 资源。

## 测试与跨平台边界

`package.json` 和 `pyproject.toml` 声明 Vitest/Pytest 依赖与命令，但当前 Git 跟踪快照按统一规则只识别到 2 个测试文件（`src/lib/components/workspace/common/versionDiff.test.ts` 与 `test/` 下的占位资产）；快照内结论是“仓内显式测试资产很少”，覆盖范围限于 Git 跟踪内容，外部 CI 与私有测试另行核实。产品是响应式 Web/PWA，通过 pip、Docker、Kubernetes 等运行；README 所列原生桌面应用位于另一个仓库，本仓不含其平台代码。

## 关键源码索引

- `backend/open_webui/`：Python API、模型与服务
- `src/lib/`、`src/routes/`：Svelte 前端
- `crypto/encryption/`、`scripts/encryption/build.py`：Rust 加密组件与手动发布脚本
- `pyproject.toml`：前后端合并打包
