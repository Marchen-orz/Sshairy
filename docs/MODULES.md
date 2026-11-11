# 功能与模块规格

M0–M5 定义以 DESIGN 为准；本文件描述功能与约束，实际完成范围见 ROADMAP，运行结果见 TESTING。默认值不代表 Netcatty 默认值或实测结果。安全规则见 SECURITY，资源契约见 CONTRACTS。

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

当前实现：`hosts.json` schema 2 由独立的 Group（稳定 ID，路径按父子关系推导）、Identity、全局默认值与主机组成，主机的端口、登录、跳板、代理、legacy 为三态覆盖（继承/禁用/自有值），解析顺序与限制见 HOST_INHERITANCE。选中分组时包含子分组；分组可在抽屉里改路径和默认值，解散时成员上移、分组自己的默认值被丢弃。密钥库（`credentials`）把私钥原样存进系统安全存储，keys.json 只有算法、指纹和公钥；加密私钥导入时只校验口令，是否记住口令单独选择。生成的密钥是不加密的 Ed25519（安全存储即保护边界）。仍有主机使用的密钥不能删除。

主机保存、删除、分组变更由 HostsNotifier 串行提交，持久化成功后才发布新状态。置顶与最近使用时间在队列执行时读取最新主机，只修改对应字段；已删除的主机不因迟到的元信息更新而复活。所有保存入口共用纯 Dart 结构校验；代理配置提交后再清理旧凭据，清理失败报告部分完成，不能冒充配置已回滚，也不能把旧口令发给新代理。与导入共用队列的清理顺序及重试范围见 HOST_INHERITANCE。已有连接不会被配置编辑隐式重连。

M3 路由字段：`jumpHostId` 指向另一台已保存主机作跳板，链由各主机的跳板依次串起；`proxy`（SOCKS5 或 HTTP CONNECT 的地址、端口、用户名）只在该主机是链的第一跳时使用，口令在代理要求时询问，可记住在安全存储 `host/<id>/proxy`；`legacy` 只为这一台主机追加 SHA-1 密钥交换与主机密钥签名、CBC 加密和 hmac-sha1，不影响链上其他主机。

主机导入（M3）统一为主机库工具栏打开的居中对话框，也接受 OpenSSH、PuTTY、MobaXterm、SecureCRT、Xshell、FinalShell、Tabby 与 CSV；首次启动且主机库为空时自动打开一次。先检测与解析来源、生成预览草稿，确认后按 revision 原子提交；不执行导入配置里的命令，不静默把不支持的路由改成直连。OpenSSH 首值匹配、Include 边界、IdentityFile、ProxyJump 和各格式的支持范围见 HOST_IMPORT。主机保存与导入共用结构校验及提交后的旧代理凭据清理协议（HOST_INHERITANCE）。

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
- 加密算法偏好与 OpenSSH 客户端默认一致：chacha20-poly1305 优先，其次 aes-ctr（配 etm MAC），aes-gcm 最后。dartssh2 的加解密是纯 Dart、跑在 UI isolate 上；2026-11-07 在作者机器上以 AOT 编译测得单核约 chacha20-poly1305 12.5 MB/s、aes128-ctr+hmac-sha256 4.5 MB/s、aes256-gcm 0.6 MB/s（库默认把 gcm 排第一），大文件传输时 gcm 会占满 UI 线程。更快的实现或把 SSH 放进后台 isolate 是后续项。
- 无法多通道/复用的主机可选独立连接。复用失败时只在未执行用户命令的 channel-open 阶段有界重建一次；不把所有错误都自动重登。
- 用户关闭 terminal 不关闭 file/forward 的租约；用户“断开主机全部会话”展示受影响资源。
- 手动重连默认；自动重连可选，1/2/4/8/16s 加抖动，最多 5 次，仅网络错误。主机密钥变化、认证失败、用户停止不自动重试。
- 恢复 shell 是新进程；不能声称恢复之前 cwd、作业、环境变量或 tmux 外的进程。
- M3 跳板链每跳独立认证/校验/超时；代理用于约定的第一跳；明确 SOCKS5 域名解析位置、HTTP CONNECT 407/IPv6/剩余 banner 字节。限制链深度并检查循环。
- 默认现代算法；不自动降级弱算法。按主机启用 legacy 必须说明兼容原因，不影响其他主机或整个链。
- OS/distro/cwd 探测按服务器能力进行，失败为 unknown；不要对网络设备或 Windows 自动运行 Linux 探测。启动命令默认无；M3 若提供，首次连接/重连行为分开且不自动重放有副作用脚本。

当前实现（M3 路由）：
- 跳板的每一跳都是 ConnectionManager 里的普通连接，多台主机经同一跳板时共用它。下一跳在跳板租约开的 direct-tcpip 通道上握手，各自经 HostTrustService（按目标地址和端口记录）、各自认证；下游连接持有跳板租约，关闭时归还。链最多 8 跳，出现循环或引用的主机已删除时在拨号前拒绝（ConnectFailure.route）。
- 代理只用于第一跳。SOCKS5 支持无认证与用户名/口令（RFC 1929），域名交给代理解析（ATYP 3），IP 字面量按 IPv4/IPv6 发送；HTTP 发 `CONNECT host:port`（IPv6 加方括号），407 视为代理认证失败。握手后多读到的字节（服务器 banner）原样交给 SSH。
- 主机密钥按密钥类型记录：`rsa-sha2-256`、`rsa-sha2-512` 与 `ssh-rsa` 是同一把 RSA 密钥，都记为 `ssh-rsa`。
- 池 key 包含跳板和代理，改了路由的主机不复用旧连接。
- known_hosts 导入：侧栏“主机密钥”选择 OpenSSH known_hosts 文件（最大 2 MiB），先生成预览，用户确认后一次写入。支持普通主机名、`[host]:port`、逗号分隔的别名和 IPv6；密钥类型限 ssh-ed25519、ssh-rsa、ecdsa-sha2-nistp256/384/521，密钥数据必须与所写类型一致。哈希条目 `|1|…` 只在与已保存主机的地址和端口匹配时导入。标记（`@revoked`、`@cert-authority`）、通配与否定模式、其他密钥类型、无法解析的行和未匹配的哈希名只列入报告，绝不当作可信；`@revoked` 仅计数，不与已信任的密钥比较。与已保存记录同端点同类型但指纹不同的列为冲突，保留原记录；文件内同端点同类型出现两个不同密钥时都不采用。提交时按当时已保存的记录再判断一次。HostTrustService 的所有改动（信任、遗忘、导入）经同一队列，写盘成功后才对外可见；`verify()` 的判断规则不变。

验收：C-01 host trust；C-02 多因子/取消；C-03 池与租约；C-04 路由/断网/迟到结果。

## 3. terminal 与 workspace（M1；分屏 M3）

TerminalSession 包含 sessionId、typed target（SSH 主机或本地 shell）、generation、channel、terminal model 与状态；Pane 仅引用 sessionId。关闭 view 不销毁 model，终端内核供应商类型不能泄漏给其他模块。

本地终端使用真实 PTY，复用有界输出、输入策略、resize 与会话状态。当前实现范围是 Windows ConPTY，macOS/Linux 在适配完成前不提供本地 shell 入口。shell 发现只检查系统环境、PATH 与可信常见安装位置，不执行候选、不全盘扫描；Windows 包含可用的 cmd、Windows PowerShell、PowerShell 7 与 Git Bash（实际 bash.exe，不启动 mintty）。发现结果按规范化可执行路径去重。启动仅在适配层内存继承环境，不能将环境变量写入布局、日志或业务对象。本地目标不伪造 HostId、不经 SSH 拨号，不挂监控/SFTP；启动失败在 pane 原位显示。分屏/复制启动同 shell 的新进程，重启不重放输入；正常退出排空输出，关闭会话释放自有 PTY/订阅，迟到启动与退出回调按代次清理，不影响其他终端。

Git Bash 的 MSYS 3.4.10 控制台路径在 resize/SIGWINCH 后可能丢弃首个新按键记录。Windows 适配器仅对 Git Bash 将 resize 与输入按 FIFO 串行，在 resize 后发送无字符的 key-up 兼容记录；不补发或改写用户字符。升级 Git 运行时时，先通过无兼容记录的并发 resize/输入回归再移除该措施。

### 数据管线

```text
SSH bytes → 有界入口队列 → 增量解码/VT 解析 → terminal model → 可见 view
键盘/IME 提交 → 输入策略 → channel.write（有序，有界）
```

- 不在任意字节边界截断 UTF-8 或 ANSI；内存限制针对已解析 scrollback，不能丢未解析控制序列。
- 初值回滚 2000 行，设置范围 500–20000；实际内存还受列宽、字符属性和编码影响，不按行数推算 MB。
- 每个 shell 独立持有输出消费器；stdout/stderr 各有增量 UTF-8 解码状态，共用按实际接收回调顺序排列的字节队列。两流之间没有 SSH 保证的全局顺序；未解析字节不丢弃、不拼成应用状态通知、不写日志。
- 队列高水位 1 MiB、低水位 256 KiB。高水位暂停两条订阅，消费到低水位一起恢复，暂停沿 ShellChannel stream 传递到 SSH 接收窗口；实际高水位验收见 TESTING。每个输入事件复制成独立、至多 8 KiB 的缓冲，消费完整缓冲后释放，避免 Uint8List 视图保留已消费前缀或更大的上游 backing buffer。`pendingBytes` 统计未消费载荷，`retainedBytes` 统计队列持有容量，两者在解析回调之间一致。
- 订阅遵守暂停契约时，队列载荷上限为高水位加触发暂停的一个输入事件；至多一个正在解码的 8 KiB 缓冲、临时字符串与对象、库内 channel/window 缓冲及入口复制期间的上游事件另计。单个上游事件大小不由消费器控制，不能把队列预算当作整个连接的内存硬上限。
- 每次最多解码/解析 64 KiB，按 8 KiB 分片检查 4 ms 预算，再用普通事件定时器让出执行权，不依赖绘制帧。第三方 VT 单次解析不可抢占，4 ms 不是硬实时承诺。UTF-8 decoder 和 ANSI parser 保留跨片段状态。
- 消费器属于 shell/model；隐藏页停止绘制与光标动画，隐藏/最小化仍继续消费并保持有界回滚。M1 不做 serialize/hibernate 系统。
- 正常 shell 结束后排空流尾部与队列再发布 disconnected。transport 结束则立即停输入、给未 EOF 的 decoder 排入结束标记，只排空应用已收到的尾部，不等上游另行 EOF；shell 先结束、transport 后丢失也必须收束。transport 尚未交给应用的缓冲不保证保留。流出错停止消费并报告连接失败。
- 用户关闭会话取消订阅、定时器、待处理字节和未完成拨号。重连创建新消费器，旧 shell 的输出与完成回调经身份检查，不能修改新 shell。结束后关闭本 shell、归还自身租约，不关闭共享 transport。
- resize 合并重复 rows/cols，拖动中节流，结束马上提交最终值；0×0 不发送。字体加载、DPI 变化要重新测量。

流控回归需覆盖水位、backing buffer 释放、分片让出、UTF-8/ANSI 跨片段、双流、尾部排空、transport 丢失且流不 EOF、错误/取消及旧 shell 迟到结果；实网数据只在 TESTING 维护。

### 功能与输入

多标签创建/关闭/排序/重命名/复制；复制新 shell 可复用 transport，不复制正在运行的进程。状态点区分连接中、在线、掉线、有新输出。断开有原地重连入口，不把旧缓冲重新送到服务器。

复制粘贴、Ctrl+Shift+F 搜索（从最新输出开始，Enter 向上、Shift+Enter 向下，可区分大小写和正则）、字号调整、URL 打开（Ctrl+单击或右键菜单，只开 http/https，参数直接交给系统程序、不经 shell）；右键默认菜单，右键粘贴可配置；多行或包含控制字符的粘贴预览。支持 bracketed paste，发送一次完整 IME commit，不默认逐字符 workaround。

中文、全角标点、emoji、组合字符、CJK 宽度、选区、光标位置必须实测。OSC 52 远端写剪贴板默认禁用；OSC 7 只更新有来源的 cwd 状态，不当指令执行。无法获得 cwd 时显示未知，不向正在 vim 的 shell 注入 pwd。

终端目录（2026-11-08）：开 shell 时随 pty 请求发送环境变量 `LC_SSHAIRY_SESSION=<16 位随机十六进制>`（Debian/Ubuntu 默认 `AcceptEnv LC_*`）；服务器拒绝时不带它重开一次，同一连接后续 shell 不再尝试。文件面板打开期间，用户按 Enter 后约 400 ms 和 1.5 s、以及收到 OSC 7 时，经同一租约 exec 一条常量脚本：在 `/proc/*/environ` 里找带该值的进程，取父进程不带它的那个（登录 shell）的 `cwd`；终端前台进程组若是带该值的 shell（嵌套 bash 等），用它的。token 只含十六进制字符，脚本不拼接其他输入，只读。拿不到 token（服务器拒绝或非 Linux）时退回 OSC 7 报告的路径；两者都没有就不同步。只在结果变化时通知，方向只有终端 → 文件面板。`su`/`sudo -i`、tmux 和到其他主机的 ssh 里，得到的是外层登录 shell 的目录。

分屏树采用 Leaf(paneId, sessionId) / Split(axis, children, ratios)。不变量：ID 唯一、叶子非空、比例正且归一；移除叶子折叠单子分支，保持未受影响祖先比例；焦点只能指向现存叶子。初期最多 8 pane，受最小尺寸约束。

拖放布局使用源/目标 TabId、可选源 PaneId、目标 PaneId 与四向边枚举，源/目标布局身份用于拒绝过期拖放。顶部标签跨标签整体搬移源树，拖入自身标签则共用分屏用例，为命中叶新开同目标的一个 shell；pane 小标题仅搬移该叶，同页叶移动先计算删除后再插入，不接受移动到自身。目标按指定边在命中叶旁插入，保留移入子树内部比例和无关祖先比例，整次最多 8 pane。搬移只转移布局引用，不调用 session open/close；本页顶栏分屏只在落点有效时创建一个会话，不重连原 shell 或重放输入；源空标签移除，其余源树折叠并保留有效焦点，单次发布/保存两端结果，目标激活并聚焦移入源的原焦点。拖回顶栏时叶成为独立标签，单叶源仅排序。`workspace.moveTerminal` / `workspace.detachPane` 是本地布局 Capability，默认不向 Agent 开放；指针移动、hover 与落点预览留在 UI。

恢复保存布局、typed SSH/local target 引用和当前标签，默认恢复为 disconnected 标签；兼容旧版 host 快照。本地只保存 shell 标识与可执行路径，启动参数由代码按 shell 类型固定，不保存环境、输入或回滚，不因恢复自动运行 shell；SSH 自动连接独立开关且默认关。无凭据、原始输出、临时主机秘密进入恢复文件。重连不重放输入、广播或旧命令。

验收：T-01 VT/TUI；T-02 IME/快捷键；T-03 背压与隐藏；W-01 树与焦点；W-02 恢复与生命周期。

## 4. files：SFTP 与传输（M2）

### 浏览与操作

独立 SFTP 标签默认本地/远程双栏；终端侧面板为同组件的单栏远程视图。切视图不会取消任务。列表含名称、修改时间、大小、类型、权限/所有者（可隐藏）；目录优先、名称筛选、隐藏文件开关、前后导航、面包屑兼路径输入、每主机书签。

支持上传/下载、创建文件/目录、重命名、删除、复制路径、chmod（服务端支持才启用）。不为了“快速删除”偷偷拼 `rm -rf`。OS 拖入上传与选择文件走同任务队列；原生拖出、远程到远程复制、压缩上传、SCP fallback、sudo SFTP 延后。

文件选择采用 Shift 范围、Ctrl/Cmd 多选；Enter 打开目录或外部编辑流程、Backspace 上级、F2 重命名、F5 刷新、Delete 删除确认、Ctrl/Cmd+A 全选、Ctrl/Cmd+L 编辑路径（点当前目录的路径段或路径栏空白处也可）、可打印字符前缀定位。输入框或模态框聚焦时列表快捷键不执行。

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
- 协议 open 15s、请求无进展 30s，可配置慢链路值；不为整个 1GB 文件设统一 30s 截止时间。进度 UI 最多约 5Hz 更新，速度以 3 秒滑动窗口计算，窗口内的采样至少间隔 100ms（每个数据块都记一次会在高速传输时让 UI 线程忙于整理采样）。
- 使用独立 transfer channel 或受限连接以保护终端延迟；复用 route/auth/trust 仍需校验。占用全连接带宽时不能只加更多 channel 声称隔离。
- 开始前重新 stat 源和目标；目录扫描有条目/深度上限、渐进进度。默认不递归跟随符号链接。
- 写 .part → 验证 → 安全发布，细则见 SECURITY。取消先停新请求、等待有限在途操作收束，再关闭本任务资源；不能 end 共享 transport 导致 terminal 掉线。
- 冲突提供跳过、保留副本、替换、取消任务；目录提供合并（仍逐项处理冲突）。应用于全部限定当前批次及同类型冲突。
- size+mtime 快速跳过是可选优化，默认关闭；不能当哈希校验。不可读取目标属性、未知文件类型、权限错误都不当作不存在。
- M3 续传只在源身份未变、part 存在且 checkpoint 合法时启用；checkpoint 只能覆盖连续已确认范围，不能取最大完成 offset。不得假定并发分块中间没有洞。
- 远端回执丢失但可能写入时结果为 attention；重新确认源/part 后才能续传。目录恢复逐项验证，不仅靠队列 JSON 猜测已完成。
- 历史保留最多 200 个终态任务/30 天（先到者），未完成任务不自动删除；任务完成不表示临时清理一定成功，分别显示警告。

### 外部编辑

下载到私有副本 → 系统默认或指定编辑器打开 → watcher + debounce → 同步修改。新稿默认保存时自动上传，用户可对本稿关闭并改为手动上传；历史稿保留已保存的开关。

保存前重新验证远端基线，冲突时保留本地稿并提供重新下载/另存/明确覆盖；原子保存后 watcher 重新绑定，上传期间新保存用 generation 串行追上最新版本。默认不转换编码/换行；失败稿跨重启可恢复，结束与退出提示未上传稿。默认应用、可靠关闭跟踪、失败保稿与清理边界只在 EXTERNAL_EDITS 维护；真实编辑器验收见 TESTING。

### 当前实现

- 本机和远端共用 `FileSystem` 接口（`lib/foundation/file_system.dart`）：远端由 `TransportLease.openFiles()` 开一个 SFTP channel，本机用 dart:io。路径按各自语法拼接，远端一律 POSIX。
- 主机库旁固定的 SFTP 页是左右双栏，每栏可选本机或任一主机；终端标签可打开文件面板（同一组件的单栏，跟随焦点 pane 的主机）；停靠在下方时左边加一栏目录树（宽 240，从 `/` 起按需列出子目录，当前路径的祖先自动展开，点目录即进入），右边是列表。面板打开时跟随终端目录（§3），打开时也从终端目录开始；用户在面板里另去别处后，只有终端目录再变化才会跳回。拖到另一栏、发送到另一侧、OS 拖入、选择文件上传都进同一队列。没有每主机书签；所有者/组取自 SFTP longname，没有就留空。
- TransferManager 持有任务。每台主机的传输共用一个与浏览分开的 SFTP channel；全局并发取设置（默认 3），每主机 2；单文件 32 KiB 请求、最多 16 个在途。30s 没有进展判为停滞并失败。
- 单文件暂停与续传（`docs/TRANSFER_RESUME.md`）：running → pausing → paused；暂停停读源、等写入收束后 stat `.part` 记稳定长度，只记 settled checkpoint。续传前重新 stat 源（类型/大小/修改时间变了报 sourceChanged），`.part` 必须是本任务 ID 派生的同目录文件且长度与 checkpoint 一致，否则 partInvalid；从偏移读源、只向已存在的 `.part` 追加，最后沿用原子发布与替换基线检查。取消、移除、从头重试先清理本任务拥有的 `.part`，清理失败保留记录并显示路径（leftoverPart）。暂停/中断任务保留目标锁，不占并发与 SSH 租约；正常退出时单文件停在 paused（重启后为 interrupted，可手动恢复），目录不暂停也不续传。SFTP 续传的哈希一致性等真实服务器验证见 TESTING §6。
- 写到目标旁的隐藏文件 `.名称.随机.part`（排他创建），写完 stat 核对长度再发布；可暂停的单文件改用 `.名称.任务ID.part`，重启后能再找到。目标不存在时 rename；dartssh2 在服务器支持 posix-rename 时 rename 会覆盖，所以先确认目标不存在，两步之间有竞态窗口。替换只在服务器支持 `posix-rename@openssh.com` 时进行，发布前再 stat 目标，大小或修改时间变了就放弃；不支持时保留原文件并报错。本机替换用 File.rename。
- 冲突：跳过、保留两者（`名称 (1).ext`）、替换、取消；目录另有合并。“应用于全部”只作用于同一批次的同类冲突。目录扫描深度 32、条目 20000 上限，不跟随符号链接（跳过并计数）。
- 删除目录逐项走 SFTP，确认框写明条目数；不拼 `rm -rf`。
- transfers.json 只存白名单字段；重启时未完成的任务变为 interrupted，带 settled checkpoint 的可恢复续传，其余可从头重试；终态保留 200 个/30 天，带 checkpoint 的记录不因清空或裁剪被悄悄丢弃。
- 外部编辑私有副本位于数据目录 `edits/<id>/`，目录 watcher 防抖 500 ms；edits.json 保留未上传稿及其开关，重启后恢复。完整生命周期见 EXTERNAL_EDITS。
- 关窗经 ShutdownCoordinator：有进行中的传输或未上传的编辑时先询问。

验收：F-01 浏览/文件名/链接；F-02 完整性与冲突；F-03 取消与共享连接；F-04 恢复续传；F-05 外部编辑；P-03 大文件/大目录。

## 5. forwarding（M3）

规则是持久化配置，运行 tunnel 是单独实例。规则含 id/revision、hostId、kind(local/remote/dynamic)、listenAddress/port、destination（适用时）、autoStart、autoReconnect。后两项独立且默认 false。

- 默认绑定 loopback；0.0.0.0/:: 是扩大网络暴露的显式选择，UI/AI 都要预览。
- 动态 SOCKS5 首期范围为经验证的 CONNECT；不暗示支持 UDP、完整代理认证或浏览器代理自动配置。
- state：stopped → starting → running → stopping → stopped，失败为 failed。停止需确认本地/远端 listener 解除，不仅归还 lease。
- 撤销远端监听超时应显示 stopFailed/状态未知；若必须断 transport，先说明关联会话影响，再执行用户选择。
- 手动 stop 取消重连意图；自动重连沿用 connections 的有界策略。端口占用、权限不足、服务端拒绝转发分别提示。

当前规则存 forwards.json，规则对象没有独立 revision 字段。运行中的规则持有 purpose 为 forward 的租约，与终端、SFTP 共用连接，关闭终端不影响转发；本地与动态监听走 `ForwardRuntime`（dart:io 只在 `adapters/`），远端监听用 tcpip-forward，停止时等服务器确认取消，确认不了显示 stopFailed。默认绑定 127.0.0.1，其他地址在表单和列表标出“对外开放”，保存前确认（已保存且地址未变不重复询问）。动态转发仅为无认证的 SOCKS5 CONNECT，支持域名、IPv4、IPv6。`Forwards.autoStart()` 在启动时调用一次；`autoReconnect` 仅连接断开时按 1/2/4/8/16 s 重试 5 次，手动停止、认证失败和主机密钥问题不重试。

约束：每条规则最多接收 128 个并发连接（包括握手和拨号中的连接），超出的直接关闭并记 limit；SOCKS5 握手及本机目标 TCP 拨号最多等待 15 s。错误发生在单个转发连接时只关闭该连接，规则继续监听并保留最近错误。停止确认失败时保留转发租约与失败状态，禁止直接重新启动、编辑或删除规则；只有确认解除监听或 SSH transport 已断开后才释放租约，断开后再次停止即可收尾。转发能力（forward.list/save/delete/start/stop）均不向 AI 开放（`agentExposed` 为 false）。

规则管理入口、命令面板、退出 `shutdown()` 与启动 `autoStart()` 由组合层接入。本进程内重复监听的 Dart 错误码 -1 也归类为端口占用，不能只识别操作系统错误码。验证覆盖 SOCKS5 解析、relay 半关闭与挂断、租约与状态生命周期、有界重连、连接上限、暴露确认、持久化和退出协调；真实 L/R/D 通路及尚未验证的界面/断线重连见 TESTING，模拟通道不代替实网验收。

验收：R-01 L/R/D 正反向通路；R-02 stop/重连/共享资源；R-03 loopback 与端口冲突。

## 6. snippets（M3）

保存 label、text、tags、order；默认“插入终端待用户 Enter”，执行另有明确动作。变量模板后续添加，需明确文本替换不是安全 shell 参数转义。首期不做脚本 runtime、输出触发器、登录自动执行或批量广播。

当前实现（运行结果见 TESTING §6）：snippets.json 按保存顺序存 id、label、text、tags；面板提供搜索、增删改，单个片段最多 64 KiB 文本。面板通过 typed 用例调用插入，命令面板经 `snippet.insert` 能力调用同一用例，把文本粘到焦点终端；“运行”在插入后再发回车。与剪贴板共用 TerminalSession 的受控粘贴入口：多行按设置确认，控制字符和运行始终确认，预览显示目标与控制字符；确认绑定当时的 shell，断线、关闭或重连后不向新 shell 发送。没有可用终端或确认 UI 时拒绝发送。受控插入入口和片段能力不开放给 AI。

实现约束：终端公开 typed insert 用例；多行按 confirmPaste 设置确认，控制字符与运行始终确认，确认绑定原 shell 与租约，取消、断线或重连后拒绝迟到输入。片段模块不依赖 workspace，焦点终端与确认入口由 app 注入，避免循环依赖。保存串行且落盘成功后发布；不展开模板，不记录片段执行内容。关闭片段面板取消尚未发送的插入；退出等待片段写入队列。确认窗口跟随插入取消关闭，避免取消后留下失效对话框；会话结束时同样撤销当前 shell 的待确认插入。

AI 使用片段执行仍经过 command 策略，不能用 snippet.run 绕过审批。M5 广播必须持续显示目标，切换选择不静默扩大范围，多行粘贴统一确认。

## 7. settings 与应用外壳（M1）

SettingDefinition 统一记录 key/type/default/range/effect/applyMode/agentExposure；不是所有设置都自动生成界面。简单值可通用表单，密钥、快捷键和代理等复杂流程用专门组件。

实现为 `SettingDef`（`lib/features/settings/settings.dart`）：`settings.patch` 的 schema 和校验都由它生成，全部成功才写入；agent 来源看不到也改不了 `agentExposed: false` 的项（渲染器、粘贴确认）。其他 feature 的分区（如信任记录）通过 `SettingsSection` 在 composition 注入，settings 不反向 import 它们。

| 分区 | 首期设置与行为 |
|---|---|
| 外观 | system/light/dark、强调色（预设，默认蓝，UI §2）、界面字体（系统已安装字体，默认 Segoe UI + Microsoft YaHei UI）与界面字号（默认 13，11–18）；即时生效。Windows 渲染器 Skia/Impeller（ADR-11），重启生效 |
| 终端 | 字体（系统等宽字体，默认 Cascadia Mono）/字号（初值 14 logical px）、光标、回滚、选中复制（默认关）、右键行为、粘贴确认 |
| 工作区 | 显示服务器监控（默认开）、监控刷新间隔（1/2/3/5/10 秒，默认 3）、监控面板宽度（240–400，默认 240）、文件面板停靠（左/右/下，默认右）、导航展开状态与宽度（176–320，默认收起、200）、退出前确认（默认开，不开放给 AI） |
| 连接 | 超时、保活、idle TTL、自动重连；标明下次连接生效 |
| 文件 | 并发、隐藏文件、默认外部程序；覆盖默认询问；新外部编辑稿保存时自动上传，可按稿关闭 |
| 快捷键 | 列出全部全局动作，按组合修改、冲突检测、逐项恢复默认；即时生效并持久化 |
| 数据与安全 | 数据目录、备份/恢复入口、信任管理；禁止由 AI 任意修改 |
| 关于 | 版本、许可、诊断导出（脱敏）、更新说明 |

首发中英文 ARB；错误、空状态和工具提示也国际化。连接日志仅记录步骤和脱敏错误，完整终端录制另设显式开关。

命令面板负责主机/会话/已注册能力搜索，AI 阶段新增“交给 AI”明确动作；**搜索不到时不自动把文本发给模型**。

一期单主窗口，设置在窗口内居中弹窗打开（UI §1）；多窗口、托盘、自动更新不作为首版前置。退出经 ShutdownCoordinator，不因关窗让上传、编辑稿或配置悄悄丢失；`confirmQuit` 开着时每次退出都先确认，并列出将断开的会话数。

Windows 打包：`tool/package_windows.ps1` 构建 Release，将完整 runner 输出、README 和第三方许可证清单打成带时间戳的 ZIP（`dist/`，不覆盖旧包）。`tool/write_notices.dart` 从已解析的依赖读取 LICENSE/NOTICE，缺失时失败而非遗漏。当前只供本地验证，不代表已签名或正式发行；项目许可证未确定前不宣称 MIT 授权。

验收：S-01 范围与 applyMode；U-01 键盘/焦点/视觉；D-01 关闭/持久化。

## 8. monitor：服务器监控（2026-11-07 加入，原列在 M5）

终端标签左侧的监控面板（UI §1）。只读，不是 Capability，也不开放给 AI。

- 数据来源：在该 pane 的主机已连接时，向 ConnectionManager 取 `LeasePurpose.exec` 租约（与终端共用同一条连接，不另行拨号；需要询问主机密钥或口令时一律拒绝，显示不可用），按设置 `monitorInterval`（1/2/3/5/10 秒，默认 3，面板顶部可直接切换）执行只读命令。命令由固定片段组成，不拼接任何主机、路径或用户输入：基础片段读 `/proc/stat`（总计与各核）、`/proc/meminfo`、`/proc/loadavg`、`/proc/uptime`、`/proc/net/dev`、`df -kPTl`（不支持时回退 `df -kPl`）、页大小与时钟频率，以及每个进程 `/proc/<pid>/stat` 中的状态、父进程、CPU 时间、线程数、启动时间、常驻内存和名称（awk 压缩为一行一个进程），并探测是否有 NVIDIA（`nvidia-smi`）或 AMD（`/sys/class/drm` 厂商 0x1002）显卡；进程窗口打开时追加 `ps` 的用户和完整命令行；GPU 页可见时才追加显卡查询。输出上限 1 MiB。
- 解析（`monitor/domain/stats.dart`、`monitor/domain/gpu.dart`，纯 Dart，有单元测试）：CPU 利用率、各核利用率与各网卡速率按两次采样的差值计算；网络默认合计除 `lo` 外的接口，可在面板里选单个网卡；进程 CPU 按 top 的口径（相邻两次采样的进程 CPU 时间差 ÷ 总 CPU 时间差 × 核数，100% 为一个核），进程号重用由启动时间区分；磁盘去掉 tmpfs、devtmpfs、overlay、squashfs 与 `/dev/loop*`、`/snap/` 挂载；最近 60 个采样画折线。CPU/内存/GPU 百分比历史按每条曲线自己的可见最小/最大值自动缩放，留出上下余量，最小跨度为 1 个百分点以免放大采样噪声；悬浮可看该曲线的实际范围，环形图仍显示真实百分比。网络上下行共享从 0 开始的动态量程，保持可比较。非 Linux（没有 `/proc`）显示不支持。
- 面板（默认 240 宽，可在 240–400 调整，信息密度参照 FinalShell）：主机名与刷新间隔；IP（可复制）、运行时长、负载；CPU、内存、交换三个环形图（中心百分比，下方已用/总量）；5 个进程预览（内存、CPU、名称）：三列表头（标题与排序箭头）及内容在各自列内居中，排序箭头固定预留位置，切换排序不挪动标题；名称行与表头保留相同的展开按钮空位；点列头切换排序，同一列再次点击切换升/降序，列头箭头显示方向；默认 CPU 降序、同值按内存降序。先对全部采样进程排序再取 5 个，排序在刷新时保留，同值用 PID 稳定排序；点进程行或展开按钮打开进程窗口；网络上下行速率、网卡选择与折线；磁盘表（逐个已挂载本地文件系统显示设备、挂载点、可用/总量，按设备去重 bind mount；优先读取 `df -kPTl` 的文件系统类型，跳过内存/虚拟文件系统和 snap，不因 `/run/media` 等挂载位置而丢掉真实数据分区；未挂载分区没有可用空间统计）。检测到显卡时顶部出现“系统 | GPU”分段切换，GPU 页参照驱动自带面板：每块卡显示名称、利用率与显存环形图、温度、功耗/上限、风扇、核心与显存频率、利用率折线，以及占用该卡的进程（PID、用户、显存、名称）。
- 进程窗口（居中大对话框，像 htop 但用鼠标操作）：顶部各核利用率条、内存、交换、任务数与负载；下方是全部进程表（PID、用户、CPU、内存%、常驻内存、状态、线程、运行时长、命令），可搜索、点列头排序、暂停刷新；表头右边界可拖动调整各列宽度，表头和数据行共用列宽，按列设置最小宽度并限制单列不超过当前表格视口（最小宽度优先），总宽超出时水平滚动。边界显示横向调整指针，聚焦后左右键步进、语义增减，双击恢复该列默认宽度；拖动不触发排序。列宽仅在本次窗口中保留，不新增持久化设置。选中行跟随 PID 不跳动。右键可复制 PID 或命令、结束进程（SIGTERM）或强制结束（SIGKILL），结束前确认。结束进程是 monitor 的 typed 用例（PID 为整数、信号为枚举，命令由常量拼成），不登记为 Capability，不开放给 AI；权限不足时显示服务器返回的错误。
- AI 固定诊断使用独立的 `DiagnosticTemplate`、常量采集与纯投影（`monitor/domain/diagnostics.dart`），不读取本面板/进程快照、不启动轮询。主机、模板和字段授权及生命周期由 Agent runtime 持有，见 AI §7/11；首批 system/storage 的具体完成范围见 ROADMAP。
- 首次采样：面板启动时立即尝试采样；若此时 SSH 尚未建立，监听连接管理器的认证完成通知，在该主机连接成功后立即采样，不等待设置的刷新间隔。重连同样触发首次采样；并发触发不重叠执行，隐藏/停止后取消通知监听。CPU/网速仍由相邻两次真实样本计算，首样本不伪造差值。
- 生命周期：面板显示且所在标签激活时轮询；标签切走、面板关闭或会话断开时停止并归还租约，因而不会让本该停泊关闭的连接一直活着。单次执行超过 10 秒视为失败，连续失败时保留上次数据并标出。
- GPU：NVIDIA 用 `nvidia-smi --query-gpu` 与 `--query-compute-apps`（各 5 秒超时，`[N/A]` 显示为“–”）；AMD 读 amdgpu 的 sysfs（`gpu_busy_percent`、`mem_info_vram_*`、hwmon 温度/功耗/风扇），进程来自 `/proc/<pid>/fdinfo` 的 `drm-*` 字段（只看得到当前用户有权读取的进程），名称在有 `lspci` 时取自它。其他显卡不显示 GPU 页，不显示假数据。

验收：解析、差值与进程 CPU 计算有单元测试；在作者的 Ubuntu 服务器上实际显示需实机验收；GPU 只有构造的输出样本，没有真实显卡验证。
