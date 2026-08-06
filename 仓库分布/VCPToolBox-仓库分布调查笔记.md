# VCPToolBox 仓库分布调查笔记

> 调查对象：`../../VCPToolBox`
>
> 调查更新日期：2026-08-06
>
> 代码快照：`c4c4d00b84202ec97f99c225b34014206aca8eea`（分支：`main`）
>
> 调查方式：Git 跟踪文件机械统计，并复核 Node 服务、Vue 管理台、插件、Rust workspace 与容器工作流
>
> 调查范围：模块、语言、文档、测试和跨平台代码组织；未运行构建、部署与测试
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

VCPToolBox 是 Node 编排服务、Vue 管理台、插件集合、知识/技能资料与多个 Rust/Python 辅助程序合仓的多运行时插件仓库。`AdminPanel-Vue` 和 `Plugin` 是两大主体；两者内部都包含被跟踪的 vendor/dist 或大批技能文档，统计时需要区分产品源码与随仓资产。

## 统计与模块分布

| 指标 | 数量 |
| --- | ---: |
| Git 跟踪文件 | 2,993 |
| 可识别源码 | 1,269 文件 / 456,062 行 |
| 文档 | 692 文件 / 161,572 行 |
| 测试 | 27 文件 / 6,007 源码行 |

主要区域为 `AdminPanel-Vue/src`（270 文件/98,552 行）、其 `vendor`（46/67,369）、`Plugin/SkillBridge`（616/37,409）、根服务源码（约 20,813 行）和 `Plugin/PaperReader`（81/19,992）。`AdminPanel-Vue/dist` 还有 320 个跟踪文件，进一步抬高文件数。

## 语言、文档与测试

JavaScript 235,918 行（51.7%）、Vue 68,638 行（15.1%）、Rust 39,307 行（8.6%）、CSS 29,013 行（6.4%），另有 Python 与 Shell 等运行时。文档集中在 SkillBridge（206 文件/76,199 行）、`docs`（52/32,752）和 `knowledge`（227 余文件）。测试只分布在 AdminPanel 18 文件、根 tests 8 和 scripts 1，未与插件数量成比例扩展。

## 跨平台组织与边界

产品主形态是服务端加浏览器管理台，不是原生多端客户端；Docker CI 明确构建 Linux amd64/arm64（`.github/workflows/ci.yml:19-120`）。插件和 Rust 辅助程序各自带构建边界，`OpenWebUISub`/`SillyTavernSub` 是第三方页面集成层。非容器环境的平台兼容性因插件而异，本次未逐插件运行。

## 关键源码索引

- `package.json:1-10`：Node 服务与 Admin 构建
- `AdminPanel-Vue/`：管理台源码、vendor 与 dist
- `Plugin/`、`routes/`、`modules/`、`rust-vexus-lite/`：插件和服务边界
