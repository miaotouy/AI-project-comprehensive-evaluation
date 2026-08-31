# Risuai 媒体创作调查笔记

> 调查对象：`https://github.com/kwaroran/Risuai`
>
> 调查更新日期：2026-08-31
>
> 代码快照：`e565563a288ebe4c65b6099a1645ba477d1c84b4`（分支：`main`）
>
> 调查方式：静态源码走读；复核既有生成式输出与运行时笔记（同一代码快照），精读图像生成器、inlay 存储与浏览器、聊天收口和 Playground 图像入口；未启动应用、未连接图像提供商、未运行测试
>
> 调查范围：图像生成进入 inlay 资产的入口、参数、执行、消息回填、资产管理和提示回流；普通 TTS、角色立绘、插件/脚本执行与通用聊天生成仅在交接必要处说明
>
> 文档定位：实现学习与跨项目横向比较，不作为整改方案

## 结论摘要

Risuai 的媒体创作主链为 **M1 模型生成工作站（聊天嵌入式）+ M3 资产工作区**。模型文本中的 `<ImgGen>` 标记、用户的 Playground 图像表单，或用户/角色预设的脚本和触发器，都可调用同一个图像生成器；聊天主链会把成功图像转存为 UUID 标识的 inlay 资产，再将消息替换为 `{{inlay::id}}` 引用。资产二进制保存在独立 IndexedDB/localforage 实例，Playground Inlay Explorer 可列出、预览和批量删除；之后提示装配又能把引用解析为图像、多模态附件或图像描述回送模型。

工作台的独特之处在于结果有独立于消息的 inlay 身份，但它不是完整的媒体工程：资产没有创建来源、提示词、模型、版本、父子关系或反向引用索引。图像生成设置是全局/角色配置，历史参数不随 inlay 保存；Playground 的手动生成当前只显示返回 data URI，静态路径未见其自动写入 inlay。因此可继续复用的正式主链应以聊天收口后的 inlay 写入为准，而不能把所有图像入口都等同为资产工作站。

该项目满足媒体类目准入的专用入口、独立资产、参数化模型调用、资产管理及聊天回流条件；没有确认任务队列、远端进度/取消、媒体版本、编辑器或跨设备资产迁移。所有结论来自静态源码，真实模型调用、浏览器 IndexedDB 和 UI 行为均未运行验证。

## 系统边界与完整主链

| 层 | 承担者 | 静态证据 |
|---|---|---|
| 创作入口 | 聊天输出 inlay screen；Playground 表单；脚本/触发器 | `src/ts/process/inlayScreen.ts`、`src/lib/Playground/PlaygroundImageGen.svelte` |
| 事实对象 | UUID -> `InlayAsset` 的 localforage 记录；聊天正文引用 | `src/ts/process/files/inlays.ts:8-33,83-125` |
| 模型执行 | 浏览器请求 WebUI、NovelAI 等配置的图像端点 | `src/ts/process/stableDiff.ts:64-948` |
| 聊天收口 | `runInlayScreen` 替换标记并异步回填消息 | `src/ts/process/index.svelte.ts:1775-1816` |
| 预览/管理 | Markdown inlay 投影与 Playground Explorer | `src/ts/parser/parser.svelte.ts:666-701`、`PlaygroundInlayExplorer.svelte` |
| 再次使用 | 提示构建把 inlay 转为多模态附件或描述 | `src/ts/process/index.svelte.ts:900-974` |

```text
模型输出 <ImgGen="prompt"> 或用户使用图像生成入口
  -> generateAIImage(prompt, character, negative, 'inlay')
  -> 浏览器按已配置 provider 调用图像 API，得到 data URI
  -> 聊天路径：runInlayScreen 加载图像 -> writeInlayImage
  -> canvas 在超过 1024*1024 像素时缩放，PNG Blob 以 UUID 写入 localforage/inlay
  -> 消息文本回填 {{inlay::UUID}}，主数据库另保存该文本
  -> ParseMarkdown 读取 UUID 并投影为媒体元素；Explorer 可列举/预览/删除
  -> 下一轮提示装配将引用转为图片、音视频或 signature 附件（或图像描述）
```

## 1. 创作入口、触发者与事实对象

聊天输出是主入口：最终化阶段调用 `runInlayScreen`，其识别 `<ImgGen>` 与 `{{ImgGen}}` 标记，先写入生成中占位，再异步生成、存入 inlay 并替换成 UUID 引用。模型只能通过文本标记间接提出生成意图；宿主负责实际调用与落库。`src/ts/process/inlayScreen.ts:7-49`、`src/ts/process/index.svelte.ts:1775-1816`。

用户还有 Playground 图像生成表单，可填写正负提示词并调用同一生成器。该组件把返回 data URI 放入局部 `img` 状态用于预览；本次未见其调用 `writeInlayImage`，所以不把它视作持久化资产链。脚本和触发器也能主动生成后写入 inlay，但其授权和调度属于 Agent 工具/角色脚本交接面。`PlaygroundImageGen.svelte:1-44`、`src/ts/process/scriptings.ts:392-404`。

`InlayAsset` 是唯一的媒体资产对象，类型覆盖 image、video、audio、signature，键为 UUID。图片写入时记录 PNG Blob、名称、宽高和类型；音视频上传也可直接建 inlay 记录。消息只保存文本占位，二者没有反向关系字段。`src/ts/process/files/inlays.ts:8-16,30-80,83-125`。

## 2. 参数、素材与模型执行

图像生成器从当前数据库读取 provider 和配置。WebUI 路径提交宽高、随机 seed、steps、CFG、正负提示词、采样器、高分修复等字段；NovelAI 路径同时支持模型、分辨率、采样器、reference/vibe/character 图像等参数。它们是已有设置面提供的参数，本页不将 provider 管理细节展开。`src/ts/process/stableDiff.ts:64-122,134-253`。

`stableDiff` 还能先调用子模型把聊天文本整理为视觉提示词，再交给 `generateAIImage`。对于 inlay 模式，生成器返回 data URI 而不直接落库；只有后续 inlay screen、脚本或触发器调用写入函数时，结果才取得资产身份。这个分离避免生成器耦合存储，却使单独调用者必须明确决定是否保存。`src/ts/process/stableDiff.ts:12-62,93-115`。

inlay 图片写入通过 canvas 解码并统一输出 PNG；超过 1024 x 1024 总像素时等比缩小。该限额只约束写入 inlay 的图片，不代表外部生成器的请求分辨率上限。`src/ts/process/files/inlays.ts:83-125`。

## 3. 任务状态、失败、取消与恢复

聊天 inlay screen 用 `[Generating...]` 文本占位表达等待，异步 Promise 完成后回填资产引用；图像生成失败由生成器调用错误提示并返回空值/false。没有独立任务表、任务 UUID、进度、轮询、webhook、重试队列或结果状态机。`src/ts/process/inlayScreen.ts:7-49`、`src/ts/process/stableDiff.ts:64-122`。

本次未找到图像任务的用户取消入口或重启续跑实现。聊天主数据库会保存消息文本，但 inlay 二进制在独立存储；因此重开后引用能否正常解析取决于同一浏览器 profile 中的资产仍在，而不是由主聊天快照恢复。此存储分离及跨设备缺口已有静态证据，实际重装/同步结果未运行验证。

## 4. 结果、历史、资产与工程持久化

inlay 使用独立的 localforage 实例，库和 store 名均为 `inlay`。读取可返回 base64 data URI 或 Blob，列举和删除都以 UUID 操作。图片、音频和视频上传可进入这套资产库，但本次主链的模型产出是图片。`src/ts/process/files/inlays.ts:30-80,172-223`。

聊天文本及其 `{{inlay::id}}` 引用随 `database.bin` 保存，但资产 Blob 不随主库、drive 同步或冷存储迁移。这提供了同设备的消息到资产持久关系，却不是可携带的媒体项目档案。既有笔记的持久化调查见 `../生成式输出与运行时/Risuai-生成式输出与运行时调查笔记.md`。

没有内容哈希、去重、来源索引、提示词/参数记录或自动孤儿清理。同一图像被多消息引用在文本层面可行，删除 Explorer 中的资产却不会检查引用；该后果由“无反向索引”和直接 `removeItem` 的静态路径推得，未运行验证断链时的 UI 表现。

## 5. 预览、编辑、重试、分支与复用

Markdown 解析器将 inlay 占位投影为图片、视频或音频元素，Playground Explorer 以分页列表列举资产，按需创建 Blob URL 预览，并支持单项或多项删除。Explorer 是本项目唯一已确认的资产管理表面；预览 URL 会在删除和组件销毁时撤销。`src/lib/Playground/PlaygroundInlayExplorer.svelte:11-144`。

复用主要发生在下一轮聊天：提示构建读取消息中的 inlay UUID，将图片等媒体转为模型可接受的附件，或在图像输入不支持时生成描述文本。模型本身没有资产列表或 UUID 定向操作接口。`src/ts/process/index.svelte.ts:900-974`。

本次未找到 inlay 的编辑、重试、版本、分支、下载/导出或由 Explorer 再次发起图像生成的动作。重新生成只能回到聊天标记、Playground 或脚本入口；生成参数也不保存在资产对象中。

## 6. Agent 回流、外部依赖与权限

结果回流先进入聊天文本，再在后续上下文中由宿主解析为多模态内容，因此是“宿主代取资产”的回流而不是模型持有对象句柄。插件 API 可以读取 inlay，脚本/触发器也可以生成并写入 inlay；模型不能查询或更新指定资产。详见既有笔记的对象感知边界。

外部执行依赖用户配置的 WebUI、NovelAI 等图像服务及浏览器网络能力；图片转码/缩放在浏览器 canvas 内完成，二进制存储依赖 IndexedDB/localforage。没有项目内 ComfyUI 编排器、FFmpeg、媒体文件服务器或后台任务服务。`src/ts/process/stableDiff.ts`、`src/ts/process/files/inlays.ts`。

## 7. 设计取舍、已确认边界与未验证事项

设计以消息内 UUID 引用连接聊天与独立 Blob 资产，允许同一资产在消息中重复使用并在提示侧转为多模态输入；代价是资产元数据极少，主数据库与资产库的迁移原子性也不成立。图像生成与写入分层，使脚本、触发器和聊天都能复用生成器，但独立调用者可选择不持久化。

已确认边界：本次在图像生成、inlay 存储、Explorer 和聊天收口范围内未找到媒体任务状态机、取消/进度/回调、资产版本/DAG、内容去重、资产来源索引、媒体编辑器、可导出的工程对象或模型直接的资产寻址。TTS 是即时播放，非 inlay SD 图则写角色立绘状态，均不纳入此主链。

未验证事项：未运行任何 WebUI/NovelAI 请求、图片缩放、localforage CRUD、消息回填或多模态回注；未测试删除被引用资产后的渲染；未确认跨设备同步/备份时资产丢失的实际提示；仓库内 inlays 单测存在但未执行。

## 8. 关键源码索引

- `src/ts/process/inlayScreen.ts:7-49`：模型标记到异步生成、写入和文本回填。
- `src/ts/process/index.svelte.ts:900-974,1775-1816`：提示侧资产回注及聊天最终化。
- `src/ts/process/stableDiff.ts:12-122,134-253`：视觉提示生成、provider 请求与参数。
- `src/ts/process/files/inlays.ts:8-125,172-223`：资产类型、独立存储、缩放、读写删除。
- `src/lib/Playground/PlaygroundImageGen.svelte:1-44`：手动图像生成入口。
- `src/lib/Playground/PlaygroundInlayExplorer.svelte:11-144`：资产列表、预览、批量删除。
- `src/ts/process/files/tests/inlays.test.ts`：inlay CRUD/缩放测试（未运行）。
- `../生成式输出与运行时/Risuai-生成式输出与运行时调查笔记.md`：消息渲染、持久化和脚本系统的交接结论。
