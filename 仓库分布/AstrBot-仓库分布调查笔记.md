# AstrBot 仓库分布调查笔记

> 调查对象：`../../AstrBot`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`346b85db9d79207ea7b51694cce5276203612af4`（分支：`master`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Python 打包、Dashboard 构建、部署说明与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行服务与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

AstrBot 是 Python 服务核心与 Vue 管理界面合仓的前后端项目。`astrbot/core`（106,932 行）与 `dashboard/src`（94,511 行）量级接近；Dashboard 构建产物在 Python 打包时嵌入发行包（`pyproject.toml:128-133`），形成一个部署单元，而不是两个独立产品仓库。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 1,612 |
| 可识别源码 | 947 文件 / 300,700 行 |
| 文档 | 441 文件 / 31,728 行 |
| 测试 | 178 文件 / 59,667 源码行 |

主要区域为 `astrbot/core`（383 文件/106,932 行）、`dashboard/src`（394/94,511）、根测试区（合计约 58,661 行）以及随包分发的 `astrbot/dashboard`（68/28,144）。后者使仓库同时保留 Dashboard 源码和面向 Python 包的静态集成层。

## 语言、文档与测试

Python 201,098 行（66.9%）、Vue 71,077 行（23.6%）、TypeScript 17,480 行（5.8%）。文档由 `docs/zh`（106 文件）、`docs/en`（101）和 `changelogs`（200）构成，文档数量较多但约一半是版本记录。测试集中在 `tests`：顶层用例 83 文件、`tests/unit` 55、`tests/agent` 3，Dashboard 仅扫描到 5 个测试文件。

## 跨平台组织与边界

项目形态是跨操作系统 Python 服务加浏览器 Dashboard，不含本仓原生桌面或移动客户端。README 给出 macOS、Linux/Arch 和 Docker 路径（`README.md:80-128`），Python 依赖也包含 Windows 条件处理；平台差异主要落在安装与服务运行层，前端共享同一 Web 构建。本次未在各系统启动验证。

## 关键源码索引

- `pyproject.toml:122-133`：Python 包范围与 Dashboard 构建嵌入
- `dashboard/package.json:1-20`：Vue Dashboard 入口
- `astrbot/core/`、`tests/`：服务核心与主要测试树
