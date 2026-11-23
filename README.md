<div align="center">

<img src="media/cover.png" alt="Sshairy. Lightweight SSH. Powered by AI. 0.62 s to open, 131 MiB at idle, 27 MiB to download, one process." width="100%">

[Features](#features) · [Airy](#airy) · [Themes](#themes) · [Performance](#performance) · [Why](#why) · [Get Sshairy](#get-sshairy) · [中文](README.zh.md)

![Preview](https://img.shields.io/badge/preview-0.3.0-2E6EF7?style=flat-square&labelColor=1F3A5F)
![Platforms](https://img.shields.io/badge/platforms-Windows%20%7C%20macOS%20%7C%20Linux%20%7C%20Android-2E6EF7?style=flat-square&labelColor=1F3A5F)
[![Flutter](https://img.shields.io/badge/Flutter-native-5AB6FF?style=flat-square&labelColor=1F3A5F)](https://flutter.dev)
![AI](https://img.shields.io/badge/AI-Airy-3CC9A7?style=flat-square&labelColor=1F3A5F)
[![LINUX DO](https://img.shields.io/badge/community-LINUX%20DO-F5A623?style=flat-square&labelColor=1F3A5F)](https://linux.do)

</div>

**Sshairy** is a lightweight SSH client for **Windows, macOS, Linux, and Android**, built with Dart and Flutter. On desktop, terminals, SFTP, tunnels, and server monitoring share one native window with tabs, splits, and panels. On Android, connect directly with a touch terminal or use Device Link to mirror sessions and share files with a computer.

AI is part of the SSH workflow: hand Airy a task or turn a sentence into a command, and it reads context, checks servers and carries out the work. Lightweight, modern and easy to use, with no Chromium, no WebView and no browser runtime to carry around.

<img src="media/preview.gif" alt="A short tour of Sshairy: fast startup, one window for every server, completion with context, Airy commands and approvals, themes and measured performance." width="100%">

<img src="media/workspace.png" alt="A Sshairy window with three terminal panes on two servers, a live metrics card and a file transfer in progress." width="100%">

## Features

<img src="media/features.png" alt="Host library, context-aware completion, dual-pane SFTP, live metrics and port forwarding." width="100%">

<table>
<tr><td><b>Connect</b></td><td>Hosts in groups with tags, pins and search. Password and key authentication, Ed25519 key generation, jump hosts and proxies.</td></tr>
<tr><td><b>Work</b></td><td>Tabbed terminals, draggable splits, local shells, search, reconnect and restored layouts.</td></tr>
<tr><td><b>Move files</b></td><td>Dual-pane SFTP, transfer queues, resumable file transfers, conflict handling and external editing.</td></tr>
<tr><td><b>Keep watch</b></td><td>CPU, memory, disk and process monitoring over SSH, with nothing to install on the server.</td></tr>
<tr><td><b>Reach further</b></td><td>Local, remote and dynamic port forwarding. Saved snippets and 1,453 shell completion specs.</td></tr>
<tr><td><b>Stay in control</b></td><td>Modern native interface with fluid tabs, splits and panels. Host-key verification, OS-backed credential storage, English and Chinese interfaces, customizable shortcuts.</td></tr>
</table>

## Airy

Airy is the AI assistant beside your terminal, with **42 tools** for hosts, remote files, commands, sessions, layouts and settings. Bring your own Anthropic or OpenAI-compatible model and decide how much to delegate.

- **Agent.** Describe a task and Airy works through it step by step.
- **Inline AI tasks.** Work through a task in the current terminal and review each command before running it.
- **AI completion.** See suggestions after the cursor as you type.

Four permission modes cover the range from watching to hands-off: **Observe**, **Confirm**, **Auto confirm** and **Full auto**. Confirm is the default, and every action shows its target and exact operation before you approve it.

<img src="media/airy.png" alt="Airy diagnosing a failing endpoint and asking for approval before restarting a container, with an inline command suggestion beside it." width="100%">

## MCP / Skill

Open **Settings → MCP / Skill**, choose an approval mode, then enable Claude Code, Codex, Zcode or DeepSeek Harness. Each switch installs the connection and Skill. Approve the client's first connection in Sshairy. MCP exposes the same tool catalog as Airy, including SSH commands and jobs, files and transfers, terminal context, workspace, hosts, settings, and port forwarding.

**Host confirmation** asks once per host per session. **Model review** also reviews each eligible call. **Automatic within scope** runs on selected hosts without a host prompt or per-call model review. Existing terminal access and local file grants still need explicit approval. The MCP settings also show the audit log and let you revoke client access.

## Themes

Ice Blue / Mint, Mint Green, Violet, Sunset Orange, Deep Sea Blue and Sakura Pink. Each palette carries through the interface, the terminal and Airy's artwork, in light and dark.

<img src="media/themes.png" alt="One window shown across six themes in light and dark, with the matching Airy for each." width="100%">

## Performance

**0.62 seconds to open. 131 MiB at idle.** Next to Netcatty, that is about **71% less idle memory** and a start about **4× sooner**.

<img src="media/performance.png" alt="Startup time and idle memory of ten SSH clients, sorted from lowest to highest." width="100%">

<details>
<summary>Full comparison</summary>

<!-- benchmark-table -->

| Client | Startup | Idle memory | App folder |
|---|---:|---:|---:|
| **Sshairy** | **0.62 s** | **131.3 MiB** | **97.4 MiB** |
| Netcatty | 2.60 s | 446.8 MiB | 471.8 MiB |
| FinalShell | 7.55 s | 333.9 MiB | 189.4 MiB |
| WindTerm | 1.33 s | 73.9 MiB | 75.8 MiB |
| electerm | 2.98 s | 414.6 MiB | 365.9 MiB |
| Wave Terminal | 2.34 s | 500.2 MiB | 616.1 MiB |
| Tabby | 1.91 s | 480.8 MiB | 481.4 MiB |
| Termius | 9.74 s | 1115.3 MiB | 557.8 MiB |
| MobaXterm | 3.54 s | 104.4 MiB | 47.1 MiB |
| Xshell | 3.01 s | 35.8 MiB | 102.6 MiB |

<!-- /benchmark-table -->

</details>

A **27 MiB download** unpacks to **97.4 MiB** and runs as **one native process**, with 1,453 shell completion specs included.

<img src="media/footprint.png" alt="Download sizes of ten SSH clients and the contents of the Sshairy app folder." width="100%">

## Why

I have tried many SSH clients over the years, and most fell a little short. FinalShell came closest and stayed in daily use, but slow startup, an interface that no longer felt modern, high resource use and no AI kept bothering me — and I suspect many others feel the same.

When I finally had some time, I decided to build the client I wanted: low overhead, AI woven into the workflow, a modern interface and fluid interaction. I named it Sshairy — a combination of SSH and Airy that also happens to contain "Ai" and "hair" (the hair was unintentional, though programmers and hair have a long and complicated relationship, Orz). The goal is a lightweight, modern SSH client that is smooth and easy to use.

Sshairy has taken a lot of work, and it draws on the best ideas from other clients. It is primarily for my own use and still has rough edges; I hope the open-source community can help maintain it and make it better.

## Get Sshairy

Download builds on [GitHub Releases](https://github.com/Marchen-orz/sshairy/releases). See what's changed in the [changelog](CHANGELOG.md).

| Platform | Download |
|---|---|
| Windows x64 | `setup.exe` for the current user or `portable.exe` to run without installing |
| macOS (Apple silicon and Intel) | Universal DMG or ZIP, early build |
| Linux x64 | AppImage or `.deb`, early build |
| Android 8.0+ | Universal preview APK for ARM64, ARMv7, and x86_64 |
| iOS | Pending |

Desktop packages lack distribution signing. Windows SmartScreen may warn on first launch (More info → Run anyway). On macOS, right-click the app and choose Open, or allow it in System Settings → Privacy & Security. The Android preview APK uses a development signature.

To build from source you need Flutter 3.47.9 / Dart 3.13.7. On Windows, also install Visual Studio's **Desktop development with C++** workload.

```sh
flutter pub get
flutter run -d windows
```

Package a Windows release (the installer needs [Inno Setup 6](https://jrsoftware.org/isinfo.php); pass `-SkipInstaller` without it):

```powershell
./tool/package_windows.ps1
```

On macOS or Linux, `./tool/package_unix.sh` builds the DMG/ZIP or the AppImage/deb.

## License

[MIT](LICENSE)

<div align="center">

[English](README.md) · [中文](README.zh.md)

</div>
