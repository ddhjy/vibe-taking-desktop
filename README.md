# 随心记 (VibeTaking)

macOS 菜单栏应用，通过 HTTP 接口接收文本并自动粘贴到当前活跃的输入框中。

## 使用场景

- 从其他设备/脚本远程向 Mac 发送文本并自动粘贴
- 配合自动化工具链，实现跨应用的文本输入
- 搭配 AI 对话工具，将生成内容直接粘贴到目标应用

## 构建

### 使用 Xcode

```bash
open VibeTaking/VibeTaking.xcodeproj
```

在 Xcode 中选择 **Product → Build**（⌘B），生成的应用位于 DerivedData 目录。

### 使用命令行

```bash
cd VibeTaking
xcodebuild -project VibeTaking.xcodeproj -scheme VibeTaking -configuration Release build
```

构建产物位于 `~/Library/Developer/Xcode/DerivedData/VibeTaking-*/Build/Products/Release/VibeTaking.app`。

可复制到 `/Applications` 目录使用：

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/VibeTaking-*/Build/Products/Release/VibeTaking.app /Applications/
```

### 使用 Make（推荐）

在项目根目录执行：

```bash
make release
```

产物位于：

- `dist/release/VibeTaking.app`
- `dist/release/VibeTaking-<version>.zip`

如需直接覆盖安装到 `/Applications` 并自动重启应用，执行：

```bash
make install
```

## 使用方法

启动后随心记会出现在菜单栏（不会显示 Dock 图标），默认监听 `0.0.0.0:7788`。

### 发送文本

**纯文本：**

```bash
curl -X POST http://localhost:7788 -d '要粘贴的文本'
```

**JSON 格式：**

```bash
curl -X POST http://localhost:7788 \
  -H 'Content-Type: application/json' \
  -d '{"text": "要粘贴的文本"}'
```

### API 说明

| 方法 | 路径 | Content-Type | Body | 说明 |
|------|------|-------------|------|------|
| POST | `/` | `text/plain`（默认） | 原始文本 | 将 body 内容粘贴 |
| POST | `/` | `application/json` | `{"text": "..."}` | 将 `text` 字段内容粘贴 |

**响应：**

| 状态码 | Body | 说明 |
|--------|------|------|
| 200 | `{"ok": true}` | 粘贴成功 |
| 400 | `{"error": "empty text"}` | 文本为空 |
| 400 | `{"error": "invalid json"}` | JSON 解析失败 |
| 500 | `{"error": "..."}` | 粘贴过程出错 |

## 菜单栏功能

| 菜单项 | 说明 |
|--------|------|
| **设置…** | 打开独立设置窗口，集中管理端口、自动发送、快捷键和权限 |
| **Port: 7788** | 点击可修改监听端口 |
| **Auto Send** | 开启后单次触发会发送 Enter；短时间内连续触发两次时，会取消这次 Enter，改为只发送一次 Cmd+Enter |
| **Auto Send Shortcut: None** | 配置 Auto Send 全局切换快捷键（默认无快捷键，点击后直接按组合键录制，按 Delete 清除） |
| **Quit** | 退出应用（快捷键 Cmd+Q） |

### 图标状态

- 📋 剪贴板图标 — 正常运行
- 📋 + ↑ 箭头 — Auto Send 已开启

## 权限要求

随心记需要以下 macOS 权限：

- **辅助功能（Accessibility）** — 用于模拟粘贴和发送按键事件

首次运行时系统会弹窗请求授权，请在 **系统设置 → 隐私与安全性 → 辅助功能** 中允许。

## 项目结构

```
VibeTaking/
├── VibeTaking.xcodeproj/
│   └── project.pbxproj
└── VibeTaking/
    ├── App/
    │   ├── main.swift            # 入口点
    │   └── AppDelegate.swift     # 主应用逻辑、菜单构建
    ├── UI/
    │   └── StatusBarIcon.swift   # 菜单栏图标绘制
    ├── Networking/
    │   └── HTTPServer.swift      # GCD TCP 服务器（纯 BSD socket）
    ├── Services/
    │   └── PasteService.swift    # 粘贴逻辑（纯 CGEvent）
    └── Resources/
        ├── AppIcon.icon/         # 新版 App Icon Composer 资源（AppIcon）
        ├── Info.plist
        └── VibeTaking.entitlements
```

## 技术细节

- 原生 Swift + Cocoa，无第三方依赖
- 使用 `CGEventPost` 模拟键盘事件（粘贴与发送）
- 使用 `NSPasteboard` 将文本写入系统剪贴板
- HTTP 服务基于 BSD socket + GCD，运行在后台队列
- 菜单栏图标使用 `NSBezierPath` 程序化绘制，支持自动适配深色/浅色模式

## 实现边界

- 核心逻辑（HTTP 接收、写剪贴板、模拟按键、状态栏控制）全部在 `VibeTaking/{App,UI,Networking,Services}/*.swift` 内
- 仓库不依赖 Python 运行时，不需要 `dist` 目录中的任何内容来运行 Xcode 构建出的应用
