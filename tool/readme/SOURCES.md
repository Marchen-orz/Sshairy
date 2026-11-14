# README artwork and data

The README presents the product and comparison results. This file keeps the production and measurement records. Product positioning comes from DESIGN: a lightweight, modern, native SSH client for Windows, macOS and Linux, with SSH usable independently and AI added to help with server work.

## Artwork

`spreads.html` lays out seven spreads; `render_spreads.py` exports them at 2× (2400 px wide) into `media/` and `media/zh/`. The landing page (`site/`) and the film (`tool/motion/`) share the same tokens, fonts, charts and drawn panels.

- Wordmark, Airy poses and theme palettes: the author's `Sshairy-Brand-Asset-Pack/`, exported to `site/assets/brand/` by `tool/site/export_assets.py`. The source pack remains unchanged.
- Interface panels: drawn in HTML by `site/mock.js` using the twelve palettes shipped in `lib/design/brand_palette_data.dart` (exported to `site/themes.css`) and the app's real labels. They are illustrations with fictional RFC 5737/example.com hosts, not screenshots. Real screenshots from `integration_test/readme_shots_test.dart` remain in `media/` as reference.
- Cover environment: `media/source/airflow.png`, generated on 2026-11-13 with the Codex imagegen bundled CLI/config fallback and `gpt-image-2`. Requested 2048 × 1152 at high quality; returned 1672 × 941. [Exact prompt](cover-prompt.txt).
- Fonts: Inter, Instrument Serif and JetBrains Mono (SIL OFL 1.1, latin subsets from Fontsource), with system Chinese fonts.
- Film soundtrack: `tool/motion/bgm.mp3`, instrumental, generated on 2026-11-14 with `lyria-3.5` through an OpenAI-compatible endpoint supplied by the author (about 68 s, ~110 BPM). Scene cuts follow its bars.

```sh
python -I -X utf8 tool/site/export_assets.py   # brand artwork, palettes, chart data
python -I -X utf8 tool/readme/render_spreads.py
python -I -X utf8 tool/motion/render.py        # site/media/sshairy-{en,zh}.mp4, needs ffmpeg
```

Rendering uses Playwright for Python with an installed Microsoft Edge.

## Client measurements

[benchmarks.json](benchmarks.json) supplies the performance charts and stores versions, startup samples, memory, application folder sizes, download URLs and artifact hashes.

Measurements collected on 2026-11-13, with Xshell, electerm and signed-in Termius remeasured on 2026-11-14 against actual workspace readiness. One warm-up precedes five launches; startup is their median. Xshell waits for a visible enabled `Xshell8::MainFrame_*` with an `Xshell8::CoreApp` terminal child, after closing its registration prompt through the normal window close action. electerm waits until Windows UI Automation exposes its visible enabled terminal Edit. Termius waits for visible enabled Hosts, New Host and SFTP buttons in its signed-in workspace, without welcome/sign-in buttons. The other rows retain their earlier first-visible-window baseline (at least 600 × 400); they were not rechecked in this revision. Window size alone cannot prove application readiness. Memory is whole-process-tree USS 15 seconds after the relevant readiness signal, including default local tabs and helper processes. Runs are sequential, use no remote SSH connections and count extracted or installed application files; the Sshairy ZIP size refers to the original application bundle.

| Client | Version | Startup | Idle USS | App folder | Processes |
|---|---|---:|---:|---:|---:|
| Sshairy | 0.1.0+1 | 0.624 s | 131.3 MiB | 97.4 MiB | 1 |
| Netcatty | 1.1.90 | 2.604 s | 446.8 MiB | 471.8 MiB | 5 |
| FinalShell | JAR 2025-04-08 / JRE 17.0.7 | 7.548 s | 333.9 MiB | 189.4 MiB | 3 |
| WindTerm | 2.7.0 | 1.333 s | 73.9 MiB | 75.8 MiB | 7 |
| electerm | 5.10.0 | 2.977 s | 414.6 MiB | 365.9 MiB | 8 |
| Wave Terminal | 0.14.5 | 2.341 s | 500.2 MiB | 616.1 MiB | 7 |
| Tabby | 1.0.238 | 1.913 s | 480.8 MiB | 481.4 MiB | 5 |
| Termius | 10.4.1 | 9.742 s | 1115.3 MiB | 557.8 MiB | 7 |
| MobaXterm | 26.6 | 3.545 s | 104.4 MiB | 47.1 MiB | 2 |
| Xshell | 8.0.0120 | 3.008 s | 35.8 MiB | 102.6 MiB | 2 |

Sshairy, Netcatty and FinalShell retain their earlier measurements. WindTerm, Wave, Tabby and MobaXterm retain their 2026-11-13 runs from official releases. WindTerm uses its fresh portable tree; the Electron clients use explicit user-data directories, redirected home/AppData paths and supported application-specific profile variables. Tabby and Termius are extracted from their official installers; Wave and electerm use portable archives. MobaXterm uses its Home portable release with an explicit temporary INI path. The electerm remeasurement reuses only its benchmark-owned profile and verifies the terminal input through read-only accessibility inspection. Termius uses its normal Windows configuration after the author completed sign-in, without a temporary user-data-dir or redirected home/AppData paths; restart persistence was verified before accepting samples. Test processes are closed after each run.

Xshell 8.0.0120 was manually installed by the author (102.6 MiB app folder). Its old 0.242 s / 11.3 MiB result described the registration page and remains rejected. On 2026-11-14, normal closing of that page was observed to open the terminal main window without entering a code. Timing includes this transition, beginning before process creation; all five accepted samples verify the main-frame class and terminal child. The remeasurement uses the installed configuration after confirming no existing Xshell process, and only closes benchmark-created processes. The [official installer](https://cdn.netsarang.net/bf4f1d11/Xshell-8.0.0120p.exe) is 47,636,296 bytes (SHA256 `bb33c314e281c6b32a16e1861d52173553979cb84267dafe96068bb08625d8ef`). The earlier assumption that registration had to be completed before the main window could be reached was incorrect for this installed build.

electerm's old 0.404 s result was also the native window shell: accessibility inspection found only window controls initially, with terminal input appearing later. Its new startup samples use the terminal-ready signal rather than that shell.

Termius 10.4.1 was remeasured after the author signed in and its actual Hosts workspace was verified. Its old 0.784 s / 1670.8 MiB row described native-window appearance and onboarding, so those values remain invalid. The high onboarding memory was reproducible (1678.3 MiB USS at about 16 seconds, including 1064.4 MiB in the GPU process), but is not the signed-in idle baseline. The earlier temporary-profile launch and the normal Windows sign-in callback used different startup parameters; the accepted remeasurement uses the normal configuration consistently. Normal close and restart retained sign-in. Every warm-up/sample verifies visible enabled Hosts, New Host and SFTP buttons with no welcome/sign-in buttons; all runs exit normally without force termination. The new median is 9.742 s and idle process-tree USS is 1115.3 MiB, sampled 15 seconds after workspace readiness. The benchmark did not read credential files, supply account information, open SSH connections or inspect browser content during the accepted runs. Its downloaded artifact (327.9 MiB) and extracted app folder (557.8 MiB) remain valid size measurements.

The README's comparison to Netcatty rounds `1 - 131.3 / 446.8 = 70.6%` to 71% lower idle memory and `2.604 / 0.624 = 4.17` to 4× the startup speed.

The baseline harness is [measure_startup.py](measure_startup.py). For isolated Electron baselines, pass `--user-data-dir=<empty-profile>/electron` and their application-specific configuration overrides; signed-in Termius follows the normal-profile method above. Additional isolation used for the other clients:

- Isolated portable and Electron baselines: redirected `HOME`, `USERPROFILE`, `HOMEDRIVE`, `HOMEPATH`, `APPDATA`, `LOCALAPPDATA` and XDG configuration/data/cache directories.
- Tabby: `TABBY_CONFIG_DIRECTORY`.
- Wave: `WAVETERM_DATA_HOME`, `WAVETERM_CONFIG_HOME`, `WAVETERM_NOCONFIRMQUIT=1`.
- electerm: `ELECTERM_REGISTER_PROTOCOLS=false`.
- MobaXterm: `-i <temporary-profile>/MobaXterm.ini` ([official command-line documentation](https://mobaxterm.mobatek.net/documentation.html)).
- Xshell uses the documented [`-newwin` option](https://netsarang.atlassian.net/wiki/spaces/ENSUP/pages/2237306095/Xshell+Command+Line+Options). Its [folder documentation](https://netsarang.atlassian.net/wiki/spaces/ENSUP/pages/177471571/Changing%2Bthe%2BUser%2BData%2BFolder%2B-%2BXshell) describes a setting in the UI; no undocumented profile switch was assumed.

## Downloads and folder contents

The download chart uses the normal Windows release artifacts listed below. The benchmark may use the portable equivalent for isolated installation; its exact downloaded artifact is recorded in the JSON.

| Client | Artifact | MiB |
|---|---|---:|
| Sshairy | Windows portable ZIP | 27.2 |
| WindTerm 2.7.0 | Windows portable ZIP | 31.2 |
| MobaXterm Home 26.6 | Windows portable ZIP | 42.2 |
| Xshell Free 8.0.0120p | Windows installer | 45.4 |
| electerm 5.10.0 | Windows installer | 114.6 |
| Netcatty 1.1.90 | Windows portable EXE | 126.9 |
| Wave Terminal 0.14.5 | Windows EXE | 156.2 |
| Tabby 1.0.238 | Windows setup | 161.9 |
| Termius | Windows installer | 327.9 |

The Sshairy application folder contains shell completion specs (52.7 MiB, 1,453 files), Flutter engine (20.3), AOT app code (14.7), brand artwork (5.6) and other files (4.1), totaling 97.4 MiB. MiB = bytes / 1,048,576.

Official release and product sources:

- [Netcatty](https://github.com/binaricat/Netcatty/releases)
- [WindTerm](https://github.com/kingToolbox/WindTerm/releases)
- [electerm](https://github.com/electerm/electerm/releases)
- [Wave Terminal](https://github.com/wavetermdev/waveterm/releases)
- [Tabby](https://github.com/Eugeny/tabby/releases)
- [Termius](https://termius.com/)
- [FinalShell](https://www.hostbuf.com/)
- [MobaXterm](https://mobaxterm.mobatek.net/)
- [Xshell](https://www.netsarang.com/en/xshell/)

```sh
python -I tool/readme/fetch_release_sizes.py wavetermdev/waveterm Eugeny/tabby electerm/electerm
```
