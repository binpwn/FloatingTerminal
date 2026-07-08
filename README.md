# FloatingTerminal

一个 macOS 上的悬浮式终端。把鼠标移动到屏幕右上角即可呼出一个半透明、圆角的终端浮窗；鼠标移开后浮窗自动消失。支持在全屏应用之上显示。

## 功能

- **悬停呼出**：鼠标移到屏幕最右上角时间位置触发区，自动弹出终端浮窗。
- **自动隐藏**：鼠标离开浮窗（含一定的容差/交接延迟）后自动收起，不抢占桌面空间。
- **全屏可用**：浮窗层级与 Space 策略使其能在全屏应用、多桌面之间显示。
- **菜单栏常驻**：通过菜单栏图标可手动呼出浮窗或退出应用。
- **完整终端体验**：
  - 命令执行与实时输出（stdout/stderr 合并显示）
  - 命令历史（↑/↓ 翻阅）
  - `cd` 目录切换与路径提示符
  - `clear` / `cls` 清屏
  - Tab 自动补全（命令名 + 文件路径，多候选项时列出并补全公共前缀）
  - `Ctrl+C` 中断当前命令
  - `Esc` 关闭浮窗
- **复制粘贴**：
  - `Cmd+C` 复制选中文本（可在历史输出区选中后复制）
  - `Cmd+V` 粘贴（仅限当前可编辑输入区）
  - `Cmd+X` 剪切（仅限输入区）
  - `Cmd+A` 全选当前输入区

## 目录结构

```
DIY/
├── Package.swift                      # Swift Package Manager 包定义
├── README.md                          # 本说明文件
├── Sources/
│   └── FloatingTerminal/
│       └── main.swift                 # 全部源码（AppKit 单文件实现）
└── FloatingTerminal.app/              # 可直接运行的应用包
    └── Contents/
        ├── Info.plist                 # 应用元数据
        ├── MacOS/
        │   └── FloatingTerminal       # 编译产物（可执行文件）
        └── Resources/                 # 资源目录（预留）
```

### 各文件说明

- **`Package.swift`**：Swift 6.1 包定义，目标平台 macOS 13+，构建一个可执行目标 `FloatingTerminal`。
- **`Sources/FloatingTerminal/main.swift`**：核心实现，包含：
  - `HoverPanel`：自定义 `NSPanel`，负责浮窗层级、全屏/多 Space 显示，以及拦截 `Cmd+C/V/X/A` 等快捷键并转发给文本视图（带输入区位置校验）。
  - `CommandExecutor`：用 `Process` 执行 `/bin/zsh -lc <命令>`，通过管道读取 stdout/stderr 并在主线程回调输出；读完 EOF 再回调完成，避免输出丢失。
  - `TerminalViewController`：终端 UI 与交互逻辑，基于 `NSTextView`（非富文本）实现提示符、命令执行、历史、Tab 补全、复制粘贴区域控制等。
  - `FloatingTerminalController`：浮窗显示/隐藏调度，用定时轮询鼠标位置判断是否处于右上角触发区或浮窗内，控制浮窗的显示、隐藏与交接时机。
  - `AppDelegate`：菜单栏状态项（图标 + 菜单）、应用启动。
- **`FloatingTerminal.app/`**：可直接双击运行的 macOS 应用包，`Contents/MacOS/FloatingTerminal` 为编译后的可执行文件。

## 构建与运行

依赖 macOS 13+ 与 Swift 工具链（随 Xcode 附带）。

```bash
# 编译 release 版本
swift build -c release

# 将编译产物拷贝进 app 包
cp .build/release/FloatingTerminal FloatingTerminal.app/Contents/MacOS/FloatingTerminal

# 启动
open FloatingTerminal.app
```

开发期间也可直接运行：

```bash
swift run
```

## 使用方法

1. 启动 `FloatingTerminal.app`，菜单栏出现终端图标。
2. 将鼠标移到屏幕**右上角**，浮窗自动弹出并获得输入焦点。
3. 在浮窗中输入命令回车执行；用 `↑/↓` 翻阅历史，`Tab` 补全。
4. 选中历史输出可 `Cmd+C` 复制；在输入行 `Cmd+V` 粘贴。
5. 鼠标移开浮窗即自动隐藏；也可按 `Esc` 关闭。
6. 点击菜单栏图标 → “Show Terminal” 可在鼠标当前位置手动呼出；→ “Quit” 退出。
