# SillyTavern 仓库分布调查笔记

> 调查对象：`https://github.com/SillyTavern/SillyTavern`
>
> 调查更新日期：2026-08-27
>
> 代码快照：`8172dcd0ee672d3cd9a5e5f7af134f91a45cd2b8`（分支：`release`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Node 服务、浏览器前端、Electron 启动器与测试入口
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行服务与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

最新快照（2026-08-27）：Git 跟踪文件 988 个；可识别源码 527 文件 / 223385 行；文档 19 文件 / 1009 行；测试 23 文件 / 9996 源码行。提交频率：历史跨度 1084 天共 11719 次，折算 324.33 次/30天，近90天 1 次（非浅克隆）。

## 结论摘要

SillyTavern 是 Node 服务与传统浏览器前端合仓的单应用项目。`public/scripts` 141,344 行，是绝对主体；后端 `src/endpoints` 22,786 行。目录结构以按功能拆分的大量浏览器脚本为主，不是 package 化 monorepo。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 988 |
| 可识别源码 | 527 文件 / 223385 行 |
| 文档 | 19 文件 / 1009 行 |
| 测试 | 23 文件 / 9996 源码行 |

JavaScript 192,388 行（86.1%）、CSS 15,733 行（7.0%）、HTML 13,345 行（6.0%）。仓内 Markdown/TXT 文档较少，主要说明依赖外部文档站或代码内约定。测试独立放在 `tests`，其中 frontend 9 文件/7,283 行；测试包同时声明 Jest 单元和 Playwright E2E（`tests/package.json:6-13`）。

## 跨平台组织与边界

主形态是跨操作系统 Node 服务加浏览器 UI，也提供 Docker 和 `src/electron` 启动器；后者只是 Electron server 包，不形成另一套业务前端。根脚本还提供 Deno/Bun 启动入口（`package.json:120-127`）。平台共享依赖 Web 技术栈，未见移动原生代码。

## 关键源码索引

- `public/scripts/`：浏览器业务主体
- `src/endpoints/`、`server.js`：后端入口
- `tests/package.json:1-13`、`src/electron/package.json:1-14`：测试与桌面启动器
