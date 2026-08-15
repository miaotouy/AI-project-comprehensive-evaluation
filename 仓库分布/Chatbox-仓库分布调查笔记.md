# Chatbox 仓库分布调查笔记

> 调查对象：`../../chatbox`
>
> 调查更新日期：2026-08-12
>
> 代码快照：`81571269addb6bafb589a920b2883f1e1e084fd1`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 pnpm、Electron、Web、Capacitor 构建入口与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Chatbox 是 TypeScript 高度统一的多端应用仓库，Electron 主进程、preload、renderer、Web 和 Capacitor 移动端共享 `src`。`src/renderer` 占 150,097 行，是主实现区；`src/shared` 和 `src/main` 分别承担跨端逻辑与桌面能力，边界比按产品平台复制整套代码更集中。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 1,414 |
| 可识别源码 | 1,168 文件 / 215,215 行 |
| 文档 | 58 文件 / 13,148 行 |
| 测试 | 282 文件 / 49,839 源码行 |

| 区域 | 文件 / 行数 |
| --- | ---: |
| `src/renderer` | 880 / 150,097 |
| `src/shared` | 210 / 34,046 |
| `src/main` | 113 / 22,533 |
| `test/integration` | 11 个源码文件 / 3,470 |

大量单元测试与实现就地放在三个 `src` 区域。

## 语言、文档与测试

TypeScript 208,676 行（96.9%），其余主要是 JavaScript 5,258 行（2.4%）。文档集中在 `docs`（33 文件，其中 `docs/technical` 17）并辅以 `tasks` 和测试用例说明。测试分布为 renderer 171 文件、shared 59、main 34、integration 11，三个运行层都有对应测试。

相对 `f90fc31a` 快照新增约 77 个跟踪文件、约 13,200 源码行，其中测试文件从 243 增至 282、测试源码行从 42,543 增至 49,839（新增 ForkGroup/MessageList/Message/Minimap/sandbox/MCP 等大量组件与主进程测试，见对应专项笔记）。

## 跨平台组织与边界

Electron 构建覆盖 Windows、macOS、Linux，另有独立 Web 构建和通过 Capacitor 同步的 iOS/Android 构建（`package.json:18-29,60-64`）。多端共享 renderer/shared，桌面专属能力留在 main/preload，移动差异由构建变量和平台适配层处理。本次只静态确认构建入口。

## 关键源码索引

- `package.json:14-64`：Electron、Web 和移动构建矩阵
- `pnpm-workspace.yaml:1-3`：workspace 范围
- `src/main/`、`src/preload/`、`src/renderer/`、`src/shared/`：运行层边界
