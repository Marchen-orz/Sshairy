# 依赖与素材

2026-11-06。本表根据当前本机 Pub cache 的 LICENSE 文件核对；精确版本以 `pubspec.lock` 为准。它不是项目许可证，也不是完整发行审计。

| 直接依赖 | LICENSE |
|---|---|
| dartssh2、xterm2、flutter_riverpod、pinenacl | MIT |
| desktop_drop | Apache-2.0 |
| crypto、ffi、file_selector、flutter_secure_storage、intl、path_provider | BSD-3-Clause |
| Flutter SDK、flutter_localizations | BSD-3-Clause；SDK 的其他组件另有各自声明 |

`tool/write_notices.dart` 从 `.dart_tool/package_config.json` 解析到的包读取许可证与 NOTICE，包含构建依赖，产出 `THIRD_PARTY_NOTICES.txt`。许可证缺失时失败。Windows 打包脚本将该文件放入完整 runner 分发目录。

当前未附带自定义 UI／终端字体，使用系统字体；Flutter 自带的 Material Icons 由其资产许可证覆盖，应随 Flutter notices 保留。应用图标通过 GPT Image 2 原创生成，透明 PNG 母版是 `assets/brand/icon-source.png`；原始生成图与提示词保留在 `output/imagegen/`，平台图标从同一母版导出。生成式素材的来源说明见 `docs/BRAND.md`；这不替代正式发行时的素材许可复核。没有使用 Netcatty 的代码、图标或品牌资源。

发行前仍需：确定项目 LICENSE、复核 Flutter engine／ICU／图标等内嵌资产声明与原生插件依赖、确认实际 ZIP 内的许可证齐全，并决定签名与分发方式。Windows 本地验证包不等于完成正式发行审计。
