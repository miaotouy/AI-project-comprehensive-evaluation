# Chatbox 仓库分布调查笔记

> 调查对象：`https://github.com/chatboxai/chatbox`
>
> 调查更新日期：2026-11-04
>
> 代码快照：`d17455c5ca8fd3ff44385c6d4d2118599e4c970f`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 pnpm、Electron、Web、Capacitor 构建入口与主要目录
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

当前快照包含 2,595 个 Git 跟踪文件、2,288 个 TypeScript/JavaScript 源码文件；`docs/` 下 42 个文档文件，按测试文件名与测试目录识别出 754 个测试文件。源码行数本次未重新统计，只按文件数量级观察。

## 结论摘要

Chatbox 已从根包共享 `src` 的单体形态演进为 pnpm workspace：根应用仍承载 Electron、Web 与 Capacitor 产品入口，`packages/chatbox-core` 抽取宿主无关的会话、上下文、生成和设置领域逻辑，`packages/chatbox-react` 承接 React 查询与 store 绑定。`src/renderer` 仍是最大实现区（1,159 个 TS/JS 文件），`src/shared` 379 个、`src/main` 191 个；`packages/chatbox-core` 已有 412 个 TS/JS 文件，`packages/chatbox-react` 47 个、`packages/chatbox-i18n` 5 个。原先集中在 renderer store 的责任已形成可移植边界。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 2,595 |
| TypeScript/JavaScript 源码 | 2,288 文件（ts 1,824、tsx 419、mjs 23、js 11、cjs 11） |
| 文档（`docs/`） | 42 文件 |
| 测试文件 | 754 |

| 区域 | 文件数 |
| --- | ---: |
| `src/renderer` | 1,159 个 TS/JS 文件 |
| `src/shared` | 379 个 TS/JS 文件 |
| `src/main` | 191 个 TS/JS 文件 |
| `packages/chatbox-core` / `chatbox-react` / `chatbox-i18n` | 412 / 47 / 5 个 TS/JS 文件 |
| `docs/` | 42 个文档文件 |

大量单元测试与实现就地放在三个 `src` 区域。

## 语言、文档与测试

源码仍以 TypeScript 为绝对主体。文档继续集中在 `docs`，其中 technical 与 product 文档分别记录实现契约和产品行为；测试除了三个 `src` 运行层和 `test/integration`，还进入两个 workspace 包，覆盖抽取后的会话服务、action gates、模式策略、上下文压缩与 React 绑定。

## 跨平台组织与边界

Electron 构建覆盖 Windows、macOS、Linux，另有独立 Web 构建和通过 Capacitor 同步的 iOS/Android 构建（`package.json:18-29,60-64`）。多端共享 renderer/shared，桌面专属能力留在 main/preload，移动差异由构建变量和平台适配层处理。本次只静态确认构建入口。

## 关键源码索引

- `package.json`：Electron、Web 和移动构建矩阵
- `pnpm-workspace.yaml:1-3`：workspace 范围
- `packages/chatbox-core/src/`：宿主无关的会话、上下文、生成与设置领域层
- `packages/chatbox-react/src/`：React Query 与 store 绑定
- `src/main/`、`src/preload/`、`src/renderer/`、`src/shared/`：运行层边界
