# sshairy

Lightweight SSH. Powered by AI. Flutter 桌面 SSH 客户端（Win/macOS/Linux），开源，主要供作者自用，不提供兼容性和可用性保障；许可证发布前确定（建议 MIT）。

开始工作前先读 `docs/DESIGN.md` 和 `docs/ROADMAP.md`，再按任务读专题：`MODULES`（功能）、`CONTRACTS`（API 与资源）、`SECURITY`（凭据与存储）、`UI`（界面）、`AI`（M4）、`TESTING`（测试）、`NETCATTY_REVIEW`（参考依据）。完成后更新 ROADMAP 的勾选和交接记录。

## 不可违反的规则
1. 业务变更走 typed 用例；主机、连接、传输、持久化设置、布局命令按需登记为 Capability，命令面板和 AI 经 CapabilityDispatcher 调用。不把 UI 瞬时状态和终端按键做成 JSON 动作。
2. 跨 feature 只 import 对方的 `api.dart`；禁止循环依赖；`domain/` 不 import Flutter、Riverpod、IO 和第三方库。
3. 第三方库（dartssh2、xterm2、flutter_pty、flutter_secure_storage 等）限定在 `adapters/` 或 `platform/`，类型不外泄。
4. 所有连接路径（含跳板、SFTP、转发、AI）都经 HostTrustService，认证前完成校验；密钥变化默认阻断。
5. 秘密只存系统安全存储，业务对象只放 SecretRef；无明文降级；不进日志，不发给 AI。
6. AI 不得获得 SECURITY §6 列出的权限；授权由确定性代码判断，不依赖 prompt 或关键词黑名单。
7. UI 只用 `lib/design/` 的 tokens 与组件；靠布局表达含义，不加多余的标题和说明文字。
8. 用户可见文案走 i18n（zh、en）。
9. 不复制 Netcatty（GPL-3.0）的代码和品牌素材，只参考设计。
10. 测试在作者的 Windows 和 Ubuntu 服务器上进行，遵守 `docs/TESTING.md` §2：需要时向作者要凭证，凭证不写入任何文件，不影响服务器现有服务。
11. 设计变更先改 `docs/`，再改代码；待验证项不写成事实，未运行的测试不写成通过。

## 命令
- `flutter run -d windows`
- `flutter test`
- `flutter analyze`
- `dart run tool/check_imports.dart`（M0 建立）
