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

**Sshairy** is a lightweight, cross-platform SSH client for **Windows, macOS and Linux**, built with Dart and Flutter. Terminals, SFTP, tunnels and server monitoring share a modern native interface, without Chromium or WebView.

The idea is straightforward: make a good everyday SSH client, keep it quick and light, then let AI help with the work. SSH works independently; Airy adds an assistant, inline command generation and AI completion when you want them.

On our Windows test PC, it opens in **0.62 seconds**, with **131 MiB** of idle memory and a **27 MiB** download.

<img src="media/workspace.png" alt="The host library in the default Ice Blue / Mint theme, with groups, pinned hosts and search." width="100%">

## Features

| | |
|---|---|
| **Connect** | Group, tag, pin and search hosts. Password and key authentication, Ed25519 key generation. |
| **Work** | Tabbed terminals, splits, local shells, search, reconnect and restored layouts. |
| **Move files** | Dual-pane SFTP, transfer queues, conflict handling and external editing. |
| **Keep watch** | CPU, memory and disk monitoring over SSH. Nothing to install on the server. |
| **Reach further** | Local, remote and dynamic port forwarding. Saved snippets and 1,453 shell completion specs. |
| **Stay in control** | Host-key verification before authentication; changed keys blocked by default. Passwords and private keys in the OS secure store. |

## Airy

Describe the task beside your terminal. Airy can inspect hosts, work with remote files, run commands and help with diagnostics, using **39 built-in tools**. Bring an Anthropic or OpenAI-compatible model; AI stays off until you configure it.

The default **Confirm** mode asks before an action runs. You see the target and the exact operation, and can approve or reject it. Choose **Observe** for read-only work, **Auto confirm** for review by a second model, or **Full auto** to allow actions without approval prompts within the scope you select.

<img src="media/airy.png" alt="Airy beside an enlarged crop of the real action approval panel. A demo request moves gpu-box to the Staging group." width="100%">

Passwords and private keys stored by Sshairy are not sent to the model. Approved tools return bounded results; review the output you choose to share.

<sub>Interface images are crops of the running app with fictional hosts, a local PowerShell session and scripted model replies. No remote server is contacted in these demos.</sub>

## Themes

Ice Blue / Mint is the default. Five more palettes change the whole interface, with matching Airy artwork. Every theme also has a dark variant; the gallery below shows the light palettes.

<img src="media/themes.png" alt="Six light themes: Ice Blue / Mint, Mint Green, Violet, Sunset Orange, Deep Sea Blue and Sakura Pink. Each shows real UI details and its matching mascot." width="100%">

## Performance

Quick to open and modest at idle. On the same PC, Sshairy used about **71% less idle memory** than Netcatty and reached its first window about **4× sooner**.

<img src="media/performance.png" alt="Startup: Sshairy 0.62 s, Netcatty 2.60 s, FinalShell 7.55 s. Idle process-tree USS: Sshairy 131.3 MiB, Netcatty 446.8 MiB, FinalShell 333.9 MiB." width="100%">

AOT-compiled Dart and Flutter keep the app native. The measured Windows build runs in **one app process** and unpacks to **97.4 MiB**. Its largest component is the bundled shell completion library.

<img src="media/footprint.png" alt="Windows download sizes and the Sshairy app folder. Sshairy 27.2 MiB; WindTerm 31.2; electerm 114.6; Netcatty 126.9; Wave Terminal 156.2; Tabby 161.9; Termius 327.9. Of Sshairy's 97.4 MiB unpacked, shell completions account for 52.7 MiB." width="100%">

<details>
<summary>Measurements, versions and other clients</summary>

Windows 11, Ryzen 7 8845HS, 24 GB RAM, 2026-11-13. Startup is the median of five warm launches, from process creation to the first visible window. Memory is the whole process tree's unique set size, 15 seconds after launch with no sessions open. Sshairy and Netcatty used isolated profiles; FinalShell used a copy of its installation without user data. These are startup and idle figures; active sessions can use more memory.

| Client | Built with | Built-in AI | Windows download | Startup | Idle memory |
|---|---|---|---:|---:|---:|
| **Sshairy 0.1.0** | Dart + Flutter | Airy agent | **27.2 MiB ZIP** | **0.62 s** | **131.3 MiB** |
| Netcatty 1.1.90 | Electron + React | Agent | 126.9 MiB portable EXE | 2.60 s | 446.8 MiB |
| FinalShell¹ | Java + bundled JRE | Not listed | — | 7.55 s | 333.9 MiB |
| WindTerm 2.7.0 | Native / C | Not listed | 31.2 MiB ZIP | — | — |
| electerm 5.10.0 | Electron | Assistant / agent mode | 114.6 MiB installer | — | — |
| Wave Terminal 0.14.5 | Electron + Go | Wave AI | 156.2 MiB EXE | — | — |
| Tabby 1.0.238 | Electron + Angular | Not listed | 161.9 MiB setup | — | — |
| Termius | Electron | Command AI / agent beta | 327.9 MiB installer | — | — |
| MobaXterm 26.6 | Native | Not listed | ~42.2 MB portable² | — | — |
| Xshell 8 build 0107 | Native | Not listed | ~49.9 MB installer² | — | — |

Only Sshairy, Netcatty and FinalShell were run. Other sizes are public download metadata, with formats shown because compression and installers differ. “Not listed” means no built-in AI was found in the documentation checked, rather than a guarantee about future versions.

¹ FinalShell's exact version was unavailable; JAR dated 2025-04-08, bundled JRE 17.0.7. ² Third-party directory values in MB, excluded from the MiB chart.

[Sources, raw figures and image provenance](tool/readme/SOURCES.md). The 27.2 MiB ZIP is the measured application bundle; adding documentation or artwork changes the archive size.

</details>

## Build

Requires Flutter 3.47.9 / Dart 3.13.7. On Windows, install Visual Studio's **Desktop development with C++** workload.

```sh
flutter pub get
flutter run -d windows
```

Create a portable Windows release:

```powershell
./tool/package_windows.ps1
```

Keep the whole release folder together, including its DLLs and data directory.

## Project status

Sshairy is an early personal project for **Windows, macOS and Linux**. Current testing covers the Windows 11 desktop client and an Ubuntu SSH server; macOS and Linux desktop builds still need verification. Local shells currently use Windows ConPTY; Unix local PTY support is pending. The Windows package is unsigned, with no installer or automatic updater yet.

The project is intended to be open source; its license is still being selected. It is primarily built for the author's own use, without compatibility or availability guarantees. There is no CI yet, and memory use during long, busy sessions still needs work.

<div align="center">

[English](README.md) · [中文](README.zh.md)

</div>
