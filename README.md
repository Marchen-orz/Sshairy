<div align="center">

![Preview](https://img.shields.io/badge/preview-0.1.0-2E6EF7?style=flat-square&labelColor=60738C)
![Desktop platforms](https://img.shields.io/badge/desktop-Windows%20%7C%20macOS%20%7C%20Linux-2E6EF7?style=flat-square&labelColor=60738C)
[![Flutter](https://img.shields.io/badge/Flutter-native-2E6EF7?style=flat-square&labelColor=60738C)](https://flutter.dev)
![AI](https://img.shields.io/badge/AI-Airy-168A6A?style=flat-square&labelColor=60738C)
[![English](https://img.shields.io/badge/docs-English-168A6A?style=flat-square&labelColor=60738C)](README.md)
[![中文](https://img.shields.io/badge/docs-%E4%B8%AD%E6%96%87-168A6A?style=flat-square&labelColor=60738C)](README.zh.md)

<img src="media/cover.png" alt="Sshairy. Lightweight SSH. Powered by AI. 0.62 s startup, 131 MiB idle memory, 27 MiB portable ZIP." width="100%">

[Features](#features) · [Airy](#airy) · [Themes](#themes) · [Performance](#performance) · [Build](#build)

</div>

**Sshairy** is a lightweight SSH client for **Windows, macOS and Linux**. Terminals, SFTP, tunnels and server monitoring come together in a clean native interface, built with Dart and Flutter.

A full SSH client first, with AI to help along the way. Keep working in the terminal, ask Airy to handle a task, or turn a sentence into a command. No Chromium, no WebView, no browser runtime to carry around.

<img src="media/workspace.png" alt="The host library in the default Ice Blue / Mint theme, with groups, pinned hosts and search." width="100%">

## Features

| | |
|---|---|
| **Connect** | Organize hosts with groups, tags, pins and search. Password and key authentication, Ed25519 key generation, jump hosts and proxies. |
| **Work** | Tabbed terminals, draggable splits, local shells, search, reconnect and restored layouts. |
| **Move files** | Dual-pane SFTP, transfer queues, resumable file transfers, conflict handling and external editing. |
| **Keep watch** | CPU, memory, disk and process monitoring over SSH. Nothing to install on the server. |
| **Reach further** | Local, remote and dynamic port forwarding. Saved snippets and 1,453 shell completion specs. |
| **Stay in control** | Host-key verification and OS-backed credential storage. English and Chinese interfaces, customizable shortcuts. |

## Airy

An assistant beside your terminal, with **39 tools** for hosts, remote files, commands, sessions, layouts and settings. Connect your Anthropic or OpenAI-compatible model and choose how much to delegate.

- **Agent** — describe a task and let Airy work through it.
- **Inline commands** — turn a plain-language request into an editable command.
- **AI completion** — get suggestions as you type, alongside shell specs and command history.

Four permission modes fit different workflows: **Observe**, **Confirm**, **Auto confirm** and **Full auto**. Confirm is the default, with the target and operation presented for approval.

<img src="media/airy.png" alt="Airy and its action approval panel." width="100%">

## Themes

Ice Blue / Mint, Mint Green, Violet, Sunset Orange, Deep Sea Blue and Sakura Pink. Each palette carries through the interface, terminal and Airy artwork, with both light and dark appearances.

<img src="media/themes.png" alt="Six themes with matching interface colors and Airy artwork." width="100%">

## Performance

**0.62 seconds to open. 131 MiB at idle.** Sshairy uses about **71% less idle memory** than Netcatty and opens about **4× sooner**.

<img src="media/performance.png" alt="Startup and idle memory comparison across SSH clients." width="100%">

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

A **27 MiB download**, **97.4 MiB unpacked**, and **one native app process**, with **1,453 shell completion specs** included.

<img src="media/footprint.png" alt="Download size comparison and the contents of the Sshairy app folder." width="100%">

## Build

Requires Flutter 3.47.9 / Dart 3.13.7. For Windows, install Visual Studio's **Desktop development with C++** workload.

```sh
flutter pub get
flutter run -d windows
```

Create a portable Windows release:

```powershell
./tool/package_windows.ps1
```

Run `sshairy.exe` from the complete release folder, alongside its DLLs and data directory.

<div align="center">

[English](README.md) · [中文](README.zh.md)

</div>
