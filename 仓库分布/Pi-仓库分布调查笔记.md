# Pi 仓库分布调查笔记

> 调查对象：`https://github.com/earendil-works/pi`
>
> 调查更新日期：2026-09-16
>
> 代码快照：`b03a367a4fbc02df81bfd96702d7a12c2d79aa45`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计（`统计仓库.ps1`），并复核 npm workspace、包清单、构建与测试入口
>
> 调查范围：模块、语言、文档、测试和平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

当前快照：Git 跟踪文件 1721 个；可识别源码 1470 文件 / 339481 行；文档 144 文件 / 56438 行；测试源码 593 文件 / 127219 行。统计只使用当前 Git 跟踪文件；行数为物理行，未运行构建与测试。

## 结论摘要

Pi 是按可发布能力拆包的 TypeScript monorepo。coding-agent、统一模型 API、TUI 与 agent runtime 四个包构成主体；server/client/protocol/session backend 提供可组合边界。测试文件/源码文件比为 42.5%，主要包都有独立测试区。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 1721 |
| 可识别源码 | 1470 文件 / 339481 行 |
| 文档 | 144 文件 / 56438 行 |
| 测试源码 | 593 文件 / 127219 行 |

主要区域：

| 区域 | 文件 / 行数 |
| --- | ---: |
| `packages/coding-agent` | 762 / 146,310 源码行 |
| `packages/ai` | 347 / 65,579 源码行 |
| `packages/agent` | 230 / 53,979 源码行 |
| `packages/tui` | 113 / 37,930 源码行 |
| `packages/chord` | 39 / 9,375 源码行 |

TypeScript/TSX 共 321611 行，是绝对主语言。主要结构变化是 agent 包增长为 durable harness 的实现与测试中心，新增 Chord 服务/复制运行时，coding-agent 增加实验 server/client、mini、facet 插件与远端连接代码；sqlite-node 从搜索适配扩展为完整 format 4 repository/storage 后端。

## 跨平台组织与边界

平台形态是 Node/Bun 可运行的 CLI/TUI、库和服务协议，没有本仓原生桌面或移动 GUI。根 workspace 和顺序构建脚本明确依赖层（`package.json:5-18`）；coding-agent 的 sandbox/container 文档包含 Linux 隔离方案，但那是可选执行边界，不表示产品只支持 Linux。

## 关键源码索引

- `package.json:5-34`：workspace、构建与全仓测试
- `README.md:17-42`：包职责
- `packages/coding-agent/`、`packages/ai/`、`packages/agent/`、`packages/tui/`：主体包
