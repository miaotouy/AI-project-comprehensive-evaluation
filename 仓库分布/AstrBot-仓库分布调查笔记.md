# AstrBot 仓库分布调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`e0aa8d386121ead06825fb6d1e423a41a3d14a83`（分支：`master`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Python 打包、Dashboard 构建、部署说明与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行服务与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-09-16）：Git 跟踪文件 1747 个；可识别源码 1030 文件 / 338181 行；文档 453 文件 / 32429 行；测试 226 文件 / 76966 源码行。主线提交节奏：浅克隆可见 60 天共 263 次，折算 131.5 次/30 天，近 90 天 263 次；更早历史不在统计范围。

## 结论摘要

AstrBot 是 Python 服务核心与 Vue 管理界面合仓的前后端项目。`astrbot/core`（116,430 行）与 `dashboard/src`（104,445 行）量级接近；Dashboard 构建产物在 Python 打包时嵌入发行包，两者构成一个部署单元。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 1747 |
| 可识别源码 | 1030 文件 / 338181 行 |
| 文档 | 453 文件 / 32429 行 |
| 测试 | 226 文件 / 76966 源码行 |

主要区域为 `astrbot/core`（396 文件/116,430 行）、`dashboard/src`（455/104,445）、测试树（213 文件/75,273 行）以及随包分发的 `astrbot/dashboard`（68/28,912）。后者使仓库同时保留 Dashboard 源码和面向 Python 包的静态集成层。

## 语言、文档与测试

Python 227,699 行（67.3%）、Vue 80,011 行（23.7%）、TypeScript 18,100 行（5.4%）。

文档由 `docs/zh`（109 文件）、`docs/en`（104）和 `changelogs`（205）构成，文档数量较多但约一半是版本记录。

测试集中在 `tests`：顶层区域 105 个文件、`tests/unit` 74、`tests/agent` 3；Dashboard 扫描到 12 个测试文件。Local 沙箱、图像输入、聊天分页、平台群元数据和 Agent Runner 配置均增加了专项测试。

## 跨平台组织与边界

项目形态是跨操作系统 Python 服务加浏览器 Dashboard，不含本仓原生桌面或移动客户端。README 给出 macOS、Linux/Arch 和 Docker 路径（`README.md:80-128`），Python 依赖也包含 Windows 条件处理；平台差异主要落在安装与服务运行层，前端共享同一 Web 构建。本次未在各系统启动验证。

## 关键源码索引

- `pyproject.toml:122-133`：Python 包范围与 Dashboard 构建嵌入
- `dashboard/package.json:1-20`：Vue Dashboard 入口
- `astrbot/core/`、`tests/`：服务核心与主要测试树
