# 路线图

里程碑定义以 DESIGN §3 为准，检查编号见 TESTING。一项真正运行并通过后才能勾选；只有代码、没有运行过的不算完成。测试环境为作者的 Windows 11 和 Ubuntu 服务器（ADR-10）。

## 当前状态

| 项 | 状态 |
|---|---|
| 阶段 | M0 进行中；第一版可运行；M2 文件工作流已有主体 |
| 工具链 | Flutter 3.47.9 stable（c197ca5199）、Dart 3.13.7、Visual Studio C++ 工具 |
| 已实际运行 | `integration_test/app_test.dart` 在 Windows 11 上连 Ubuntu 24.04 服务器，七个流程全过（含终端搜索、断线自动重连、标签重命名和复制、删除信任记录、SFTP 与传输）；Release 版能启动 |
| 下一步 | M3；作者亲测 E-04、外部编辑（F-05）、OS 拖入和关窗确认；补 E-05、E-06、E-12、E-01、E-02 和 P-01、P-02 |

第一版已实际运行的范围（不代表对应 M1 项完成，所以下面没有勾选）：快速连接、主机增删改、主机密钥未知/拒绝/变化、密码输入与记住、错误密码、多标签、关闭标签不影响其他会话、断线后重连、Ctrl+C（含有选区时）、多行粘贴确认、主题/语言/字号/主题色、命令面板打开主机与执行动作、同主机分屏、Alt+方向键切换焦点、关闭分屏、重启后恢复为未连接标签、终端搜索（计数、上下跳转、无结果）、服务端结束会话后自动重连、标签右键重命名、命令面板复制标签（共享连接不再要密码）、设置里删除信任记录。

未测：私钥和加密私钥登录、keyboard-interactive、真实网络中断（只测了服务端结束会话）、窗口缩放时的远端尺寸更新、大量输出时的界面卡顿、链接打开、右键菜单、选中复制、光标形状、未读标记。

D-02 Windows 后端（已验证）：flutter_secure_storage_windows 4.2.2 把秘密写入 `%APPDATA%\dev.sshairy\sshairy\flutter_secure_storage.dat`，文件头是 DPAPI 密文，绑定当前 Windows 用户；凭据管理器里没有对应条目。集成测试断言数据目录的文件都不含密码明文。

## 待确认

- 许可证：用户已确认开源，MIT 只是建议；发布前确定。
- Netcatty 800 MB+ 的原因尚未核实，M0 按 P-01 在同机测一次。

## 第一版的简化

作者决定先做能运行的第一版，基本功能可用后再补齐。下列偏离 DESIGN、MODULES、CLAUDE.md 的地方是有意的：

- Capability 目录有 host.list/create/update/delete、session.open/close/reconnect、workspace.split/focus（可带 view: files）/renameTab/duplicateTab、settings.get/patch（schema 由 SettingDef 生成）、file.list/stat/mkdir/rename/delete、transfer.list/enqueue/cancel/retry（都不开放给 AI）；还没有 revision、审批和审计。界面按钮仍直接调用 notifier，命令面板经 dispatcher。
- ConnectionManager 在拨号前解析不可变的完整跳板链，池 key 包含每跳主机 ID、端点、用户名、认证方式、密钥引用、代理和算法策略；还没有凭据/信任 revision。停泊时长、连接超时和保活取自设置。没有脱敏日志。
- 终端输出同步解析，应用层没有流控；E-03 只证明库支持背压，T-03 仍未做。
- 主机有分组路径、标签、置顶和最近连接，没有 Group 对象、继承和 Identity；密码在首次连接时输入并可选记住，表单里没有密码字段。
- 左侧导航尚未完整实现；Windows 正按用户新要求改为自绘标题栏（ADR-12），详见 CORRECTION。

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
| E-04 中文输入法 | 候选框跟随光标：作者用百度输入法确认正常（1944056），集成测试检查 IME 位置 | 选词、退格、标点等其余项未单独确认 |
| E-08 主机密钥 | 回调延迟 3 秒确认正常，rekey 期间不断流；拒绝后未发送认证数据，库报 `SSHAuthAbortError`；指纹与 OpenSSH 一致。应用内拒绝后不弹密码框、不写信任记录，密钥变化时不提供“仅本次” | 通过 |
| E-05 多会话内存 | 未开始 | |
| E-12 启动与帧耗时 | 空闲内存已测（TESTING §6）：Impeller 下 240–300 MB，大头是渲染缓冲 | 改为默认 Skia（ADR-11），Release 空闲约 90–140 MB；启动和帧耗时未测 |
| E-01、E-02 顺带检查 | 未开始 | |

## M1 SSH 可用版

开始时：
- [ ] E-09、E-10、E-11 结果写入此处，必要时修订支持范围

基础：
- [ ] foundation：ID、Result、AppError、取消、脱敏日志
- [ ] design：tokens、Light/Dark、基础组件、i18n（zh、en）
- [ ] 窗口外壳与标签栏（E-11 结果决定标题栏方案）
- [ ] 配置存储：单写队列、revision、迁移、备份（D-01）：单写队列、读回验证、revision/expectedRevision、损坏与未来版本的类型化错误和写保护、快照（最近 10 份、5 分钟间隔、50 MiB）、损坏文件经校验快照恢复有单元测试（`test/json_file_test.dart`）；各配置文件的领域校验回调已接入，启动时读取失败显示保留原文件的修复页（`lib/app/configuration.dart`）。迁移框架、恢复界面和多实例防护未做，见 SECURITY §4“当前实现”
- [ ] ShutdownCoordinator：有传输或未上传的编辑时先确认（`app/shutdown.dart`），集成测试经 `handleRequestAppExit` 确认对话框和“取消”；点窗口关闭按钮是否走到这里未亲测：活动转发也计入确认；停止或保存失败时提供重试/返回/仍要退出，不冒充已完成（`test/app_lifecycle_test.dart`）；取消退出后队列恢复接收新任务

主机与凭据：
- [ ] 主机、分组、身份、继承解析（H-01）
- [ ] 持久化与坏数据恢复（H-02）
- [ ] 主机库：网格/列表、搜索、排序、置顶、最近连接、快速连接（H-03）：分组筛选、按标签搜索、置顶、列表视图已在集成测试中确认；拖拽排序未做
- [ ] SecretRef 与系统凭据存储，无明文降级（D-02）
- [ ] 密钥导入、引用与加密私钥（H-04）：导入 ssh-keygen 生成的 Ed25519/RSA/ECDSA 加密私钥、指纹与 ssh-keygen 一致有单元测试；用导入的密钥登录服务器未测（需要改服务器的 authorized_keys，按 TESTING §2 先问作者）

连接：
- [ ] HostTrustService、trust 数据、确认对话框（C-01）：已独立为 HostTrustService，所有拨号经它校验
- [ ] 认证状态机、多因子、取消（C-02）
- [ ] ConnectionManager：池、合并拨号、租约、停泊（C-03）：分屏和断开后重连复用连接已在服务器上确认；60s 停泊和不同用户不复用只有单元测试
- [ ] 保活、断线、手动与可选自动重连（C-04）：自动重连在服务端结束会话时已确认；保活和真实断网未测

终端与外壳：
- [ ] TerminalSessionManager、model 与 view 分离、流控（T-03）
- [ ] 多标签、搜索、复制粘贴、字体、URL（T-01）：搜索、重命名、复制标签已在服务器上确认；URL 只有单元测试
- [ ] 输入策略、IME、快捷键上下文（T-02）
- [ ] 标签生命周期（W-02 的 M1 部分）
- [ ] 设置定义、设置页（S-01）：SettingDef 与全有或全无的 patch 有单元测试；其他 feature 经 SettingsSection 加分区
- [ ] capabilities 最小目录、命令面板
- [ ] 键盘操作与视觉检查（U-01）
- [ ] P-01a/c/f、P-02 记录

## M2 文件工作流

开始时：
- [ ] E-06、E-07 结果写入此处，据此确定并发和 channel 策略：E-07 通过（上传中取消，终端照常、远端不留 `.part`）；E-06 未做，大小待作者定。当前策略见 MODULES §4“当前实现”

功能：
- [ ] SFTP 浏览：单栏与双栏共用组件、键盘操作（F-01）：终端侧栏和双栏页、中文和带空格的名字、Enter/F2/Delete 已在服务器上确认；方向键、按名跳转、Ctrl+A 未测
- [x] 文件操作：新建、重命名、删除、chmod（F-01）：集成测试在服务器上逐项核对，删除指向目录的符号链接只删链接
- [ ] TransferManager：队列、并发、进度、取消、从头重试（F-03）：进度和取消在服务器上确认；并发上限和重试只有单元测试；“关闭面板不取消任务”未测
- [x] .part 发布、大小校验、冲突处理（F-02）：上传下载哈希一致、取消不留 `.part`、同名“保留两者”在服务器上确认；替换、合并、跳过和“本批都这样”只有单元测试
- [ ] 目录传输：扫描上限、逐项冲突：下载含中文名的目录在服务器上确认；上限和逐项冲突只有单元测试
- [ ] OS 拖入上传：已实现（desktop_drop），未测
- [ ] 外部编辑：临时副本、watcher、冲突、恢复（F-05）：已实现，未运行；需要作者用自己的编辑器试
- [ ] 传输历史：保存、重启后进行中的变为“已中断”、200 条/30 天裁剪只有单元测试
- [ ] P-01a/c/e/f、P-03 记录

## M3 桌面主力版

- [x] 分屏树与焦点（W-01）：`test/layout_test.dart`
- [x] 布局恢复（W-02 的 M3 部分）：workspace.json 只存布局、主机 ID 和标签名；重启后恢复为未连接，不自己拨号；`test/workspace_test.dart` 通过，服务器集成测试 `workspace: palette, split panes, restore after restart` 此前通过，之后的改动没有重跑
- [ ] 跳板链、SOCKS5/HTTP 代理、legacy 按主机启用（C-01、C-04 的 M3 部分）：路由已实现；`integration_test/routes_test.dart` 在 Windows/Ubuntu 通过双跳（服务器自身 loopback）、每跳校验、共享跳板、direct-tcpip 和远端转发取消；循环/缺失/链上限/改跳板后不复用与 RSA 信任别名有单元测试。代理和 legacy 没有对应真实环境，未验证
- [ ] 端口转发 L/R/D 与规则管理（R-01、R-02、R-03）：L/R/D、SOCKS5、规则面板、暴露确认、退出收束和单元测试（`test/forwarding_test.dart`，模拟通道）已实现并接入工具栏与命令面板；真实服务器上的通路、端口冲突和界面行为未验证
- [ ] Windows 无系统顶栏的自绘窗口（ADR-12）：原生保留缩放/DPI/Snap 语义，Flutter 绘制标签行与窗口按钮，关闭经统一退出协调；组件与命中区有单元测试（`test/desktop_window_test.dart`），原生 C++ 已编译通过；拖动、Snap、DPI 切换与真实 WM_CLOSE 取消未在运行中的窗口亲测；macOS/Linux 仍用系统外框
- [x] 片段：搜索与增删改、持久化、插入/运行、命令面板入口；Windows 无连接界面集成通过，受控插入与 shell 生命周期用模拟通道验证，真实 SSH 片段发送未测
- [ ] SSH config 导入：draft 预览与未支持项报告：解析、计划（跳板依赖、已存在与冲突分类）和 revision 校验提交有单元测试（`test/ssh_config_test.dart`）；文件选择器、Include 展开和抽屉界面未在真实窗口运行
- [x] known_hosts 导入：解析、哈希匹配（对照 `ssh-keygen -H` 的输出）、冲突不覆盖、串行落盘和预览对话框有单元/组件测试；文件选择器和真实窗口未运行
- [ ] 密钥生成：Ed25519，ssh-keygen 能读出同样的公钥和指纹；登录未测
- [ ] 暂停与断点续传（F-04）：单文件暂停/续传、checkpoint 持久化与重启恢复、源与 `.part` 校验、取消/重试清理、目标锁有单元测试（`test/files_test.dart`，全部走本机文件系统）；传输面板的暂停/继续按钮和 `transfer.pause`/`transfer.resume` 能力已接线。真实服务器上的 SFTP 续传、哈希一致性与大文件暂停未验证
- [ ] 10 GB 传输（P-03）
- [x] README 写明已测环境和无保障声明
- [ ] 确定 LICENSE；审计依赖、字体、图标许可
- [x] Windows 本地打包：Release 构建、完整 runner ZIP、101 个依赖许可证清单和 SHA256 已验证；未签名，正式发行仍待许可证确认。其他平台未验证

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
| 2026-11-06 | Claude Opus 5.5 | 查明内存大头是 Impeller 的渲染缓冲；Windows 默认 Skia，设置里可切 Impeller（ADR-11），runner 启动前读 settings.json | 多会话内存（E-05、P-01）仍未测；升级 Flutter 时复测两种渲染器 |
| 2026-11-06 | Claude Opus 5.5 | 蓝色默认主题色与可选色、终端配色随明暗、应用图标；foundation 的 ID/Result/取消；Capability 目录、dispatcher、命令面板（Ctrl+Shift+P）；分屏树、窗格焦点、布局与当前标签恢复 | 窗格焦点以布局为准，对话框还回的焦点会被送回；workspace.json 在 Provider 构建后才建会话（Riverpod 不允许构建中改别的 provider） |
| 2026-11-06 | Claude Opus 5.5 | ConnectionManager（池、合并拨号、租约、停泊、复用失败重建一次）与 HostTrustService；终端经租约开 shell | 退出 shell 后 60s 内重连和同主机新标签不再要密码；集成测试已按此修改 |
| 2026-11-06 | Claude Opus 5.5 | 终端搜索、链接、右键菜单、选中复制、光标形状；自动重连（1/2/4/8/16s）；标签重命名、复制、未读标记；SettingDef 设置定义与分区化设置页；信任记录管理 | 未读标记要在帧后改（构建中通知会断言）；对话框里的 TextEditingController 由对话框自己持有（`design/text_prompt.dart`） |
| 2026-11-06 | Claude Opus 5.5 | 主机分组路径、标签、置顶、最近连接、网格/列表、排序；密钥库（导入、生成、复制公钥、按主机引用）；host.* 能力加分组/标签/置顶/keyId，新增 key.list、key.generate | dartssh2 现在也允许出现在 `credentials/adapters`（解析和生成密钥）；单元测试用系统 ssh-keygen 作格式参照，没有时跳过 |
| 2026-11-06 | Claude Opus 5.5 | M2 主体：foundation 的 FileSystem（SFTP 与本机两个实现）、FileSystems 每主机共享一条 SFTP、双栏 SFTP 页和终端侧栏、TransferManager（.part 发布、冲突、目录、看门狗、历史）、外部编辑、file.*/transfer.* 能力、设置里的文件分区、关窗确认 | 集成测试的文件流程只在 `~/sshairy-test/` 内，结束时删除；传输结束会刷新正在显示目标目录的栏；dartssh2 的 rename 在服务器支持 posix-rename 时会覆盖，所以 SftpFileSystem.rename 先 stat 目标 |
| 2026-11-06 | 开发助手 | M3 路由：完整跳板链快照与池键、SOCKS5/HTTP CONNECT 适配、按主机 legacy、RSA 信任别名；主机变更串行且落盘后发布，置顶/最近时间不覆盖新配置或复活已删主机。70 项单元测试通过，flutter analyze 无问题，imports ok；此前 Windows/Ubuntu 双跳与远端转发取消集成通过 | 代理/legacy 无真实环境，未验证；转发只有领域模型，片段和导入未实现；打包脚本未运行。配置 revision/备份仍欠缺 |
| 2026-11-06 | 开发助手 | 片段搜索、增删改、串行持久化与命令面板入口；与剪贴板共用受控插入，运行/控制字符确认绑定原 shell。Windows 无连接 CRUD/重启恢复集成通过，79 项单元测试通过，flutter analyze 无问题，imports ok | 真实 SSH 片段发送未测；SSH config、known_hosts 导入与转发规则管理继续实施 |
| 2026-11-06 | 开发助手 | Windows 本地打包（Release、ZIP、101 个依赖许可证清单、SHA256，已核对 ZIP 内容）；片段确认窗口随取消、断线、关闭而关闭；`tool/check_imports.dart` 增加 feature 循环依赖与 `package:sshairy/` 绕过检测 | 包未签名；许可证未定，不宣称 MIT。其他平台未打包 |
| 2026-11-06 | 开发助手 | known_hosts 导入（预览、冲突报告、哈希名只匹配已保存主机）；HostTrustService 的信任、遗忘、导入改为串行并先落盘后发布。110 项单元测试通过，flutter analyze 无问题，imports ok | 文件选择器与窗口里的导入流程未实际运行；`@revoked` 只计数 |
| 2026-11-06 | 开发助手 | 纠偏（capability 登记移到 app/、凭据 API 收窄、池键加 securityRevision、JsonFile 保护、统一退出、启动配置门）；SSH config 导入（解析、计划、提交，9 项单元测试）；转发规则面板；片段编辑改抽屉。F-04 单文件暂停/续传（checkpoint、恢复校验、清理、目标锁，`test/files_test.dart`）。200 项单元测试通过，analyze 与 imports 干净 | 无边框窗口（ADR-12）、新图标、冰蓝配色已实现但未在真实窗口亲测；暂停/续传未经真实服务器验证（SFTP 侧 `append` 已实现，本机 `FileMode.append` 修正过截断问题）；全部未提交 |
