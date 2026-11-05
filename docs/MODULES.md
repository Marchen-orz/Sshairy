# 功能与模块规格

v0.2。M0–M5 定义以 DESIGN 为准。标明的默认值是 sshairy 的初始设计值，不代表 Netcatty 默认值或实测结果。安全规则见 SECURITY，资源契约见 CONTRACTS，检查编号见 TESTING。

## 1. hosts / credentials（M1）

### 数据模型

| 模型 | 主要字段/不变量 |
|---|---|
| HostProfile | id、revision、label、endpoint、groupId、tags、connectionOverrides、terminalOverrides、icon、pinned、order；无 password/privateKey |
| Group | id、parentId、name、defaults、order；不允许循环，路径由 ID 关系推导 |
| Identity | id、revision、username、AuthPolicy；可供多个主机引用 |
| AuthPolicy | 有序认证偏好、identity/key SecretRef、是否允许交互；不是互斥的一次性 authMethod |
| KeyMetadata | id、算法、指纹、公钥、创建时间、来源（导入/文件引用/生成）、SecretRef；私钥不作为普通 DTO 字段 |
| Override<T> | inherit / disabled（仅允许禁用的字段）/ value(T)；区分 null、空列表、false、显式直连 |
| ResolvedConnectionSpec | 解析后不可变端点、用户、认证、路由、算法、保活、信任及凭据 revision |

继承顺序：全局 → 根组 → 子组 → 主机；身份/认证策略整体替换，不能继承密码同时又叠加另一身份密钥。解析纯函数可输出每个有效值的来源，编辑界面能显示“继承自…”。变更配置不隐式重连现有会话。

### 工作流

- 主机与分组创建、编辑、复制、删除、移动；删除分组默认将内容移出，批量删除另行明确选择。
- 网格/列表共用同一数据源、筛选、排序和选择模型；树形导航支持分组，完整树形主视图不列为 M1 前置。
- 搜索 label/host/user/tags；名称、最近连接、手动排序；置顶、最近连接。排序模式下拖拽禁用或先切手动排序。
- 快速连接解析 `user@host`、`user@host:port`、`ssh -p N user@host`，IPv6 使用明确 bracket 语法；只解析支持选项，不调用 shell 执行输入。临时主机默认不保存秘密或恢复状态。
- SSH config 导入在 M3：支持 Host/HostName/User/Port/IdentityFile/ProxyJump 的限定子集；不能直接把 `Host *` 变成一台主机。Include 需深度/文件范围上限；Match、ProxyCommand、复杂模式等不支持项展示报告，禁止偷偷执行命令。
- 密钥首期导入/引用优先，支持经 dartssh2 验证的 Ed25519/RSA/ECDSA 与加密格式。生成密钥在 M3 增补；未验证格式不宣称支持。证书、FIDO、agent 列为后续能力。
- 分发公钥是远程写操作，M5 再做；不能把复制到剪贴板与修改 authorized_keys 混为一事。

验收：H-01 继承与三态；H-02 并发编辑与坏数据恢复；H-03 搜索/IPv6/不支持语法；H-04 密钥与多因子。

## 2. connections（M1，路由扩展 M3）

```text
idle → resolving → connecting → handshaking → verifyingHostKey
     → authenticating ↔ awaitingChallenge → openingChannel → ready
任意阶段 → cancelling → cancelled；失败 → failed；运行掉线 → disconnected
```

- 认证可按服务器要求完成多步骤：key → keyboard-interactive、password → OTP、多轮挑战。prompt 的 echo 标志决定隐藏输入，OTP 不自动记忆。
- 主机信任确认与认证输入分开；取消 challenge 后停止连接，不再自动尝试其他认证方式。
- 初值：TCP 20s、认证总等待 120s（用户等待计入并显示）、通道打开 15s；known-host 确认最长 120s 且受总 attempt 取消控制。超时清理迟到 socket/channel。
- keepalive 默认 30s、连续 3 次无应答判失活，0 明确禁用；是否被库支持由 E-09 验证。
- 池按完整 ResolvedConnectionSpec 复用，合并并发同规格 acquire；lease 幂等归还。最后 lease 后默认停泊 60s，可设 0 立即关闭，范围 0–300s，**0 不表示无限保留**。
- 无法多通道/复用的主机可选独立连接。复用失败时只在未执行用户命令的 channel-open 阶段有界重建一次；不把所有错误都自动重登。
- 用户关闭 terminal 不关闭 file/forward 的租约；用户“断开主机全部会话”展示受影响资源。
- 手动重连默认；自动重连可选，1/2/4/8/16s 加抖动，最多 5 次，仅网络错误。主机密钥变化、认证失败、用户停止不自动重试。
- 恢复 shell 是新进程；不能声称恢复之前 cwd、作业、环境变量或 tmux 外的进程。
- M3 跳板链每跳独立认证/校验/超时；代理用于约定的第一跳；明确 SOCKS5 域名解析位置、HTTP CONNECT 407/IPv6/剩余 banner 字节。限制链深度并检查循环。
- 默认现代算法；不自动降级弱算法。按主机启用 legacy 必须说明兼容原因，不影响其他主机或整个链。
- OS/distro/cwd 探测按服务器能力进行，失败为 unknown；不要对网络设备或 Windows 自动运行 Linux 探测。启动命令默认无；M3 若提供，首次连接/重连行为分开且不自动重放有副作用脚本。

验收：C-01 host trust；C-02 多因子/取消；C-03 池与租约；C-04 路由/断网/迟到结果。

## 3. terminal 与 workspace（M1；分屏 M3）

TerminalSession 包含 sessionId、generation、channel、terminal model 与状态；Pane 仅引用 sessionId。关闭 view 不销毁 model，终端内核供应商类型不能泄漏给其他模块。

### 数据管线

```text
SSH bytes → 有界入口队列 → 增量解码/VT 解析 → terminal model → 可见 view
键盘/IME 提交 → 输入策略 → channel.write（有序，有界）
```

- 不在任意字节边界截断 UTF-8 或 ANSI；内存限制针对已解析 scrollback，不能丢未解析控制序列。
- 初值回滚 2000 行，设置范围 500–20000；实际内存还受列宽、字符属性和编码影响，不按行数推算 MB。
- 输出队列初值高水位 1 MiB/低水位 256 KiB，消费后才返还额度；必须验证 dartssh2 的 pause 是否传递到 SSH 窗口，否则该方案不算完成。
- 快速回显尽快解析；大输出每次有时间预算并让出 UI。不能只靠帧回调排空，隐藏/最小化窗口也要消费协议数据。
- 隐藏页保留 model、停止绘制/光标动画；后台仍解析、保持有界回滚与流控。M1 不做 serialize/hibernate 系统。
- resize 合并重复 rows/cols，拖动中节流，结束马上提交最终值；0×0 不发送。字体加载、DPI 变化要重新测量。

### 功能与输入

多标签创建/关闭/排序/重命名/复制；复制新 shell 可复用 transport，不复制正在运行的进程。状态点区分连接中、在线、掉线、有新输出。断开有原地重连入口，不把旧缓冲重新送到服务器。

复制粘贴、Ctrl+Shift+F 搜索、字号调整、URL 打开；右键默认菜单，右键粘贴可配置；多行或包含控制字符的粘贴预览。支持 bracketed paste，发送一次完整 IME commit，不默认逐字符 workaround。

中文、全角标点、emoji、组合字符、CJK 宽度、选区、光标位置必须实测。OSC 52 远端写剪贴板默认禁用；OSC 7 只更新有来源的 cwd 状态，不当指令执行。无法获得 cwd 时显示未知，不向正在 vim 的 shell 注入 pwd。

分屏树采用 Leaf(paneId, sessionId) / Split(axis, children, ratios)。不变量：ID 唯一、叶子非空、比例正且归一；移除叶子折叠单子分支，保持未受影响祖先比例；焦点只能指向现存叶子。初期最多 8 pane，受最小尺寸约束。

恢复保存布局和 host 引用，默认恢复为 disconnected 标签；自动连接独立开关且默认关。无凭据、原始输出、临时主机秘密进入恢复文件。重连不重放输入、广播或旧命令。

验收：T-01 VT/TUI；T-02 IME/快捷键；T-03 背压与隐藏；W-01 树与焦点；W-02 恢复与生命周期。

## 4. files：SFTP 与传输（M2）

### 浏览与操作

独立 SFTP 标签默认本地/远程双栏；终端侧面板为同组件的单栏远程视图。切视图不会取消任务。列表含名称、修改时间、大小、类型、权限/所有者（可隐藏）；目录优先、名称筛选、隐藏文件开关、前后导航、面包屑兼路径输入、每主机书签。

支持上传/下载、创建文件/目录、重命名、删除、复制路径、chmod（服务端支持才启用）。不为了“快速删除”偷偷拼 `rm -rf`。OS 拖入上传与选择文件走同任务队列；原生拖出、远程到远程复制、树形文件视图、压缩上传、SCP fallback、sudo SFTP 延后。

文件选择采用 Shift 范围、Ctrl/Cmd 多选；Enter 打开目录或外部编辑流程、Backspace 上级、F2 重命名、F5 刷新、Delete 删除确认、Ctrl/Cmd+A 全选、可打印字符前缀定位。输入框或模态框聚焦时列表快捷键不执行。

### 传输生命周期

```text
queued → preparing → running → verifying → publishing → completed
任意可中止阶段 → cancelling → cancelled
running → pausing → paused → preparing（M3 增量）
错误 → failed / attention；重启后的未完成任务 → interrupted
```

- Task 持有 source/target identity、方向、策略、已确认进度、状态、错误、operationId 和 lease；保存 DTO 只含白名单，不含密码、socket、闭包。
- M2 保证排队、进度、取消、从头重试；暂停/断点续传在 M3，经 checkpoint 验证通过才显示按钮。不能把网络中断后重传伪装成断点续传。
- 初值全局并发 3 文件、每 host 2 文件；单文件 32 KiB 请求、最多 16 个在途请求。实际 API 是否支持、WAN 吞吐是否足够由测试决定；无同等能力时不能伪报参数生效。
- 协议 open 15s、请求无进展 30s，可配置慢链路值；不为整个 1GB 文件设统一 30s 截止时间。进度 UI 最多约 5Hz 更新，速度以滑动窗口计算。
- 使用独立 transfer channel 或受限连接以保护终端延迟；复用 route/auth/trust 仍需校验。占用全连接带宽时不能只加更多 channel 声称隔离。
- 开始前重新 stat 源和目标；目录扫描有条目/深度上限、渐进进度。默认不递归跟随符号链接。
- 写 .part → 验证 → 安全发布，细则见 SECURITY。取消先停新请求、等待有限在途操作收束，再关闭本任务资源；不能 end 共享 transport 导致 terminal 掉线。
- 冲突提供跳过、保留副本、替换、取消任务；目录提供合并（仍逐项处理冲突）。应用于全部限定当前批次及同类型冲突。
- size+mtime 快速跳过是可选优化，默认关闭；不能当哈希校验。不可读取目标属性、未知文件类型、权限错误都不当作不存在。
- M3 续传只在源身份未变、part 存在且 checkpoint 合法时启用；checkpoint 只能覆盖连续已确认范围，不能取最大完成 offset。不得假定并发分块中间没有洞。
- 远端回执丢失但可能写入时结果为 attention；重新确认源/part 后才能续传。目录恢复逐项验证，不仅靠队列 JSON 猜测已完成。
- 历史保留最多 200 个终态任务/30 天（先到者），未完成任务不自动删除；任务完成不表示临时清理一定成功，分别显示警告。

### 外部编辑

下载到私有 temp → 系统默认或指定编辑器打开 → watcher + debounce → 显示修改待上传。默认显式上传；用户可为本编辑会话开启自动上传。

保存前重新验证远端基线，冲突时保留本地稿并提供重新下载/另存/明确覆盖；编辑器原子保存导致文件被替换时 watcher 要重新绑定。上传期间再次保存用 generation 串行追上最新版本，旧任务不能覆盖新版本。默认不转换编码/换行；失败稿跨重启可恢复。结束编辑与退出都提示未上传稿。

验收：F-01 浏览/文件名/链接；F-02 完整性与冲突；F-03 取消与共享连接；F-04 恢复续传；F-05 外部编辑；P-03 大文件/大目录。

## 5. forwarding（M3）

规则是持久化配置，运行 tunnel 是单独实例。规则含 id/revision、hostId、kind(local/remote/dynamic)、listenAddress/port、destination（适用时）、autoStart、autoReconnect。后两项独立且默认 false。

- 默认绑定 loopback；0.0.0.0/:: 是扩大网络暴露的显式选择，UI/AI 都要预览。
- 动态 SOCKS5 首期范围为经验证的 CONNECT；不暗示支持 UDP、完整代理认证或浏览器代理自动配置。
- state：stopped → starting → running → stopping → stopped，失败为 failed。停止需确认本地/远端 listener 解除，不仅归还 lease。
- 撤销远端监听超时应显示 stopFailed/状态未知；若必须断 transport，先说明关联会话影响，再执行用户选择。
- 手动 stop 取消重连意图；自动重连沿用 connections 的有界策略。端口占用、权限不足、服务端拒绝转发分别提示。

验收：R-01 L/R/D 正反向通路；R-02 stop/重连/共享资源；R-03 loopback 与端口冲突。

## 6. snippets（M3）

保存 label、text、tags、order；默认“插入终端待用户 Enter”，执行另有明确动作。变量模板后续添加，需明确文本替换不是安全 shell 参数转义。首期不做脚本 runtime、输出触发器、登录自动执行或批量广播。

AI 使用片段执行仍经过 command 策略，不能用 snippet.run 绕过审批。M5 广播必须持续显示目标，切换选择不静默扩大范围，多行粘贴统一确认。

## 7. settings 与应用外壳（M1）

SettingDefinition 统一记录 key/type/default/range/effect/applyMode/agentExposure；不是所有设置都自动生成界面。简单值可通用表单，密钥、快捷键和代理等复杂流程用专门组件。

| 分区 | 首期设置与行为 |
|---|---|
| 外观 | system/light/dark、强调色、界面字号与缩放；即时预览，可取消 |
| 终端 | 字体/字号（初值 14 logical px）、光标、回滚、选中复制（默认关）、右键行为、粘贴确认 |
| 连接 | 超时、保活、idle TTL、自动重连；标明下次连接生效 |
| 文件 | 并发、隐藏文件、默认外部程序；覆盖默认询问；自动上传默认关 |
| 快捷键 | 按上下文修改、冲突检测、恢复默认 |
| 数据与安全 | 数据目录、备份/恢复入口、信任管理；禁止由 AI 任意修改 |
| 关于 | 版本、许可、诊断导出（脱敏）、更新说明 |

首发中英文 ARB；错误、空状态和工具提示也国际化。连接日志仅记录步骤和脱敏错误，完整终端录制另设显式开关。

命令面板负责主机/会话/已注册能力搜索，AI 阶段新增“交给 AI”明确动作；**搜索不到时不自动把文本发给模型**。

一期单主窗口，设置作为窗口内页面/抽屉；多窗口、托盘、自动更新不作为首版前置。退出经 ShutdownCoordinator，不因关窗让上传、编辑稿或配置悄悄丢失。

验收：S-01 范围与 applyMode；U-01 键盘/焦点/视觉；D-01 关闭/持久化。

