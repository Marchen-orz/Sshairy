# 路线图

里程碑定义以 DESIGN §3 为准，检查编号见 TESTING。一项真正运行并通过后才能勾选；只有代码、没有运行过的不算完成。测试环境为作者的 Windows 11 和 Ubuntu 服务器（ADR-10）。

## 当前状态

| 项 | 状态 |
|---|---|
| 阶段 | M1–M3 已有主要实现；M0 技术验收与一期验收未收齐，非 AI 功能尚未全部完成 |
| 工具链 | Flutter 3.47.9 stable（c197ca5199）、Dart 3.13.7、Visual Studio C++ 工具 |
| 已实际运行 | 2026-11-07 在 Windows 11 上连作者的 Ubuntu 服务器逐个跑集成测试，全部通过：`app_test`（8 个流程，含 T-03 持续输出）、`auth_test`、`routes_test`、`snippets_test`（不连服务器）、`keys_test`（文件/导入/加密密钥登录，临时公钥已移除）、`forward_test`（L/R/D）、`transfer_test`（往返哈希、暂停续传、退出后恢复、256 MiB/10 GiB 稀疏文件 30 秒取消、1 万条目录）、`edits_test`（外部编辑 app 一侧）；`memory_test` 在 Profile 构建下通过。数字见 TESTING §6；Release 版能启动 |
| 下一步 | 作者验收新界面（图标栏、浮层、快速连接、监控面板、文件停靠、字体与字号）和关闭确认；真实环境还差：keyboard-interactive（服务器关闭）、窗口拖动/Snap/DPI/最小化、真实输入法、作者自己的外部编辑器、10 GB 传输、Release 构建的任务管理器内存口径 |

第一版已实际运行的范围（不代表对应 M1 项完成，所以下面没有勾选）：快速连接、主机增删改、主机密钥未知/拒绝/变化、密码输入与记住、错误密码、多标签、关闭标签不影响其他会话、断线后重连、Ctrl+C（含有选区时）、多行粘贴确认、主题/语言/字号/主题色、命令面板打开主机与执行动作、同主机分屏、Alt+方向键切换焦点、关闭分屏、重启后恢复为未连接标签、终端搜索（计数、上下跳转、无结果）、服务端结束会话后自动重连、标签右键重命名、命令面板复制标签（共享连接不再要密码）、设置里删除信任记录。

未测：keyboard-interactive（服务器关闭了该认证方式）、真实网络中断（只测了服务端结束会话）、窗口缩放时的远端尺寸更新、大量输出时的界面卡顿（只测了内存和事件循环停顿，没有测帧率）、链接打开、右键菜单、选中复制、光标形状、窗口最小化、真实输入法、作者自己的外部编辑器。

D-02 Windows 后端（已验证）：flutter_secure_storage_windows 4.2.2 把秘密写入 `%APPDATA%\dev.sshairy\sshairy\flutter_secure_storage.dat`，文件头是 DPAPI 密文，绑定当前 Windows 用户；凭据管理器里没有对应条目。集成测试断言数据目录的文件都不含密码明文。

## 待确认

- 许可证：用户已确认开源，MIT 只是建议；发布前确定。
- Netcatty 800 MB+ 的原因尚未核实，M0 按 P-01 在同机测一次。

## 第一版的简化

作者决定先做能运行的第一版，基本功能可用后再补齐。下列偏离 DESIGN、MODULES、CLAUDE.md 的地方是有意的：

- Capability 目录有 host.list/create/update/delete、session.open/close/reconnect、workspace.split/focus（可带 view: files）/renameTab/duplicateTab、settings.get/patch（schema 由 SettingDef 生成）、file.list/stat/mkdir/rename/delete、transfer.list/enqueue/cancel/retry（都不开放给 AI）；还没有 revision、审批和审计。界面按钮仍直接调用 notifier，命令面板经 dispatcher。
- ConnectionManager 在拨号前解析不可变的完整跳板链，池 key 包含每跳主机 ID、端点、用户名、认证方式、密钥引用、代理和算法策略，以及凭据/信任 revision（上轮纠偏已补）。停泊时长、连接超时和保活取自设置。脱敏日志尚未实现。
- 终端输出同步解析，应用层没有流控；E-03 只证明库支持背压，T-03 仍未做。
- 主机有分组路径、标签、置顶和最近连接，没有 Group 对象、继承和 Identity；密码在首次连接时输入并可选记住，表单里没有密码字段。
- 左侧导航尚未完整实现；Windows 自绘标题栏（ADR-12）已实现并编译启动，完整交互未验收，详见 CORRECTION。本轮设计复核与未修复缺陷见 DESIGN_AUDIT。

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
| E-05 多会话内存 | Profile 构建、5 个会话（回滚满）加 SFTP 面板：RSS 约 220 MiB，四轮全部关闭再重开为 223 / 220 / 235 / 227 MiB，不持续增长；每轮关闭后 5 个终端全部可回收（`integration_test/memory_test.dart`） | 总 RSS 含测试驱动，不是任务管理器的私有工作集；没有 Release 数据，没有 Netcatty 对照；发现并修复了两个缺陷（关闭的会话被连接持有、关标签不挂断远端 shell） |
| E-12 启动与帧耗时 | 空闲内存已测（TESTING §6）：Impeller 下 240–300 MB，大头是渲染缓冲 | 改为默认 Skia（ADR-11），Release 空闲约 90–140 MB；启动和帧耗时未测 |
| E-01、E-02 顺带检查 | 未开始 | |

## M1 SSH 可用版

开始时：
- [ ] E-09、E-10、E-11 结果写入此处，必要时修订支持范围

基础：
- [ ] foundation：ID、Result、AppError、取消、脱敏日志
- [ ] design：tokens、Light/Dark、基础组件、i18n（zh、en）
- [x] 六套品牌主题（2026-11-07）：素材包的冰蓝薄荷/薄荷绿/紫罗兰/日落橙/深海蓝/樱花粉，独立浅深模式、主题预览卡、对应 Logo 和空状态装饰；旧 `accent` 值兼容，命令面板沿用 `settings.patch`。十二种组合已渲染检查，`test/brand_theme_test.dart` 覆盖配色、对比度、终端选区、旧配置读取、持久化、键盘选择和 18 px 中文布局；Windows/macOS 静态安装图标采用默认冰蓝薄荷，macOS 运行未验证
- [x] 品牌与导航追调（2026-11-07）：冰蓝薄荷浅色界面主色换为湖青 `#46B7C8`；Windows 运行窗口图标随六主题与有效浅深模式切换；导航可在 48/240 px 间展开收起，展开显示完整菜单名和关于页同款横版 Logo。最大化客户区排除屏幕外的隐形边框，顶栏改为 44 px 并留出上下空间；在作者 Windows 200% 缩放下实测客户区边界、最大化/还原、Logo 和按钮位置，12 个原生图标图像各不相同，详见 TESTING §6
- [x] 导航拖宽与品牌装饰（2026-11-07）：展开导航默认 200，拖动分隔线在 176–320 间调整（导线、松开提交、双击恢复、方向键），Logo 随宽度缩小；装饰改为半透明——主机库空状态角色配淡云/风线/星光，主机少时右下角淡角色水印（列表碰不到才显示），密钥/转发/片段/传输的空列表用对应动作小图。`test/workspace_layout_test.dart` 覆盖拖动限宽、键盘、双击、浮层避让、水印出现与隐藏和空列表动作；六主题浅深预览检查过主机库、浮层和传输浮层，见 TESTING §6
- [x] 主机库动作轮换（2026-11-07）：空状态与水印在默认、开心、成功、疾速、睡在云上之间随机，每次回到主机库立即换一个（不淡出没人看见的旧图），停留时每 45 秒预解码后以 1.2 秒淡入淡出切换；主机库不可见时不计时，减少动态效果时只在显示时随机。思考（AI）动作留给 AI。`test/brand_theme_test.dart` 覆盖轮换、隐藏不换、返回即换、减少动态效果与全部动作资源存在；真实窗口淡入淡出未截图检查
- [x] 强调色、窗口按钮与退出（2026-11-07）：冰蓝薄荷浅色主色由湖青改为在原始 `#2E6EF7` 上微调的 `#2C71E8`，填充按钮用该色配白字；最小化/最大化/关闭为 36×28 圆角悬浮，间距 2，关闭右侧留 8。确认退出后窗口先隐藏，取消、保存和断开在窗口消失后进行，失败时窗口重新出现；Windows runner 在消息循环结束后也先隐藏窗口再拆引擎。顺序有 widget 测试（`test/app_lifecycle_test.dart`），实测见 TESTING §6
- [x] 传输下拉浮层（2026-11-07）：从顶栏传输按钮下方展开，宽 440 px、最高 520 px，小窗口内收缩并滚动；Esc/点外部关闭不取消任务。队列操作及边界布局有 widget 回归测试，真实窗口空队列布局已检查
- [ ] 窗口外壳与标签栏（E-11 结果决定标题栏方案）
- [ ] 配置存储：单写队列、revision、迁移、备份（D-01）：单写队列、读回验证、revision/expectedRevision、损坏与未来版本的类型化错误和写保护、快照（最近 10 份、5 分钟间隔、50 MiB）、损坏文件经校验快照恢复有单元测试（`test/json_file_test.dart`）；各配置文件的领域校验回调已接入，启动时读取失败显示保留原文件的修复页（`lib/app/configuration.dart`）。逐版迁移、启动恢复入口和跨进程写锁已实现并有测试（`test/json_file_test.dart`、`test/configuration_recovery_test.dart`），恢复页未在真实窗口运行，见 SECURITY §4“当前实现”和 CONFIG_RECOVERY
- [ ] ShutdownCoordinator：有传输或未上传的编辑时先确认（`app/shutdown.dart`），集成测试经 `handleRequestAppExit` 确认对话框和“取消”；点窗口关闭按钮是否走到这里未亲测：活动转发也计入确认；停止或保存失败时提供重试/返回/仍要退出，不冒充已完成（`test/app_lifecycle_test.dart`）；取消退出后队列恢复接收新任务

主机与凭据：
- [x] 主机、分组、身份、继承解析（H-01）：独立 Group/Identity/全局默认值、schema 1→2 迁移、三态继承解析与来源、串行编辑与密钥引用检查有单元测试；主机/组/全局默认值/身份/主机库的编辑界面有 widget 测试（`test/host_editor_test.dart`）；group/identity/hostDefaults 与 host 能力有测试（`test/host_capabilities_test.dart`），均不对 AI 开放。真实服务器（2026-11-07）上验证了：服务器拒绝密钥后回落到密码（key→password）、只配密钥时认证失败且不索要密码、仅密码且关闭 keyboard-interactive 登录（`integration_test/auth_test.dart`）；成功的密钥登录见下面 H-04；keyboard-interactive 未验（服务器关闭了该认证方式）；已知限制见 HOST_INHERITANCE
- [ ] 持久化与坏数据恢复（H-02）
- [ ] 主机库：网格/列表、搜索、排序、置顶、最近连接、快速连接（H-03）：分组筛选、按标签搜索、置顶、列表视图已在集成测试中确认；拖拽排序未做
- [ ] SecretRef 与系统凭据存储，无明文降级（D-02）
- [ ] 密钥导入、引用与加密私钥（H-04）：导入 ssh-keygen 生成的 Ed25519/RSA/ECDSA 加密私钥、指纹与 ssh-keygen 一致有单元测试；作者允许临时往服务器的 `authorized_keys` 加测试公钥后，`integration_test/keys_test.dart` 验证了：OpenSSH 生成的 Ed25519、RSA 3072、ECDSA P-256 文件密钥与导入密钥登录；加密密钥按记住/未记住口令决定是否提问；错误口令得到密钥文件错误；应用生成的密钥登录；公钥移除后认证失败。没有验证错误口令后的界面重试，也不知道作者自己的密钥类型，所以不勾选

连接：
- [ ] HostTrustService、trust 数据、确认对话框（C-01）：已独立为 HostTrustService，所有拨号经它校验
- [ ] 认证状态机、多因子、取消（C-02）
- [ ] ConnectionManager：池、合并拨号、租约、停泊（C-03）：分屏和断开后重连复用连接已在服务器上确认；60s 停泊和不同用户不复用只有单元测试
- [ ] 保活、断线、手动与可选自动重连（C-04）：自动重连在服务端结束会话时已确认；保活和真实断网未测

终端与外壳：
- [ ] TerminalSessionManager、model 与 view 分离、流控（T-03）：真实服务器持续输出下内存有界（+9–30 MiB）、隐藏标签继续接收、Ctrl+C 能结束输出，数字见 TERMINAL_FLOW；链路（约 3 Mbit/s）比消费端慢，队列峰值没到 1 MiB 高水位，SSH 窗口背压没有被真实触发；窗口最小化后继续接收没有测，所以不勾选。关闭标签现在会挂断远端 shell（此前登录 shell 会留在服务器上）
- [ ] 多标签、搜索、复制粘贴、字体、URL（T-01）：搜索、重命名、复制标签已在服务器上确认；URL 只有单元测试
- [ ] 输入策略、IME、快捷键上下文（T-02）
- [ ] 标签生命周期（W-02 的 M1 部分）
- [ ] 设置定义、设置页（S-01）：SettingDef 与全有或全无的 patch 有单元测试；其他 feature 经 SettingsSection 加分区
- [ ] capabilities 最小目录、命令面板
- [ ] 键盘操作与视觉检查（U-01）
- [ ] P-01a/c/f、P-02 记录

## M2 文件工作流

开始时：
- [ ] E-06、E-07 结果写入此处，据此确定并发和 channel 策略：E-07 通过（上传中取消，终端照常、远端不留 `.part`）；E-06 用 256 MiB 上传和 10 GiB 稀疏文件下载各跑 30 秒后取消测过（TESTING §6：占满链路时终端往返从 64–67 ms 升到 1.1–2.9 s，内存有界），没有按作者定的大小跑完整传输，策略没有据此改动。当前策略见 MODULES §4“当前实现”

功能：
- [ ] SFTP 浏览：单栏与双栏共用组件、键盘操作（F-01）：终端侧栏和双栏页、中文和带空格的名字、Enter/F2/Delete 已在服务器上确认；方向键、按名跳转、Ctrl+A 未测
- [x] 文件操作：新建、重命名、删除、chmod（F-01）：集成测试在服务器上逐项核对，删除指向目录的符号链接只删链接
- [ ] TransferManager：队列、并发、进度、取消、从头重试（F-03）：进度和取消在服务器上确认；并发上限和重试只有单元测试；“关闭面板不取消任务”未测
- [x] .part 发布、大小校验、冲突处理（F-02）：上传下载哈希一致、取消不留 `.part`、同名“保留两者”在服务器上确认；替换、合并、跳过和“本批都这样”只有单元测试
- [ ] 目录传输：扫描上限、逐项冲突：下载含中文名的目录在服务器上确认；上限和逐项冲突只有单元测试
- [ ] OS 拖入上传：已实现（desktop_drop），未测
- [ ] 外部编辑：临时副本、watcher、冲突、恢复（F-05）：app 一侧已在真实服务器上跑通（`integration_test/edits_test.dart`：原子替换和原地写入被发现、手动与自动上传、连续保存以最后一次为准、冲突时覆盖/重新下载/另存副本、非法文件名、退出后恢复），编辑器由测试扮演；作者自己的编辑器还没试，所以不勾选
- [ ] 传输历史：保存、重启后进行中的变为“已中断”、200 条/30 天裁剪只有单元测试
- [ ] P-01a/c/e/f、P-03 记录

## M3 桌面主力版

- [x] 分屏树与焦点（W-01）：`test/layout_test.dart`
- [x] 布局恢复（W-02 的 M3 部分）：workspace.json 只存布局、主机 ID 和标签名；重启后恢复为未连接，不自己拨号；`test/workspace_test.dart` 通过，服务器集成测试 `workspace: palette, split panes, restore after restart` 此前通过，之后的改动没有重跑
- [ ] 跳板链、SOCKS5/HTTP 代理、legacy 按主机启用（C-01、C-04 的 M3 部分）：路由已实现；`integration_test/routes_test.dart` 在 Windows/Ubuntu 通过双跳（服务器自身 loopback）、每跳校验、共享跳板、direct-tcpip 和远端转发取消；循环/缺失/链上限/改跳板后不复用与 RSA 信任别名有单元测试。代理和 legacy 没有对应真实环境，未验证
- [ ] 端口转发 L/R/D 与规则管理（R-01、R-02、R-03）：L/R/D、SOCKS5、规则面板、暴露确认、退出收束和单元测试（`test/forwarding_test.dart`，模拟通道）已实现并接入工具栏与命令面板；真实服务器上 L/R/D 通路与哈希、端口占用提示、停止后端口释放已在 `integration_test/forward_test.dart` 验证（走管理器，不经界面）；规则面板的点击流程和断线重连未验证，所以不勾选
- [ ] Windows 无系统顶栏的自绘窗口（ADR-12）：原生保留缩放/DPI/Snap 语义，Flutter 绘制标签行与窗口按钮，关闭经统一退出协调；组件与命中区有单元测试（`test/desktop_window_test.dart`），原生 C++ 已编译通过；2026-11-07 在运行中的窗口里向窗口投递非客户区点击，最大化按钮命中为 HTMAXBUTTON，最大化与还原都生效（作者此前报告点击无反应）；WM_CLOSE（Alt+F4、任务栏、系统菜单）改由原生转给 Dart 的统一退出，此前投递 WM_CLOSE 会不经确认直接退出，改后只有单元测试，真实窗口里的确认弹窗未亲测；拖动、Snap 布局浮层、DPI 切换未测；macOS/Linux 仍用系统外框
- [ ] 自有弹层与选择控件、图标栏与浮层、快速连接、可停靠文件面板（ADR-13、WORKSPACE_LAYOUT）：组件测试覆盖浮层 Esc、快速连接、停靠限宽与拖动；界面字体、UI/终端字号设置已实现；作者的调试实例里看到新界面运行，其余交互待作者验收
- [ ] 服务器监控面板（ADR-14、MODULES §8）：解析与速率有单元测试（`test/monitor_test.dart`）；作者服务器上 CPU、内存、交换、网络、磁盘、运行时长实时显示；GPU 无测试环境。2026-11-08 按作者要求重做为 FinalShell 式密度：CPU/内存/交换环形图、可选刷新间隔、前 5 进程点开进程窗口（排序、搜索、暂停、确认后结束进程）、NVIDIA/AMD GPU 页；nvidia-smi 与 amdgpu sysfs 解析、进程 CPU、面板与进程窗口有单元/组件测试（`test/monitor_panel_test.dart`）。重做后的采集命令没有在服务器上运行，GPU 只有构造样本
- [ ] 底部文件面板目录树与终端目录跟随（MODULES §3、§4）：停靠在下方时左侧目录树、右侧列表；文件面板打开期间按 Enter 后与收到 OSC 7 时经同一连接 exec 只读查询终端目录，单向跟随。会话标记、查询时机、OSC 7 回落、目录树和跟随有测试（`test/terminal_directory_test.dart`）；查询脚本只在本机 bash/dash 做过语法检查，没有在服务器上运行；su、tmux、嵌套 ssh 下得到的是外层 shell 的目录
- [x] 片段：搜索与增删改、持久化、插入/运行、命令面板入口；Windows 无连接界面集成通过，受控插入与 shell 生命周期用模拟通道验证，真实 SSH 片段发送未测
- [ ] 主机导入（HOST_IMPORT、SSH_CONFIG_IMPORT）：2026-11-08 抽屉换成居中对话框，来源扩展为 OpenSSH、PuTTY、MobaXterm、SecureCRT、Xshell、FinalShell、Tabby、CSV，空库首次启动自动打开一次。SSH config 解析、计划和 revision 校验提交有单元测试（`test/ssh_config_test.dart`）；其他格式的解析、编码识别、上限和目录读取有单元测试（`test/host_import_test.dart`，构造样例）；对话框、目标分组、首次引导有组件测试（`test/import_dialog_test.dart`，假的文件来源）。随后增加逐软件选取指引、实际来源路径与重选、FinalShell 安装信息发现、可关闭的旧式保存密码本地迁移；已有直接密码认证主机可补缺失密码而不重复创建，代理路由和密钥认证不补。`test/finalshell_login_test.dart`、`test/credential_migration_test.dart`、`test/host_import_discovery_test.dart` 与组件测试覆盖，完整 390 项测试、analyze、imports 通过。各软件的真实安装、默认位置、注册表读取和文件选择器都没有在真实窗口运行
- [x] known_hosts 导入：解析、哈希匹配（对照 `ssh-keygen -H` 的输出）、冲突不覆盖、串行落盘和预览对话框有单元/组件测试；文件选择器和真实窗口未运行
- [x] 密钥生成：Ed25519，ssh-keygen 能读出同样的公钥和指纹；应用生成的密钥写入服务器的 `authorized_keys` 后登录成功（`integration_test/keys_test.dart`，临时公钥带标记，结束后移除并核对大小与权限）
- [x] 暂停与断点续传（F-04）：单文件暂停/续传、checkpoint 持久化与重启恢复、源与 `.part` 校验、取消/重试清理、目标锁有单元测试（`test/files_test.dart`，全部走本机文件系统）；传输面板的暂停/继续按钮和 `transfer.pause`/`transfer.resume` 能力已接线。2026-11-07 在真实服务器上（`integration_test/transfer_test.dart`）验证：上传暂停于 3.4–3.9 MiB/12 MiB、下载暂停于 2.1–2.3 MiB/10 MiB，续传后哈希一致；传输中退出后文件停在 paused，重启后续传，哈希一致；源文件变化后拒绝续传。只验证了几十 MiB 的文件，大文件暂停和 10 GB 没有验证；复核发现的“保留两者 (2)”判断、源类型变化处理、恢复 ID 路径约束三项缺陷已修复并有回归测试（见 DESIGN_AUDIT）
- [ ] 10 GB 传输（P-03）：只测了上万条目目录（列出 5.5–5.9 s，内存有界）和 256 MiB 上传/10 GiB 稀疏下载 30 秒内内存有界、可取消；链路约 3 Mbit/s，10 GB 要 7 小时以上，未做完整传输
- [x] README 写明已测环境和无保障声明
- [ ] 确定 LICENSE；审计依赖、字体、图标许可
- [x] Windows 本地打包：2026-11-08 从原 `build/windows/x64/runner/Release` 重建，最新 ZIP 为 `sshairy-0.1.0+1-windows-x64-20261108-021220-258.zip`（19.64 MiB，137 个文件，120 张品牌运行 PNG），包含文件面板裁剪/单行操作栏、分区监控和导入指引/FinalShell 登录迁移，附 101 个依赖许可证清单；ZIP 与 Release/staging 逐文件核对、CRC 和 SHA256 均通过，旧包保留。未启动新包验证真实配置和服务器登录；未签名，正式发行仍待许可证确认。其他平台未验证

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

不预先排期，用户需求或反馈确认后才开始。候选：本地 PTY、ssh-agent、证书、公钥分发、应用锁、广播输入、关键词高亮、远程到远程复制、加密可移植备份、AI 远程文件写入与自动模式。

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
| 2026-11-06 | 开发助手 | 纠偏（capability 登记移到 app/、凭据 API 收窄、池键加 securityRevision、JsonFile 保护、统一退出、启动配置门）；SSH config 导入（解析、计划、提交，9 项单元测试）；转发规则面板；片段编辑改抽屉。F-04 单文件暂停/续传（checkpoint、恢复校验、清理、目标锁，`test/files_test.dart`）。200 项单元测试通过，analyze 与 imports 干净 | 无边框窗口（ADR-12）、新图标、冰蓝配色已实现但未在真实窗口亲测；暂停/续传未经真实服务器验证（SFTP 侧 `append` 已实现，本机 `FileMode.append` 修正过截断问题）；该轮随后已分主题本地提交（至 db45d93），未推送 |
| 2026-11-06 | 开发助手 | 对照最早设计与参考复核：架构纠偏主要边界已落实；3 个本机探针确认续传缺陷，尚未修复，详见 DESIGN_AUDIT。修订 SECURITY/ROADMAP/MODULES 的滞后描述。通过 imagegen + 配置回退实际调用 GPT Image 2 重做 logo，保留原图与提示词，导出透明母版/应用 PNG/Windows ICO/macOS 图标；Windows debug 构建成功。正式 200 项测试、analyze、imports 通过 | 先修三项续传问题再补原始 UI 和流控。新图标已替换；本轮变更未提交。未连接服务器，未新增窗口手动验收 |
| 2026-11-07 | 开发助手 | H-01 完成：主机、分组、全局默认值共用 ConnectionEditor（每项链接图标、继承来源提示），分组/默认值/身份抽屉，空组与解散确认；group.*/identity.*/hostDefaults.* 能力，host.* 沿用同一字段词汇并带 `inherit`；传输续传三项缺陷修复并补回归测试。全量 284 项测试通过，flutter analyze 无问题，imports ok。widget 测试发现并修了一个真实缺陷：链接的登录（无上层可继承）仍被必填校验，导致分组无法保存 | 真实服务器上的 key→password、keyboard-interactive、密钥加载未验；已知限制见 HOST_INHERITANCE（不合并同路径组、解散丢默认值、跳板被删后悬挂引用、折叠路由区的校验错误不可见）；本轮变更尚未提交，未推送 |
| 2026-11-07 | 开发助手 | 用作者提供的测试服务器跑集成测试（凭证只经环境变量，日志里核对过没有出现）：app_test 7 项、routes_test、snippets_test、新增 auth_test 通过。发现并修复真实缺陷：首次信任主机密钥和首次保存凭据会递增池的安全修订，使刚建立的连接无法复用（退出 shell 后重连、分屏、同主机新标签都会再次要密码）；修订现在只在收回信任或凭据时递增（CONTRACTS、CORRECTION 已写明，host_trust_test、keys_test 覆盖）。集成测试其余失败是跟不上新界面（主机树使名称出现两次、认证方式改下拉框、日志文件占用清理），已改测试。285 项单元测试、analyze、imports 通过 | 没有试成功的密钥登录（要改 authorized_keys，需作者同意）和 keyboard-interactive；10 GB 传输、窗口手动验收、真实输入法和外部编辑器未做；同一条命令连续跑多个集成测试文件时第二个文件可能启动失败，分开跑；本轮变更尚未提交，未推送 |
| 2026-11-07 | 开发助手 | 作者允许临时往 `authorized_keys` 加测试公钥和超过 1 GB 的流量后，测完剩下的并修了测出的问题：新增 keys/forward/transfer/edits/memory 集成测试（`integration_test/support/` 放共用驱动），连真实服务器逐个跑通；`memory_test` 在 Profile 构建下通过。修复：关闭的会话被共享连接持有（每个租约自己的 `done`）；关标签不挂断远端 shell（`ShellChannel.close` 双向关闭，3 秒内远端 shell 消失）；被用作跳板的主机不能删除（`HostInUse`）并从路由区定位；双击改为按时间判断（`DoubleClick`）；本进程内重复监听同一端口归为“端口已被占用”。294 项单元测试、analyze、imports 通过；数字与未测项见 TESTING §6、TERMINAL_FLOW、DESIGN_AUDIT | 测试服务器链路约 3 Mbit/s，10 GB 传输和 T-03 的真实背压没法测；Profile 内存是总 RSS 不是任务管理器口径；keyboard-interactive（服务器关闭）、窗口拖动/Snap/DPI/最小化、真实输入法、作者自己的外部编辑器未测；文件栏的行单击仍有约 300 ms 延迟；`vm_service` 加为开发依赖（内存测试用）；每个测试文件分开跑；本轮变更按主题本地提交，未推送 |
| 2026-11-07 | 开发助手 | 按作者要求重做界面：自有对话框/菜单/下拉/开关/分段（ADR-13），图标栏 + 二级浮层取代导航列，顶栏 `+` 快速连接，终端标签内监控面板（ADR-14，exec 租约、只读命令、不拨号），文件面板可停靠左/右/下；界面字体（中文回退到微软雅黑）与 UI/终端字号设置，整体尺寸收紧。修复：最大化按钮点击无反应（原生 HTMAXBUTTON 点击由 runner 执行）；系统关闭不经确认直接退出（WM_CLOSE 转给 Dart 统一退出，`confirmQuit` 默认开）。查明作者看到的 270–350 MB 是 `flutter run` Debug，Release 为 124/156 MB（TESTING §6）。303 项单元测试、analyze、imports 通过；集成测试已改到新组件但本轮未运行 | 作者在用调试实例，验证只用投递给本窗口的消息和 PrintWindow，不发真实键鼠；真实窗口的关闭确认、Snap 布局浮层、拖动与 DPI 待作者亲测；集成测试要连服务器重跑；文件面板窄宽时面包屑截断、CPU 曲线低负载时贴底可再调；本轮变更按主题本地提交，未推送 |
| 2026-11-07 | 开发助手 | 按作者提供的品牌包替换整套六主题与 Logo：独立浅深色语义面板、终端 ANSI/选区、3×2 设置预览卡、应用内随主题 Logo、主机库角色与风线空状态；平台静态图标换默认冰蓝薄荷。原四个 accent 持久化值兼容，新两套走同一 typed 设置/命令面板。只导入 36 张实际使用的图片（含默认图标约 2.3 MiB），不把 32 MiB 原始包打进应用；旧 Logo 归档，统一导入工具与来源映射。308 项测试、analyze、imports 通过；十二种组合组件渲染预览已检查，Windows Release 构建成功 | 作者可在设置→外观→配色方案切换；macOS 图标已导出，未运行；本轮未连服务器，未重跑 SSH 集成测试；原始素材包保持原样 |
| 2026-11-07 | 开发助手 | 按作者要求将原始设计素材包 Sshairy-Brand-Asset-Pack 加入 .gitignore；该目录此前未被 Git 追踪，本地文件保留，已导入的运行时 assets/brand 继续纳入版本管理 | 无需移除 Git 索引；git check-ignore 已确认规则生效 |
| 2026-11-07 | 开发助手 | 按作者反馈将冰蓝薄荷浅色界面主色换为湖青 #46B7C8，大按钮用浅填充和深字；导航支持 48/240 px 展开，完整文字和关于页同款横版 Logo，选中背景与文字对比度统一；顶栏 44 px、上下留白，最大化时 WM_NCCALCSIZE 排除屏幕外的隐形边框。Windows 运行图标随六主题及有效明暗（含系统模式）切换，12 ICO 资源由统一导入工具生成；传输列表改为顶栏按钮下方 440×最高 520 的浮层，保留所有队列操作。318 项测试、analyze、imports 通过；在己方临时数据窗口实测 200% 缩放客户区、HTMAXBUTTON 最大化/还原、Logo/按钮/浮层位置和 12 个原生图标图像，详见 TESTING §6 | Windows Release 构建成功；为保留作者正在运行的旧版，新输出位于 `build/desktop-refresh/windows/x64/runner/Release/sshairy.exe`，使用单次进程的独立 Flutter 配置，未改用户全局配置。测试入口与预览 exe 已移除。跨屏 DPI、Snap 菜单与固定任务栏快捷方式缓存待亲测；本轮未连服务器、未重跑 SSH 集成测试 |
| 2026-11-07 | 开发助手 | 按作者要求清空旧 build（约 586 MiB，含 desktop-refresh 和测试缓存）后，从当前源码重新构建 Windows Release，恢复默认运行路径 `build/windows/x64/runner/Release/sshairy.exe`；新包 `dist/sshairy-0.1.0+1-windows-x64-20261107-211318-198.zip` 为 16.46 MiB，完整目录为 37.12 MiB。ZIP 的 52 个文件逐一核对 staging/Release，CRC 与 SHA256 通过，含 101 个依赖许可证清单和全部 36 张运行品牌 PNG，不含原始素材包和临时预览 | 重建前无运行实例；OneDrive 给旧插件符号链接加只读属性，清除链接本身后重建成功，Pub 缓存目标保留。PowerShell Compress-Archive 报缺少 ZipArchiveMode 类型，最终 ZIP 与 SHA256 改用本机 Python 标准库生成并校验；本轮未改业务代码、未重跑功能测试，未连接服务器 |
| 2026-11-07 | 开发助手 | 冰蓝薄荷浅色主色改为在原始 #2E6EF7 上微调的 #2C71E8（湖青弃用），填充按钮在主色可承载 4.5:1 白字时直接用主色；窗口按钮 36×28 控件圆角悬浮、间距 2、关闭右侧 8，关闭悬浮为危险色。确认退出后先经 `DesktopWindow.hide` 隐藏窗口，清理失败时 `show` 后再给出返回/重试/仍要退出；runner 消息循环结束后也先隐藏再拆引擎。322 项测试、analyze、imports 通过；Profile 探针实测确认后窗口 0.02 s 隐藏（修复前 2.04 s），详见 TESTING §6 | 有 SSH 会话时的约 10 s 冻结只按原因推断修复，未连服务器复测；窗口按钮真实悬浮外观未亲测（投递的鼠标消息不触发悬浮，未用真实键鼠）。Release 重建，dist 旧包替换为 `sshairy-0.1.0+1-windows-x64-20261107-215430-741.zip`（16.46 MiB，53 个文件逐一核对 Release，CRC 与 SHA256 通过）|
| 2026-11-07 | 开发助手 | 展开导航默认宽度由 240 降为 200，并可拖动分隔线在 176–320 间调整，交互与文件面板一致（导线、松开提交、双击恢复、方向键与语义增减），宽度属窗口瞬时布局。导入工具新增每主题云、星光、风线（浅/深）和五个动作图（睡在云上、安全、专注编码、已连接、SFTP 传输），约 2 MB；装饰一律半透明、不可交互、不进语义树：空主机库角色 70%（暗 72%），水印 12%（暗 9%）且仅在按固定行高算出的空白足够时显示，空列表动作 55%（暗 60%）。片段无条目时显示动作，有搜索词无结果仍显示“无匹配”。323 项测试、analyze、imports 通过 | 随后按作者要求在无运行实例时重建 Release，dist 旧包替换为 `sshairy-0.1.0+1-windows-x64-20261107-222802-982.zip`（18.35 MiB，119 个文件逐一核对 Release，含 102 张运行品牌 PNG，CRC 与 SHA256 通过）；素材包中没有中国年主题素材，按“pose 这类动作图”理解；终端、文件列表、监控与安全确认仍不加装饰。拖动和悬浮在真实窗口未用真实鼠标验证，组件测试覆盖 |
| 2026-11-07 | 开发助手 | 主机库的空状态角色和右下水印改为动作轮换：池为默认、开心、成功、疾速、睡在云上（`BrandRotation`），每次主机库重新可见时随机换一个且直接显示（换掉 AnimatedSwitcher 的 key，避免淡出旧图），停留时每 45 秒先 `precacheImage` 再 1.2 秒交叉淡入淡出；计时器只在 `active` 且未要求减少动态效果时存在。导入工具新增导出默认/开心/成功/疾速（360 px），删除不再使用的整身 mascot.png，每主题 20 张、共 120 张运行 PNG。325 项测试、analyze、imports 通过 | dist 中的包仍是轮换前的版本（102 张品牌 PNG），重新打包时 `verify_repackage2.py` 的期望数改为 120；疾速等宽幅动作在 190×140 / 168×130 框内按 contain 缩放，真实窗口外观与淡入淡出待作者亲测 |
| 2026-11-08 | 开发助手 | 按作者一组反馈修改：去掉多余边距；导航展开宽度写入配置（`navigationWidth`，松开时写一次）；顶栏标签选中时留出间隔；冰蓝薄荷深色改为中性灰为主、蓝色强调（BRAND）；监控面板重做（环形图、刷新间隔、进程窗口、GPU 页）；大文件传输卡顿：加密偏好改为 OpenSSH 顺序（chacha20-poly1305 优先，库默认的纯 Dart AES-GCM 不到 1 MB/s），速度采样按 100 ms 合并；底部文件面板目录树并跟随终端目录；主机导入改为对话框并支持八种来源与首次引导（HOST_IMPORT，新增 yaml 直接依赖）。360 项测试、analyze、imports 通过 | 本轮都只有单元/组件测试：监控新命令、终端目录查询脚本、chacha 协商与传输流畅度没有连服务器运行，GPU 没有真实显卡，导入没有在装有这些软件的机器上试，界面改动未在真实窗口亲测；现有测试和集成驱动预置 `importOffered: true` 以免首次引导挡住主机库；dist 里的包仍是旧版（102 张品牌 PNG），重新打包时期望数为 120；本轮变更尚未提交 |
| 2026-11-08 | 开发助手 | 按作者要求重新打包当前源码：Windows Release 构建成功，`sshairy-0.1.0+1-windows-x64-20261108-011743-040.zip` 为 19.61 MiB，137 个文件、120 张运行品牌 PNG；完整 runner 与依赖许可证清单一并打包。ZIP/Release/staging 逐文件哈希、ZIP CRC、SHA256 校验通过，旧包保留 | 本轮仅构建与包内容校验，未启动新包、未重跑功能或服务器测试；作者授权当前与后续修改按独立功能或修复及时本地提交，推送需另行授权 |

| 2026-11-08 | 开发助手 | 新增 HostPasswordImport：只补缺失密码，凭据读写与清理共用串行队列；先写秘密再提交元数据，失败回收本次尝试创建的引用，回收失败单独报告；7 项合成测试通过 | 安全策略按作者要求允许主动本地迁移，仍禁止 AI 读取原始秘密、明文降级和覆盖已有密码 |
| 2026-11-08 | 开发助手 | FinalShell 自动发现扩展到常见安装目录、固定 App Paths 和匹配的软件安装信息；跳过空来源，预览契约保留实际路径；5 项合成发现测试通过 | 不全盘扫描、不执行安装命令；未读取作者的真实配置或注册表；任意便携目录仍手动选择 |
| 2026-11-08 | 开发助手 | 磁盘监控改为逐个已挂载本地文件系统显示设备、挂载点与可用/总量；优先按文件系统类型过滤，保留 `/run/media` 等位置的真实数据分区，兼容旧 df 输出并去重 bind mount。相关 15 项测试、analyze、imports 通过 | 未连接服务器核对实际分区；未挂载分区不统计可用空间；按独立修复本地提交 |
| 2026-11-08 | 开发助手 | 文件面板修复：目录树改为每行独立 Material，选中背景与点击反馈随列表裁剪；停靠和关闭按钮合并到文件路径工具栏，窄侧栏把前进/后退放进更多菜单。像素回归在旧实现复现工具栏被选中背景覆盖、修复后通过；底部/300 px 侧栏验证按钮同排与菜单操作；全量 363 项测试、analyze、imports 通过 | 已按独立主题提交此前积累改动；此次修复单独提交。尚未重建含此修复的 Release，最终打包等待后续导入体验改进完成 |
| 2026-11-08 | 开发助手 | 导入体验与 FinalShell 登录迁移完成：各来源所需文件/目录、未发现时先指引、实际路径与重选；默认开启且可关闭的保存密码迁移；支持旧式编码，已有主机补缺失密码，不覆盖；代理路由、来源变化、并发冲突与失败回收均有回归。全量 390 项测试、analyze、imports 通过；发现/凭据/交互分主题本地提交 | 未使用作者真实配置或登录服务器；FinalShell 专有密钥引用和未知密码编码仍需补登录；下一步从原 `build/windows/x64/runner/Release` 重建打包 |
| 2026-11-08 | 开发助手 | 原 Release 目录重建成功（105.6 秒），新包 `sshairy-0.1.0+1-windows-x64-20261108-021220-258.zip`（19.64 MiB，完整目录 40.60 MiB）；137 文件/120 运行 PNG 与 Release/staging/ZIP 逐一一致，CRC 和 SHA256 通过，附校验文件 | 构建前确认无运行实例；未创建额外修复构建目录。功能已分点本地提交，未推送；未启动新包读取真实配置或连接服务器 |
| 2026-11-08 | 开发助手 | 导入软件标识改为 8 个独立绘制的简化 SVG（含 CSV 通用图形），本地资源与专用 flutter_svg 适配器；原名称/指引/计数保留。资源编译及浅深渲染 3 项、导入交互 5 项通过，图形浅深预览已检查 | 图形为识别用简化标识，非官方精确复刻；未使用 Netcatty 素材；按独立点本地提交 |
| 2026-11-08 | 开发助手 | CPU/内存/GPU 历史改为独立动态量程，最近 60 点自动缩放、12% 余量、至少 1 个百分点跨度，悬浮可看实际范围；网络上下行仍共享零基线；无变化时不重复绘制。8 项曲线/像素回归、3 项监控面板测试通过 | 恒定值保持直线，环形图显示真实百分比；未连服务器或验证真实 GPU |
| 2026-11-08 | 开发助手 | 修复内存保留点：传输历史在内存/磁盘同步裁剪并释放完成批次策略；目录树按 128 目录/8192 子项目标回收，历史各 100 项；文件页隐藏 30 秒释放浏览列表与 SFTP、返回恢复，隐藏动画停止；图片闲置 LRU 为 16 MiB/128，隐藏/内存压力清理。资源与恢复有构造测试，本轮全量 427 项、analyze、imports 通过 | 原 Release 进程只读采样工作集 330.3 MiB/私有提交 282.3 MiB，无同条件前后测量，不宣称固定降幅；保留终端回滚、后台任务和大目录完整内容。详见 MEMORY_USAGE |
