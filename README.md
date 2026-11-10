# sshairy

Lightweight SSH. Powered by AI.

基于 Flutter 的桌面 SSH 客户端，提供侧栏 Agent、行内命令生成与 AI 提示补全。Agent 根据任务自行选择回答、固定诊断或提出命令，执行前逐次确认。AI 默认关闭，真实模型和服务器闭环仍待实测；完整目标与完成范围见 [ROADMAP](docs/ROADMAP.md)。

主要供作者自用，处于开发阶段，不提供兼容性、可用性或数据恢复保障。目标平台为 Windows、macOS、Linux；目前只在作者的 Windows 11 和 Ubuntu 24.04 服务器上实际测试，macOS 和 Linux 桌面尚未验证。

- 主机库：分组、标签、搜索、置顶、最近连接；密码与密钥认证，导入与生成 Ed25519 密钥。
- 终端：多标签、分屏、搜索、复制粘贴、重连、布局恢复；关闭标签不会关闭其他通道。
- 文件：双栏 SFTP、终端侧栏、上传下载、队列、冲突处理、外部编辑。
- 片段：搜索、标签、编辑与持久化；插入焦点终端或确认后运行，断线重连使旧确认失效。
- 外观：六套浅深品牌主题、界面缩放与独立背景图片。Windows 默认 Skia，可在设置中切换 Impeller，重启生效。
- 连接扩展：跳板链、SOCKS5／HTTP CONNECT 代理、按主机启用旧版算法。实际验证范围见 [ROADMAP](docs/ROADMAP.md)。
- AI：设置中配置 Anthropic Messages 或 OpenAI-compatible Chat Completions；导航或 Ctrl/Cmd+Shift+A 打开 Agent，选择主机后由 Agent 决定步骤。行内生成与自动补全分别开启，命令先预览或填入，按 Enter 才执行；Agent 命令逐次批准，执行输出另选发送。

密码与私钥只存系统安全存储。连接先检查主机密钥，变化时默认阻断；不修改系统 SSH 配置或 `known_hosts`。

## 开发

当前工具链：Flutter 3.47.9 stable、Dart 3.13.7。Windows 需要 Visual Studio 的 C++ 桌面开发工具。

```sh
flutter pub get
flutter run -d windows
```

```sh
flutter analyze
dart run tool/check_imports.dart
flutter test
```

服务器集成测试的配置见 [integration_test/app_test.dart](integration_test/app_test.dart)，凭据只通过环境变量传入。测试必须遵守 [TESTING §2](docs/TESTING.md)：文件操作限于 `~/sshairy-test/`，不得影响已有服务；没有实际运行的场景不得当作已通过。

## Windows 本地打包

在可执行 `flutter`、`dart` 的 PowerShell 中运行：

```powershell
./tool/package_windows.ps1
```

输出在 `dist/`：完整运行目录、ZIP 和 SHA256 校验文件。已有 Release 构建可加 `-SkipBuild`。必须分发整个目录，不能只复制 EXE；包未签名，没有安装器或自动更新。脚本保留依赖许可证，缺失时会终止打包。

## 扩展

采用按功能划分的模块化单体；跨模块仅通过 `api.dart`，第三方库封装在适配层，连接、终端和传输分别持有自己的资源。业务行为通过 typed 用例，命令面板经 `CapabilityDispatcher` 调用；新能力默认不向 AI 暴露。

首批 Agent 经同一调度器调用审核过的能力，绑定实际连接身份并在执行前重验。行内生成和补全共用无工具的模型端口，各自限制发送范围和请求寿命。后续按工具扩展 Capability 和窄端口，无需重写 SSH/SFTP 核心；凭据与信任授权始终由确定性代码控制，完整应用/多机工具继续按阶段推进。设计入口：[DESIGN](docs/DESIGN.md)、[CONTRACTS](docs/CONTRACTS.md)、[SECURITY](docs/SECURITY.md)、[AI](docs/AI.md)。

学习 AI Agent 可从 [项目导读](docs/AI_AGENT_GUIDE.md) 开始：当前功能、任务循环、工具调用、权限与数据发送边界，以及源码阅读路线和练习。

## 许可证

计划开源，项目许可证尚未确定，当前不声明 MIT 授权。发行前还需完成许可证选择与完整依赖审计。第三方组件保留各自许可，说明见 [DEPENDENCIES](docs/DEPENDENCIES.md)。

界面使用作者提供的六套品牌主题（冰蓝薄荷、薄荷绿、紫罗兰、日落橙、深海蓝、樱花粉），每套都有浅色、深色和对应 Logo；在设置的“配色方案”中切换。来源、资源导入和图标说明见 [BRAND](docs/BRAND.md)。只参考 Netcatty 的产品设计，未采用其 GPL 代码或品牌素材。
