# KeyNest

**KeyNest** 是一款面向 macOS 的**本地**密码管理应用：主密码与恢复密钥保护下的加密保管库、SwiftUI 界面，以及通过本机 HTTP 桥与浏览器扩展（**Chrome / Edge / Firefox**，**Safari** 需经 Xcode 转换）配合在网页中填充账号密码。数据默认只保存在本机，不依赖云同步服务。

> English: A macOS native password manager with a local encrypted vault, optional recovery key, and browser extensions that talk to a **localhost-only** HTTP bridge (default port `17373`).

维护者：**heureuxl** · [lq_17395@163.com](mailto:lq_17395@163.com)

## 功能概览

- **本地加密保管库**，默认路径：`~/Library/Application Support/KeyNest/vault.keynest`（若检测到旧版 TwoPassword 的保管库，首次启动会尝试**复制**迁移到新路径）。使用 [swift-crypto](https://github.com/apple/swift-crypto) 等进行加解密与密钥派生。
- **主密码**解锁；支持用**恢复密钥**在忘记主密码时重置主密码并保留数据（保管库 v2 格式）；解锁后主界面工具栏可**更换恢复密钥**（成功后旧短语作废，行为与 Windows 版一致）。
- **本机桥接**：解锁且开启后，在 `127.0.0.1:17373` 提供只读/写入接口，供扩展使用；**不监听公网**。
- **浏览器扩展**：脚本与页面以 `browser/chrome-extension` 为**单一来源**，构建时同步到 `edge-extension`、`firefox-extension`、`safari-extension`。在登录页拉取匹配凭据并填充；多账号时可选账号；支持在**传统表单提交**时经用户确认后保存到保管库。
- **同一主机**（域名或 IP：只根据主机名识别站点，不含路径与端口）下最多保留 **3 个不同用户名**；相同主机 + 用户名则覆盖更新；子域与根域可按包含关系匹配（例如 `login.example.com` 与 `example.com`）。

## 系统要求

- macOS **14** 及以上  
- Swift **5.9**+（随 Xcode 命令行工具或 Xcode）

## 从源码构建与运行

```bash
git clone https://github.com/<用户名>/<仓库名>.git
cd <仓库名>

swift build
swift run KeyNest
```

发布构建：

```bash
swift build -c release
swift run -c release KeyNest
```

## 打包分发

### macOS 应用（`.app` / `.dmg`）

依赖 `App/AppIcon.icns`（可由 `App/app-icon-1024.png` 通过脚本生成）、`App/Info.plist` 等。

```bash
# 仅组装 .app
bash scripts/build-macos-app.sh

# 额外生成 DMG（卷名带版本号）
MAKE_DMG=1 bash scripts/build-macos-app.sh
```

产物默认输出到 **`dist/`**（该目录已在 `.gitignore` 中忽略）。

### 浏览器扩展（Chrome / Edge / Firefox / Safari）

统一打包（同步共享脚本后生成各浏览器 zip，并为 Chrome 生成 `.crx`）：

```bash
bash scripts/build-browser-extensions.sh
```

兼容旧命令（行为与上面相同）：

```bash
bash scripts/build-chrome-extension.sh
```

产物示例（均在 `dist/`）：

| 文件 | 用途 |
|------|------|
| `KeyNest-Chrome.zip` / `KeyNest-Chrome.crx` | Google Chrome |
| `KeyNest-Edge.zip` | Microsoft Edge（Chromium，亦可共用 Chrome 包） |
| `KeyNest-Firefox.zip` | Mozilla Firefox（MV3，`browser_specific_settings.gecko` 已配置） |
| `*_扩展安装说明.txt` | 各浏览器加载步骤 |

**Safari**：Web Extension 需由 Apple 提供的工具转为 Xcode 工程后再编译、在 Safari 中启用：

```bash
bash scripts/convert-safari-extension.sh
```

默认输出目录为 `browser/safari-extension-build/`（已在 `.gitignore` 中忽略）。详见 **`dist/Safari扩展安装说明.txt`**。

在打 DMG 时一并打包扩展：

```bash
MAKE_DMG=1 BUILD_CHROME_EXT=1 bash scripts/build-macos-app.sh
```

首次用 Chrome 的 `--pack-extension` 生成 `.crx` 时可能在本仓库 `browser/` 下生成 **`chrome-extension.pem`**（扩展签名私钥）。**请勿将 `.pem` 提交到 Git**（已在 `.gitignore` 中排除）；丢失后再次打包会得到新的扩展 ID。

## 仓库布局简表

| 路径 | 说明 |
|------|------|
| `Sources/KeyNest/` | Swift 源码（界面、保管库、加密、本机桥） |
| `App/` | 应用 `Info.plist`、图标资源、DMG 背景图等 |
| `browser/chrome-extension/` | 扩展清单与脚本（主拷贝） |
| `browser/edge-extension/`、`firefox-extension/`、`safari-extension/` | 各浏览器专用 `manifest.json`，`.js`/`.html` 由脚本从 `chrome-extension` 同步 |
| `scripts/` | `build-macos-app.sh`、`build-browser-extensions.sh`、`convert-safari-extension.sh`、`build-icns.sh` 等 |

## 安全与隐私

- 保管库文件与主密码仅存在于用户机器；请自行备份 `vault.keynest`（或旧版 `vault.twopw`）与**恢复密钥**。
- 桥接端口仅绑定本机回环地址；请在防火墙与使用习惯上避免向局域网暴露相关端口。
- 本仓库**不包含**任何云端账号或第三方分析；使用前请阅读源码并自行评估风险。

## 开源许可

本项目以 **MIT License** 发布，见 [`LICENSE`](LICENSE)。
