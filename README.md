# 即刻译 (JiKeYi Trans)

即刻译是一个常驻菜单栏的 macOS 翻译工具，面向“选中文本后立即翻译”的高频场景，支持多服务并发、OCR 截图翻译、流式结果展示与一键替换原文。

## 核心能力

- 菜单栏常驻
  - 常驻状态栏，随时触发翻译、OCR 翻译和偏好设置。

- 选中文本即时翻译
  - 通过辅助功能读取当前选区文本。
  - 若读取失败，自动触发 `Cmd+C` 复制兜底获取文本。

- OCR 截图翻译
  - 全屏框选区域后进行 OCR 识别并翻译。
  - 内置取消、空结果、权限缺失等错误提示。

- 多服务并发翻译
  - 同一段原文可同时发送到多个服务并行返回。
  - 可指定“当前服务”，也可在结果区对比多服务输出。

- 流式输出与思考展示
  - 支持流式增量显示译文。
  - 支持按服务展示思考过程（前提是上游接口返回思考内容）。

- 翻译增强内容
  - 每个服务可独立开启“深入讲解”。
  - 每个服务可独立开启“英语学习讲解”（含词汇表、改写建议、学习要点）。

- 一键替换原文
  - 在“选中文本翻译”场景下，可将译文直接回填到原应用选区。
  - 支持点击按钮替换，也支持 `Alt+1..9` 快捷替换对应服务结果。

- 自动化文本预处理
  - 可选将换行替换为空格。
  - 可选去除注释标记（适合代码片段）。
  - 可选修复断词连字符（`hyphen + space`）。

- 便捷操作
  - 自动复制首个译文。
  - 点击译文中的英文单词自动复制。
  - 自动朗读原文。

- 术语表与路由
  - 支持术语表，翻译时注入提示。
  - 支持服务启用/禁用、气泡模式可见服务控制。

- 两种展示模式
  - `panel`：固定面板展示完整结果。
  - `bubble`：贴近选区显示，适合轻量快速查看。

## 界面与设置

偏好设置分为主要三个区域：

- 服务管理
  - 服务增删改、启用状态、当前服务切换。
  - Base URL / API Key / Model / 目标语言。
  - 术语表编辑。

- 模型设置（按服务独立）
  - 超时毫秒、温度、最大 tokens、思考预算。
  - 思考模式开关。
  - 讲解与英语学习提示词。
  - 额外请求参数 JSON（对象格式）。

- 快捷键与界面
  - 翻译、OCR、打开设置快捷键录制。
  - 面板/气泡模式切换、字号设置。
  - 自动化处理开关。

## 默认快捷键

- 翻译选中文本：`CommandOrControl+Shift+T`
- OCR 截图翻译：`CommandOrControl+Shift+S`
- 打开偏好设置：`CommandOrControl+Shift+O`

> 快捷键可在偏好设置内直接录制并保存，保存后立即生效。

## 运行环境

- macOS
- Xcode / Command Line Tools（含 Swift）

## 本地运行

```bash
cd /Volumes/PSSD/工具/trans
swift build
swift run jikeyi-trans
```

## 打包

```bash
cd /Volumes/PSSD/工具/trans
./scripts/package-macos-app.sh
```

默认产物：

- `dist/即刻译.app`

## 发布（签名、公证、DMG）

```bash
cd /Volumes/PSSD/工具/trans
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
KEYCHAIN_PROFILE="AC_NOTARY" \
./scripts/release-macos.sh
```

默认产物：

- `dist/即刻译.app`
- `dist/即刻译-notary.zip`
- `dist/即刻译.dmg`

可选参数：

- `--skip-notary`
- `--skip-dmg`
- `--skip-dmg-notary`
- `--skip-app-staple`
- `--skip-dmg-staple`

查看全部参数：

```bash
./scripts/release-macos.sh --help
```

## 权限要求

首次使用需要在系统设置授予以下权限：

- 辅助功能
  - 用于读取选中文本、复制兜底与回填替换。

- 屏幕录制
  - 仅 OCR 截图翻译需要。

路径：系统设置 -> 隐私与安全性 -> 辅助功能 / 屏幕录制

## 配置文件

- 设置文件：`~/.jikeyi-trans/settings.json`
- 状态文件：`~/.jikeyi-trans.json`

配置中包含服务列表、当前服务、快捷键、自动化开关、术语表等信息。

## 安全建议

- 不要把真实 API Key 写死在源码里。
- 建议仅在本机配置文件中保存 API Key。
- 发布前确认 `.gitignore` 已排除 `.env`、密钥文件和本地运行数据。

## 效果展示

![](https://echo-machile.oss-cn-beijing.aliyuncs.com/typora/20260223094137_9561.png)

![](https://echo-machile.oss-cn-beijing.aliyuncs.com/typora/20260223094244_8731.png)
