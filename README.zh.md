<div align="center">

<img src="media/zh/cover.png" alt="Sshairy。轻量 SSH，AI 加持。0.62 秒启动，131 MiB 空闲内存，27 MiB 下载体积，单进程运行" width="100%">

[功能](#功能) · [Airy](#airy) · [主题](#主题) · [性能](#性能) · [获取](#获取) · [English](README.md)

![预览版](https://img.shields.io/badge/preview-0.1.0-2E6EF7?style=flat-square&labelColor=1F3A5F)
![桌面平台](https://img.shields.io/badge/desktop-Windows%20%7C%20macOS%20%7C%20Linux-2E6EF7?style=flat-square&labelColor=1F3A5F)
[![Flutter](https://img.shields.io/badge/Flutter-native-5AB6FF?style=flat-square&labelColor=1F3A5F)](https://flutter.dev)
![AI](https://img.shields.io/badge/AI-Airy-3CC9A7?style=flat-square&labelColor=1F3A5F)

</div>

**Sshairy** 是一款面向 **Windows、macOS、Linux** 的轻量 SSH 客户端。终端、SFTP、端口转发和服务器监控收进同一个现代原生窗口，界面清爽，分屏、标签与面板切换顺手，基于 Dart 与 Flutter 构建

AI 直接融进日常 SSH 工作流：把任务交给 Airy，或把一句话变成命令，读上下文、查服务器、执行操作都由它接着做。轻量、现代、流畅易用，同时不依赖 Chromium，不套 WebView，也不用额外带一套浏览器运行时

<img src="media/zh/preview.gif" alt="Sshairy 演示：快速启动、一个窗口管理所有服务器、懂上下文的补全、Airy 执行与审批、主题和实测性能" width="100%">

<img src="media/zh/workspace.png" alt="Sshairy 窗口：两台服务器上的三个终端分屏、实时监控卡片和进行中的文件传输" width="100%">

## 功能

<img src="media/zh/features.png" alt="主机库、懂命令的补全、双栏 SFTP、实时监控与端口转发" width="100%">

| | |
|---|---|
| **连接** | 主机分组、标签、置顶、搜索；密码与密钥认证，生成 Ed25519 密钥，支持跳板与代理 |
| **终端** | 多标签、拖放分屏、本地 Shell、搜索、重连与布局恢复 |
| **文件** | 双栏 SFTP、传输队列、单文件断点续传、冲突处理与外部编辑器 |
| **监控** | 通过 SSH 查看 CPU、内存、磁盘与进程，服务器无需安装任何东西 |
| **工具** | 本地、远程、动态端口转发；命令片段和 1,453 个 Shell 补全规格 |
| **体验** | 现代原生界面，分屏、标签与面板切换顺手；主机密钥校验、系统凭据存储、中英文界面与自定义快捷键 |

## Airy

Airy 就在终端旁边，是一位 AI 助手，配备 **39 个工具**，可管理主机、远端文件、命令、会话、布局与设置。接入你自己的 Anthropic 或 OpenAI 兼容模型，交给它多少由你决定

- **Agent**：说出任务，Airy 一步步处理
- **行内命令**：一句自然语言变成命令，运行前可以修改
- **AI 补全**：边输入边给建议，和 Shell 规格、命令历史排在一起

四档权限覆盖从旁观到放手：**观察、确认、自动确认、全自动**。默认是确认，每个操作都先展示目标和具体内容，由你批准

<img src="media/zh/airy.png" alt="Airy 诊断一个出错的接口，在重启容器前请求批准，旁边是一条行内命令建议" width="100%">

## 主题

冰蓝薄荷、薄荷绿、紫罗兰、落日橙、深海蓝、樱花粉。六套配色贯穿界面、终端与 Airy 形象，浅色和深色都完整适配

<img src="media/zh/themes.png" alt="同一个窗口在六套主题、浅色与深色下的样子，以及各自的 Airy" width="100%">

## 性能

**0.62 秒启动，空闲内存 131 MiB。** 与 Netcatty 相比，空闲内存低约 **71%**，启动速度约快 **4 倍**

<img src="media/zh/performance.png" alt="十款 SSH 客户端的启动时间与空闲内存，从低到高排列" width="100%">

<details>
<summary>全部数据</summary>

<!-- benchmark-table -->

| 客户端 | 启动 | 空闲内存 | 磁盘占用 |
|---|---:|---:|---:|
| **Sshairy** | **0.62 秒** | **131.3 MiB** | **97.4 MiB** |
| Netcatty | 2.60 秒 | 446.8 MiB | 471.8 MiB |
| FinalShell | 7.55 秒 | 333.9 MiB | 189.4 MiB |
| WindTerm | 1.33 秒 | 73.9 MiB | 75.8 MiB |
| electerm | 2.98 秒 | 414.6 MiB | 365.9 MiB |
| Wave Terminal | 2.34 秒 | 500.2 MiB | 616.1 MiB |
| Tabby | 1.91 秒 | 480.8 MiB | 481.4 MiB |
| Termius | 9.74 秒 | 1115.3 MiB | 557.8 MiB |
| MobaXterm | 3.54 秒 | 104.4 MiB | 47.1 MiB |
| Xshell | 3.01 秒 | 35.8 MiB | 102.6 MiB |

<!-- /benchmark-table -->

测量方法、版本与来源见 [tool/readme/SOURCES.md](tool/readme/SOURCES.md)

</details>

**下载体积 27 MiB，解压后 97.4 MiB，单进程原生运行。** 内置 1,453 个 Shell 补全规格

<img src="media/zh/footprint.png" alt="九款 SSH 客户端的下载体积，以及 Sshairy 应用目录的构成" width="100%">

## 获取

Windows 便携版发布在 [Releases](../../releases) 页面。解压后保留完整文件夹，连同 DLL 和 `data` 目录一起运行 `sshairy.exe`

从源码构建需要 Flutter 3.47.9 / Dart 3.13.7。Windows 还需安装 Visual Studio 的 **C++ 桌面开发**工作负载

```sh
flutter pub get
flutter run -d windows
```

生成 Windows 便携版：

```powershell
./tool/package_windows.ps1
```

<div align="center">

[English](README.md) · [中文](README.zh.md)

</div>
