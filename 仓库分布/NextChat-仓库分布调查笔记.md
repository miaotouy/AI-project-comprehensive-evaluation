# NextChat 仓库分布调查笔记

> 调查对象：`../../NextChat`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`706a18b95b714ab29b2a4842d3b9ff4f887935d5`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Next.js、Tauri、发布工作流与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

NextChat 是紧凑的单应用仓库：Next.js Web/PWA 是主体，Tauri 目录提供桌面封装。`app` 承载约 96% 的源码行；其中组件和多语言资源是最大的两个区域，因此语言包会显著影响源码量级。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 425 |
| 可识别源码 | 220 文件 / 48,347 行 |
| 文档 | 29 文件 / 3,566 行 |
| 测试 | 34 文件 / 1,347 源码行 |

`app/components` 为 51 文件/14,990 行，`app/locales` 为 21/13,184，之后是 client、API、store 和 utils。TypeScript 42,680 行（88.3%）、SCSS 5,043 行（10.4%）。文档主要是 `docs` 22 文件和 5 份根 README/翻译；测试全部集中在根 `test`，量级较小。

## 跨平台组织与边界

Next.js 同一应用用于 Web 与 PWA，`src-tauri` 将其封装为 Windows、macOS、Linux 桌面端（`package.json:9-16`；`README.md:16-30,83-106`）。README 提到 iOS 应用，但同时说明源码另行提供/尚未在本仓公开（`README.md:21,50`），因此本仓平台统计不把 iOS 计为已包含模块。

## 关键源码索引

- `app/`：Web/PWA 主应用
- `src-tauri/tauri.conf.json:1-100`：桌面封装与更新
- `.github/workflows/app.yml`：桌面发布矩阵
