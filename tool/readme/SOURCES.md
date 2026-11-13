# README artwork and figures

Product positioning follows the local design documents: a lightweight, modern, native SSH client for Windows, macOS and Linux, with SSH usable independently and AI added to help with server work. The roughly 200 MB daily-use memory goal in DESIGN is a goal, not a measured limit. Current desktop verification is Windows; an Ubuntu SSH server is not Linux desktop verification.

## Artwork

The six light spreads in `media/` and their Chinese versions in `media/zh/` are exported by `make_images.py`. There are no dark README variants. Text and numbers are typeset with Segoe UI / Microsoft YaHei; chart values come from the measurements below.

- Brand wordmark, Airy poses and palette tokens: the author's `Sshairy-Brand-Asset-Pack/`. Used as supplied, cropped to transparent bounds and resized proportionally. No redrawing, mirroring or recoloring. The app's adjusted Ice Blue interaction color is separate from the artwork's original brand color.
- Cover environment: `media/source/airflow.png`, generated on 2026-11-13 through the Codex **imagegen** skill's bundled CLI, with `imagegen-config-fallback` because the built-in image tool was unavailable. Model: `gpt-image-2`; requested size: 2048 × 1152, high quality; returned image: 1672 × 941, scaled for the final spread. Exact prompt: [cover-prompt.txt](cover-prompt.txt). The model generated only the white, ice-blue and mint glass ribbons; the original wordmark and mascot were composited afterward.
- Host and Airy panels: real Flutter screenshots produced by `integration_test/readme_shots_test.dart`. Fictional hosts use RFC 5737 addresses and example.com; the terminal is local PowerShell; model responses are scripted on loopback. No remote server or real model task is shown.
- Theme panels: close crops from the six real application screenshots in `media/tiles/`, plus the supplied matching mascot and palette. The UI crops use English in both language editions; surrounding captions are localized.

Re-export on Windows with Pillow, the brand pack and the checked-in screenshot sources:

```sh
python -I -X utf8 tool/readme/make_images.py
```

The brand pack is an external local source, not a runtime dependency or a script to execute. Keep its own source and license information when preparing a release. README artwork is not included in the application footprint measurement below.

## Startup and memory

Measured 2026-11-13 on Windows 11 Home build 26200, Ryzen 7 8845HS, approximately 24 GB RAM. A warm-up run precedes five measured launches. Startup ends at the first visible window of at least 600 × 400 pixels. Memory is whole-process-tree USS, sampled 15 seconds after that window appears, without sessions open. RSS is not added to USS.

| Client | Median startup | Idle USS | Processes |
|---|---:|---:|---:|
| Sshairy 0.1.0 | 0.624 s | 131.3 MiB | 1 |
| Netcatty 1.1.90 | 2.604 s | 446.8 MiB | 5 |
| FinalShell, exact version unavailable | 7.548 s | 333.9 MiB | 3 |

Sshairy's five startup samples: 0.615, 0.641, 0.760, 0.607, 0.624 seconds. FinalShell was measured from a copy of its installation without user data; JAR dated 2025-04-08, bundled JRE 17.0.7. Sshairy and Netcatty used isolated profiles. Other clients were not run.

The rounded promotional comparisons use `1 - 131.3 / 446.8 = 70.6%` lower idle USS and `2.604 / 0.624 = 4.17` times the startup duration for Netcatty. This is one machine, not a universal performance guarantee. A 593 MiB Release RSS peak has also been seen during longer use and has not been explained; idle figures do not establish a daily-use maximum.

Measurement tool (it closes only the processes it starts):

```sh
python -I tool/readme/measure_startup.py sshairy <empty-profile-dir> "build/windows/x64/runner/Release/sshairy.exe"
```

## Downloads and application folder

Snapshot read on 2026-11-13. MiB means bytes / 1,048,576. ZIPs, portable executables and installers use different compression and packaging; these numbers describe the offered downloads, not identical installed contents.

| Client | Artifact | MiB |
|---|---|---:|
| Sshairy 0.1.0 | Measured Windows portable ZIP | 27.2 |
| WindTerm 2.7.0 | Windows portable ZIP | 31.2 |
| electerm 5.10.0 | Windows installer | 114.6 |
| Netcatty 1.1.90 | Windows portable EXE | 126.9 |
| Wave Terminal 0.14.5 | Windows EXE | 156.2 |
| Tabby 1.0.238 | Windows setup | 161.9 |
| Termius | Windows installer, 343,825,648 bytes | 327.9 |

MobaXterm 26.6 portable (~42.2 MB) and Xshell 8 build 0107 (~49.9 MB) are third-party directory figures in MB. They remain in the README table with that qualification, and are excluded from the MiB chart.

The Sshairy application folder was 97.4 MiB unpacked. Its rounded inventory: shell completion specs 52.7 MiB (1,453 files), Flutter engine 20.3, AOT app code 14.7, brand artwork 5.6, other files 4.1 (runner/plugins, notices/README, ICU and remaining assets). Adding README artwork to a distribution would change both its ZIP and unpacked size.

Public sources for releases, technology and AI features:

- [Netcatty](https://github.com/binaricat/Netcatty) · [releases](https://github.com/binaricat/Netcatty/releases)
- [Wave Terminal](https://github.com/wavetermdev/waveterm) · [releases](https://github.com/wavetermdev/waveterm/releases)
- [electerm](https://github.com/electerm/electerm) · [releases](https://github.com/electerm/electerm/releases)
- [Tabby](https://github.com/Eugeny/tabby) · [releases](https://github.com/Eugeny/tabby/releases)
- [WindTerm](https://github.com/kingToolbox/WindTerm) · [releases](https://github.com/kingToolbox/WindTerm/releases)
- [Termius](https://termius.com/) · [changelog](https://termius.com/changelog)
- [FinalShell](https://www.hostbuf.com/)
- [MobaXterm](https://mobaxterm.mobatek.net/)
- [Xshell](https://www.netsarang.com/en/xshell/) · [Softpedia listing](https://www.softpedia.com/get/Network-Tools/Telnet-SSH-Clients/Xshell.shtml)

Refresh GitHub release metadata with `fetch_release_sizes.py`; identify the Windows artifacts in its output before using the sizes:

```sh
python -I tool/readme/fetch_release_sizes.py wavetermdev/waveterm Eugeny/tabby electerm/electerm
```

Third-party features and releases can change. “AI not listed” only describes the documentation checked. Netcatty was used as a design reference; none of its GPL code or brand assets are used in these illustrations.
