# 第三方组件与素材声明

本仓库自己的代码（`shell/`、`.github/`）以根目录 [`LICENSE`](LICENSE)（MIT）授权。
而 `dshX.app` / DMG 里**打包了别人的东西**，它们各有各的许可，跟本仓库的 MIT 不是一回事。

## 1. `@deepseek-ai/dsh` 及其整棵依赖树

- 来源：npm 公共源 `registry.npmjs.org`，版本 `0.1.6-alpha.2`
- 锁定方式：`runtime/package-lock.json`（lockfileVersion 3，556 个包条目，
  其中 `@deepseek-ai/*` 271 个）
- 许可：MIT，Copyright (c) 2026 DeepSeek
- 许可原文：[`licenses/dsh-LICENSE.txt`](licenses/dsh-LICENSE.txt)
- 上游项目：<https://github.com/deepseek-ai/deepseek-harness>

`make-app.sh` 会把整个 `runtime/node_modules` 原样拷进
`dshX.app/Contents/Resources/runtime/node_modules`。因此这棵依赖树里的几百个包
（绝大多数同样是 MIT）也一并被打包；各自的许可原文保留在包内的 `LICENSE` 文件里，
没有被改动或删除。

## 2. Node.js v24.17.0（官方 darwin-arm64 二进制）

- 来源：<https://nodejs.org/dist/v24.17.0/>，下载时用同目录的 `SHASUMS256.txt`
  比对 SHA-256，不匹配就中止构建
- 许可：MIT（Node.js 本体）**外加一批随附的第三方许可**，涉及 V8、OpenSSL、
  npm 及其依赖等
- 许可原文：[`licenses/node-LICENSE.txt`](licenses/node-LICENSE.txt)
  （取自上述官方 tarball 内的 `LICENSE`，原文未删改）

`.app` 里只放了 `bin/node` 这一个可执行文件
（`Contents/Resources/node/bin/node`），没有装 npm、corepack 等其余部分。

## 3. 应用图标 —— 这一项**不是** MIT，注意区分

`iconsrc/official.icns` 不是本仓库的原创素材，也不在本仓库的 MIT 授权范围内：

- 来源：官方 DSH Desktop.app 的 `Contents/Resources/icon.icns`，
  即 DeepSeek 官方鲸鱼标（实测 11 个尺寸：16×16 → 512×512@2x）
- 本仓库只是原样转存，用途是让这个自建壳在 Dock 里有个像样的图标
- **不附带任何商标或品牌授权**；"DeepSeek Harness" 是 DeepSeek 的注册商标，
  官方品牌素材的使用约束见
  [BRAND_GUIDELINES.md](https://github.com/deepseek-ai/deepseek-harness/blob/main/BRAND_GUIDELINES.md)

结论：本仓库的**代码**你可以按 MIT 使用，但**图标**是 DeepSeek 的品牌素材，
本仓库无权转授。要对外分发或商用，请换成自己的图标：

```sh
ICNS=/path/to/your.icns ./shell/make-app.sh
```

## dshX 与 DeepSeek 的关系

dshX 是**第三方自建壳，不是 DeepSeek 官方产品**，与 DeepSeek 之间没有隶属、合作、
赞助或授权关系。项目名里的 "DSH" 沿用上游品牌指南建议的社区简称；
"DeepSeek Harness" 一词仅用于如实说明本项目的技术依赖关系。
