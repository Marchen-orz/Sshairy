# 依赖与素材

2026-11-06。本表根据当前本机 Pub cache 的 LICENSE 文件核对；精确版本以 `pubspec.lock` 为准。它不是项目许可证，也不是完整发行审计。

| 直接依赖 | LICENSE |
|---|---|
| dartssh2、xterm2、flutter_riverpod、pinenacl | MIT |
| desktop_drop | Apache-2.0 |
| crypto、ffi、file_selector、flutter_secure_storage、intl、path_provider、yaml、flutter_markdown_plus | BSD-3-Clause |
| Flutter SDK、flutter_localizations | BSD-3-Clause；SDK 的其他组件另有各自声明 |

yaml（dart-lang 官方，2026-11-08 加入，原为传递依赖）只在 `hosts/adapters` 读 Tabby 的 config.yaml。

flutter_markdown_plus 1.0.12（2026-11-11 加入，发布于 2026-07-10）用于 `ai/adapters` 的回复渲染；BSD-3-Clause 已按 pub.dev 发布包的 LICENSE 核对，维护来源为 Foresight Mobile，精确传递依赖随 lockfile 和 notices 保留。适配器不加载 Markdown 图片，链接只在用户点击后打开 http(s)，不用 HTML/WebView。组件、窄面板和图片/链接边界的验证结果见 TESTING §6；未据上游支持列表推定所有 Markdown 扩展均可用。

Windows 本地终端通过已有 ffi 直接调用系统 ConPTY，无新增分发库。2026-11-10 核对 flutter_pty 0.4.2 时发现其原生句柄释放、退出尾部输出及路径参数实现不满足本项目生命周期要求，未采用；Unix PTY 尚未实现，不据 Windows 结果推定跨平台可用。

`tool/write_notices.dart` 从 `.dart_tool/package_config.json` 解析到的包读取许可证与 NOTICE，包含构建依赖，产出 `THIRD_PARTY_NOTICES.txt`。许可证缺失时失败。Windows 打包脚本将该文件放入完整 runner 分发目录。

当前未附带自定义 UI／终端字体，使用系统字体；Flutter 自带的 Material Icons 由其资产许可证覆盖，应随 Flutter notices 保留。应用品牌与六套主题来自作者提供的 `Sshairy-Brand-Asset-Pack/`，实际使用的 PNG 与来源映射在 `assets/brand/`；Windows/macOS 静态图标从包内默认冰蓝薄荷的 app-icon-1024.png 导出。`tool/import_brand.py` 只读取包中的图像和 JSON，不运行素材包代码。导入来源 SVG 由专用适配器使用 flutter_svg 渲染。旧 GPT 生成图与提示词保留在 `output/imagegen/`，不再用于应用。来源说明见 `docs/BRAND.md`；这不替代正式发行时的素材许可复核。没有使用 Netcatty 的代码、图标或品牌资源。

发行前仍需：确定项目 LICENSE、复核 Flutter engine／ICU／图标等内嵌资产声明与原生插件依赖、确认实际 ZIP 内的许可证齐全，并决定签名与分发方式。Windows 本地验证包不等于完成正式发行审计。
