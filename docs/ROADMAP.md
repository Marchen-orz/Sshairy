# 路线图

里程碑定义以 DESIGN §3 为准，检查编号见 TESTING。一项真正运行并通过后才能勾选；只有代码、没有运行过的不算完成。测试环境为作者的 Windows 11 和 Ubuntu 服务器（ADR-10）。

## 当前状态

| 项 | 状态 |
|---|---|
| 阶段 | M0 进行中；第一版可运行 |
| 工具链 | Flutter 3.47.9 stable（c197ca5199）、Dart 3.13.7、Visual Studio C++ 工具 |
| 已实际运行 | `integration_test/app_test.dart` 在 Windows 11 上连 Ubuntu 24.04 服务器，四个流程全过；Release 版能启动 |
| 下一步 | 作者亲测 E-04；补 E-05、E-12、E-01、E-02 和 P-01、P-02 |

第一版已实际运行的范围（不代表对应 M1 项完成，所以下面没有勾选）：快速连接、主机增删改、主机密钥未知/拒绝/变化、密码输入与记住、错误密码、多标签、关闭标签不影响其他会话、断线后重连、Ctrl+C（含有选区时）、多行粘贴确认、主题/语言/字号。

未测：私钥和加密私钥登录、keyboard-interactive、网络异常断线（只测了 `exit`）、窗口缩放时的远端尺寸更新、大量输出时的界面卡顿。

D-02 Windows 后端（已验证）：flutter_secure_storage_windows 4.2.2 把秘密写入 `%APPDATA%\dev.sshairy\sshairy\flutter_secure_storage.dat`，文件头是 DPAPI 密文，绑定当前 Windows 用户；凭据管理器里没有对应条目。集成测试断言数据目录的文件都不含密码明文。

## 待确认

- 许可证：用户已确认开源，MIT 只是建议；发布前确定。
- Netcatty 800 MB+ 的原因尚未核实，M0 按 P-01 在同机测一次。

## 第一版的简化

作者决定先做能运行的第一版，基本功能可用后再补齐。下列偏离 DESIGN、MODULES、CLAUDE.md 的地方是有意的：

- 不做 Capability 目录、CapabilityDispatcher 和命令面板，UI 直接调用 notifier；M1 加入能力目录时迁移。
- 主机密钥校验在 `Connector` 内用 `TrustStore` 完成，还没有独立的 HostTrustService；SFTP、转发、跳板出现前要抽出来。
- 每个 shell 独占一个 transport，没有连接池和租约；没有 foundation 的 Result、取消和脱敏日志。
- 终端输出同步解析，应用层没有流控；E-03 只证明库支持背压，T-03 仍未做。
- 主机只有名称、地址、端口、用户名和认证方式，没有分组和继承；密码在首次连接时输入并可选记住，表单里没有密码字段。
- 使用系统原生标题栏，工作区只有标签，没有左侧导航和分屏。

## M0 技术验证

- [x] 最小 Flutter 窗口（工程启用三个桌面平台，先在 Windows 运行）；记录 Flutter/Dart 精确版本；提交 lockfile
- [x] `analysis_options.yaml`、`tool/check_imports.dart`
- [x] 最小 SSH + 终端（不写持久化和正式 UI）
- [ ] E-03、E-04、E-08 通过（进入 M1 的硬门槛；E-04 待作者亲测）
- [ ] E-05、E-12 测量；E-01、E-02 顺带检查
- [ ] P-01、P-02 基线与 Netcatty 对照写入 TESTING §6
- [ ] dartssh2、xterm2 依赖批准表（版本、许可、维护、未解决问题）
- [ ] 依据结论修订 DESIGN §5 和相关专题，决定进入 M1 或替换候选

### M0 结论

| 实验 | 结果 | 结论 |
|---|---|---|
| E-03 背压 | 暂停读取后服务器停在 3136 KiB，恢复后 28 MiB 收全（`tool/m0_probe.dart`） | 通过；dartssh2 可用，应用层流控留给 T-03 |
| E-04 中文输入法 | 未开始 | 待作者用百度输入法亲测 |
| E-08 主机密钥 | 回调延迟 3 秒确认正常，rekey 期间不断流；拒绝后未发送认证数据，库报 `SSHAuthAbortError`；指纹与 OpenSSH 一致。应用内拒绝后不弹密码框、不写信任记录，密钥变化时不提供“仅本次” | 通过 |
| E-05 多会话内存 | 未开始 | |
| E-12 启动与帧耗时 | 未开始 | |
| E-01、E-02 顺带检查 | 未开始 | |

## M1 SSH 可用版

开始时：
- [ ] E-09、E-10、E-11 结果写入此处，必要时修订支持范围

基础：
- [ ] foundation：ID、Result、AppError、取消、脱敏日志
- [ ] design：tokens、Light/Dark、基础组件、i18n（zh、en）
- [ ] 窗口外壳与标签栏（E-11 结果决定标题栏方案）
- [ ] 配置存储：单写队列、revision、迁移、备份（D-01）
- [ ] ShutdownCoordinator

主机与凭据：
- [ ] 主机、分组、身份、继承解析（H-01）
- [ ] 持久化与坏数据恢复（H-02）
- [ ] 主机库：网格/列表、搜索、排序、置顶、最近连接、快速连接（H-03）
- [ ] SecretRef 与系统凭据存储，无明文降级（D-02）
- [ ] 密钥导入、引用与加密私钥（H-04）

连接：
- [ ] HostTrustService、trust 数据、确认对话框（C-01）
- [ ] 认证状态机、多因子、取消（C-02）
- [ ] ConnectionManager：池、合并拨号、租约、停泊（C-03）
- [ ] 保活、断线、手动与可选自动重连（C-04）

终端与外壳：
- [ ] TerminalSessionManager、model 与 view 分离、流控（T-03）
- [ ] 多标签、搜索、复制粘贴、字体、URL（T-01）
- [ ] 输入策略、IME、快捷键上下文（T-02）
- [ ] 标签生命周期（W-02 的 M1 部分）
- [ ] 设置定义、设置页（S-01）
- [ ] capabilities 最小目录、命令面板
- [ ] 键盘操作与视觉检查（U-01）
- [ ] P-01a/c/f、P-02 记录

## M2 文件工作流

开始时：
- [ ] E-06、E-07 结果写入此处，据此确定并发和 channel 策略

功能：
- [ ] SFTP 浏览：单栏与双栏共用组件、键盘操作（F-01）
- [ ] 文件操作：新建、重命名、删除、chmod（F-01）
- [ ] TransferManager：队列、并发、进度、取消、从头重试（F-03）
- [ ] .part 发布、大小校验、冲突处理（F-02）
- [ ] 目录传输：扫描上限、逐项冲突
- [ ] OS 拖入上传
- [ ] 外部编辑：临时副本、watcher、冲突、恢复（F-05）
- [ ] 传输历史
- [ ] P-01a/c/e/f、P-03 记录

## M3 桌面主力版

- [ ] 分屏树与焦点（W-01）
- [ ] 布局恢复（W-02 的 M3 部分）
- [ ] 跳板链、SOCKS5/HTTP 代理、legacy 按主机启用（C-01、C-04 的 M3 部分）
- [ ] 端口转发 L/R/D 与规则管理（R-01、R-02、R-03）
- [ ] 片段
- [ ] SSH config 导入：draft 预览与未支持项报告
- [ ] known_hosts 导入
- [ ] 密钥生成
- [ ] 暂停与断点续传（F-04）
- [ ] 10 GB 传输（P-03）
- [ ] README 写明已测环境和无保障声明
- [ ] 确定 LICENSE；审计依赖、字体、图标许可
- [ ] Windows 打包；其他平台有需要时再做

## M4 AI 首版

- [ ] 复核供应商文档，确定首批模型协议
- [ ] SSE parser 与 ModelProvider：Anthropic Messages、OpenAI 兼容（A-01）
- [ ] AgentRuntime 状态机、唯一 Stop 入口（A-02）
- [ ] 工具 allowlist、审批卡片、Confirm 模式（A-03）
- [ ] CommandExecutor：独立 exec、可见执行记录、shell adapter
- [ ] ContextManager、压缩、OutputStore
- [ ] 重试与 operationId（A-04）
- [ ] 设置与布局能力、撤销（A-05）
- [ ] 对话持久化与脱敏
- [ ] 侧边面板、引用选中输出、命令面板入口
- [ ] P-01g 记录

## M5 按反馈扩展

不预先排期，用户需求或反馈确认后才开始。候选：本地 PTY、ssh-agent、证书、公钥分发、应用锁、广播输入、关键词高亮、服务器监控、远程到远程复制、加密可移植备份、AI 远程文件写入与自动模式。

## 交接记录

接手时读这里，结束时追加一行。

| 日期 | 执行者 | 完成 | 下一步与注意事项 |
|---|---|---|---|
| 2026-11-05 | Claude Opus 5.5 / GPT-6-Astra | 深读 Netcatty 0e3f282，完成设计文档 v0.2 | 从 M0 开始；先做 E-03、E-04、E-08，它们会决定候选库是否可用 |
| 2026-11-05 | Claude Opus 5.5 | 按用户意见收窄 M0（ADR-09）：E-09、E-10、E-11 移到 M1 开始时，E-06、E-07 移到 M2 开始时，E-01、E-02 改为顺带检查 | 同上 |
| 2026-11-06 | Claude Opus 5.5 | 按用户决定只在真实环境测试（ADR-10）：TESTING 重写，取消 Docker、fixture、CI 矩阵和三端门槛 | 服务器按 TESTING §2 使用，需要连接时向用户要凭证 |
| 2026-11-06 | Claude Opus 5.5 | 第一版可运行：主机库、标签工作区、设置、i18n、单元测试和真实服务器集成测试；E-03、E-08 通过 | 先看“第一版的简化”；集成测试的用法在 `integration_test/app_test.dart` 开头，凭据只走环境变量；E-04 等作者结果 |
