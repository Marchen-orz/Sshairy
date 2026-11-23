# Sshairy 0.3.0

<!-- zh -->
## Android 与手机互联

- 新增 Android 预览版。可直接连 SSH，使用触控终端、命令草稿、双栏 SFTP、文本预览与编辑和 Airy。Android 还提供可选的后台保活和生物识别应用锁。
- 手机可通过扫码或局域网发现与电脑配对。互联通道端到端加密，可同步主机、片段和信任记录、传送剪贴板，以及在手机处理电脑上的 Airy 和 MCP 审批。同步已存服务器密码需要电脑确认。
- 可镜像电脑终端，也可通过电脑连接主机，使用留在电脑上的 SSH 凭据。电脑未连接的标签会显示「待连接」，点按后由电脑连接。长按电脑代理主机或会话可在电脑打开同一主机并镜像。
- 可双向传输已共享的手机与电脑文件，在电脑代理和镜像终端打开对应的文件与只读监控。相对路径补全随 SSH shell 的当前目录更新，`~/` 仍指向家目录。

## Airy 与 MCP

- 内置 Airy 与外部 MCP 客户端共用 42 项工具，涵盖 SSH 命令与后台任务、文件和传输、终端上下文、主机、会话、设置及转发。MCP 客户端首次接入需在 Sshairy 内确认，读取已有终端和访问本机文件仍需相应授权。
- 行内 AI 可在当前终端分步完成任务，显示每步命令和结果。默认由用户按回车执行，每次任务可开启自动执行。修复了长命令折行、多行粘贴和较慢回显时的输入跟踪。
- AI 补全改为光标后的灰字，可调触发延迟，块光标下也能看见开头字符。可选安装 bash/zsh shell 集成，启用下一条命令预测和失败命令修复。

## 桌面改进

- Windows 私钥路径接受资源管理器「复制文件地址」附加的双引号，已有配置也能正常读取。
- 文件面板改进外部编辑同步与传输进度。双击下载时才在对应文件行显示进度，完成的传输保留完成状态。
- 更新提示默认展示最新版本的日志。

## 下载

Windows x64 提供安装版和便携版，macOS 提供 Apple 芯片与 Intel 通用包，Linux x64 提供 AppImage 和 deb。Android 8.0 及以上可下载通用预览 APK，含 ARM64、ARMv7 和 x86_64。预览 APK 使用开发签名。

[查看自 v0.2.5 起的全部提交](https://github.com/Marchen-orz/sshairy/compare/v0.2.5...v0.3.0)
<!-- /zh -->

<!-- en -->
## Android and Device Link

- The Android preview adds direct SSH, a touch terminal, command drafts, dual-pane SFTP, text preview and editing, and Airy. Android also offers optional connection keep-alive and biometric app lock.
- Pair a phone and computer by QR code or LAN discovery. The end-to-end encrypted link can sync hosts, snippets, and host trust records, send clipboard text, and deliver desktop Airy and MCP approvals to the phone. Syncing saved server passwords requires confirmation on the computer.
- Mirror a desktop terminal or let the desktop connect using its own SSH credentials. Disconnected desktop tabs appear as pending and can be connected from the phone. Long-press a proxied host or session to open and mirror it on the computer.
- Transfer shared files in both directions and open matching files and read-only monitoring from proxied or mirrored terminals. Relative path completion follows the SSH shell's current directory. `~/` still refers to the home directory.

## Airy and MCP

- Airy and external MCP clients share 42 tools for SSH commands and background jobs, files and transfers, terminal context, hosts, sessions, settings, and forwarding. Approve each MCP client's first connection in Sshairy. Existing terminal and local file access require their own grants.
- Inline AI can work through a task step by step in the current terminal, showing the commands and results. Press Enter to run each step, or enable automatic execution for that task. Input tracking handles wrapped commands, multiline pastes, and slow echo.
- AI completion appears as ghost text after the cursor, with an adjustable delay and a visible first character under a block cursor. Optional bash and zsh integration enables next-command prediction and assistance with failed commands.

## Desktop improvements

- Windows accepts private key paths pasted from Explorer's Copy as path, including quoted paths already saved in a host configuration.
- The files panel improves external edit sync and transfer progress. A file row shows download progress while its double-click download runs, and completed transfers retain their finished state.
- The update prompt shows the latest release notes by default.

## Downloads

Windows x64 has an installer and a portable EXE. The macOS universal builds run on Apple silicon and Intel, and Linux x64 has an AppImage and a deb. Android 8.0 and later can use the universal preview APK, with ARM64, ARMv7, and x86_64 included. The preview APK uses a development signature.

[View all commits since v0.2.5](https://github.com/Marchen-orz/sshairy/compare/v0.2.5...v0.3.0)
<!-- /en -->
