# AstrBot 仓库分布调查笔记

> 调查对象：`https://github.com/AstrBotDevs/AstrBot`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`f926af99ec5f8bd85b64413f8bfad55da76ef73b`（分支：`master`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Python 打包、Dashboard 构建、部署说明与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行服务与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-11-04）：Git 跟踪文件 1926 个；可识别源码 1149 文件 / 385408 行；文档 465 文件 / 36052 行；测试 287 文件 / 101839 源码行。主线提交节奏：浅克隆可见 109 天共 496 次，折算 136.5 次/30 天，近 90 天 396 次；更早历史不在统计范围。

## 结论摘要

AstrBot 是 Python 服务核心与 Vue 管理界面合仓的前后端项目，版本号 4.29.4。`astrbot/core`（127,677 行）与 `dashboard/src`（111,161 行）量级接近；Dashboard 构建产物在 Python 打包时嵌入发行包，两者构成一个部署单元。仓库另含一套容器内运维用的 CLI（`astrbot/cli`，12 文件/1259 行）。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 1926 |
| 可识别源码 | 1149 文件 / 385408 行 |
| 文档 | 465 文件 / 36052 行 |
| 测试 | 287 文件 / 101839 源码行 |

主要区域为 `astrbot/core`（426 文件/127,677 行）、`dashboard/src`（477/111,161）、测试树（270 文件/99,213）以及随包分发的 `astrbot/dashboard`（72/30,980）。后者使仓库同时保留 Dashboard 源码和面向 Python 包的静态集成层。

## 语言、文档与测试

Python 265,858 行（69.0%）、Vue 85,577 行（22.2%）、TypeScript 19,419 行（5.0%），其后是 JavaScript 8,314 行、CSS/SCSS 3,323 行与少量 Shell、HTML、PowerShell。

文档由 `docs/zh`（131 文件）、`docs/en`（124）和 `changelogs`（212）构成，文档数量较多但约一半是版本记录。

测试集中在 `tests`：顶层区域 133 个文件、`tests/unit` 103、`tests/test_kook` 21、`tests/fixtures` 10、`tests/agent` 3；Dashboard 扫描到 16 个测试文件。专项测试随近期机制扩展同步增加，覆盖各平台适配器的按钮与富文本、Windows 进程沙箱、Agent Runner 与技能、WebChat 消息分段等。

## 跨平台组织与边界

项目形态是跨操作系统 Python 服务加浏览器 Dashboard。Dashboard 内含桌面壳桥接（窗口内 `window.astrbotDesktop`、`window.astrbotAppUpdater`）与 macOS 原生窗口 chrome 适配（隐藏标题栏、vibrancy 侧栏），桌面客户端本体不在本仓。README 给出 macOS、Linux/Arch 和 Docker 路径（`README.md:80-128`）；Python 依赖包含 Windows 条件项（`pywin32`）与 Windows AppContainer 沙箱支持，平台差异落在安装、服务运行与本地执行权限层，前端共享同一 Web 构建。CLI 既用于本机也在容器镜像中提供，用于安装、配置与密码重置。本次未在各系统启动验证。

## 关键源码索引

- `pyproject.toml:89-137`：Python 依赖、CLI 入口与 Dashboard 构建嵌入钩子（`scripts/hatch_build.py`）
- `dashboard/package.json:6-16`：Vue Dashboard 构建、图标字体子集与 i18n 键校验入口
- `astrbot/cli/`：容器内与本地运维 CLI
- `astrbot/core/`、`tests/`：服务核心与主要测试树
