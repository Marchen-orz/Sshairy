# 终端远程路径补全来源

2026-11-08：给终端补全提供“某个远程目录里有哪些条目”。只读、只列目录，不执行命令，不写终端；调用方（TerminalSession 与补全 UI）决定何时查、怎样插入。实现在 `terminal/domain/terminal_paths.dart`（规则、缓存、查询调度）与 `terminal/adapters/terminal_paths.dart`（SFTP 读取），已接入 TerminalSession 与候选层级浏览。

## 数据来源

| 项 | 实际情况（2026-11-08 读源码） |
|---|---|
| 入口 | `TransportLease.openFiles()` 返回 foundation 的 `FileSystem`，没有 `openSftp`；`close()` 只关这条 SFTP channel，不动 transport 和其他 channel |
| `FileSystem.list(dir)` | 一次返回完整 `List<FileEntry>`：无流式、无上限、不可取消，对每个符号链接顺序 `stat`。文件功能在用，保持不变，补全不走它（回退除外） |
| `BoundedFileListing` | foundation 里与 `FileSystem` 并列的可选接口，`listBounded(dir, maxScanned, accept, cancel)` 返回 `BoundedListing{entries, scanned, complete}`；`SftpFileSystem` 额外实现它，走 dartssh2 的流式 `readdir` |
| 家目录 | `FileSystem.home()` 是 SFTP `realpath('.')`，即 SSH 登录用户的家目录 |

有界列目录（`SftpFileSystem.listBounded`）：

- 一次只有一个 READDIR 请求在途，批与批之间检查取消；`.` 与 `..` 不算条目。
- 最多读 `maxScanned`（4096）个名字。读到第 4097 个名字就停，`complete=false`；正好 4096 个且服务器随后报告结束，`complete=true`。
- `accept(name)` 在流中过滤：被拒的名字照计入 `scanned`，但不保留、不 `stat`。终端读取器传 `RemotePaths.validName`，非法名字不占内存也不触发 `stat`。
- 符号链接只对已保留的条目 `stat`（跟随链接，最多 16 个并行），判断是否指向目录；不在扫描范围内的条目一个都不 `stat`。服务器用状态码答复的失败（不存在、无权限、链接成环等）按“不是目录”处理；连接状态错误（`noConnection`、`connectionLost`）和传输层错误照常抛出。
- 前缀不在流里过滤：上限数的是读过的名字，按前缀筛只会少几次 `stat`，不会让扫描范围变大；而缓存按目录保存一次扫描，要让换前缀时直接可用。所以前缀、点文件、`foldersOnly` 都在缓存的列表上筛。

目录句柄：dartssh2 的 `readdir` 只在读到末尾时才关目录句柄，提前停止（达到上限）时它的私有 `_close` 调不到，句柄会一直开到 channel 关闭。因此契约是：`complete=false`、出错或取消之后，调用方要关掉这条 channel，服务器随之收回句柄。终端读取器自己拥有这条 channel，据此在未读完或被取消时立即丢弃它，下一次查询重开；`BoundedFileListing` 的其他调用方必须同样处理。

回退：`FileSystem` 没有该接口时（测试替身、本机文件系统）用 `list` 一次读完，再按同一上限截断，`complete` 照实报告。回退的内存不受限，界限只有浏览器的超时。

不用 exec：路径不拼进 shell，不需要转义，名字里的空格、引号、Unicode 原样经 SFTP 二进制字符串传递。

## 契约

查询 `RemotePathQuery{directory, prefix, foldersOnly}`，结果 `RemotePathResult`。

| 字段 | 含义 |
|---|---|
| `directory`（入） | 绝对路径 `/…`，或 `~`、`~/…`；相对路径、`~user`、`~+`、`~-` 一律 `invalid`。相对输入由调用方用可信 cwd 拼成绝对（`RemotePaths.absolute`） |
| `prefix`（入） | 用户已输入的最后一段，区分大小写的前缀；不含 `/` 与控制字符，最长 255 UTF-8 字节；可为空 |
| `foldersOnly`（入） | 只留目录和指向目录的符号链接 |
| `directory`（出） | 规范化并展开 `~` 后的绝对路径 |
| `entries` | 最多 200 项；目录（含指向目录的链接）在前，其后按 UTF-16 码元序排序，区分大小写 |
| `truncated` | 匹配项超过 200，或目录的名字超过 4096 个、没有读到末尾（此时没匹配到的名字也可能存在） |
| `generation` / `cached` | 来源构造时给定的连接代；是否来自缓存 |

条目 `RemotePathEntry{name, kind, path, linkToDirectory}`：`kind` 为 directory、file、symlink；套接字、设备、管道算 file。`enterable` = 目录或指向目录的链接，补全插入时据此决定是否带 `/`。断链或指向文件的链接是 symlink 且 `linkToDirectory` 为假，不再追踪。`path` 是 `child(directory, name)`，仅用于层级导航，插入终端的编码由调用方的解析器负责。

层级导航：向下查 `RemotePaths.child(result.directory, entry.name)`，向上查 `RemotePaths.parent(result.directory)`；两者都只是新的 `browse`，本模块不写终端。

失败 `RemotePathException(kind)`：

| kind | 来源 |
|---|---|
| `invalid` | 路径或前缀不合规 |
| `unavailable` | 租约已释放或连接丢失、来源已 dispose、打不开 SFTP channel |
| `denied`、`notFound`、`failed` | 服务器拒绝、不存在、其他失败（如对文件列目录） |
| `timeout` | 超过期限：浏览器整体默认 3 秒（含取家目录），读取器对每个请求也各有一个同样的期限 |
| `cancelled` | 调用方取消，或被更新的查询取代 |

候选框用本地化的简短状态区分加载、不可用、失败与空目录，不弹阻断式错误；终端连接照常工作。

## 路径与名称规则

- `directory` 原串最长 4096 个字符，规范化后最长 4096 UTF-8 字节、128 段；空段与 `.` 段去掉，`..` 保留不折叠，由服务器按物理路径解析（折叠会在符号链接处与服务器不一致）。孤立代理项、NUL、控制字符一律 `invalid`。
- 只有路径开头的 `~` 才是家目录；`/x/~` 里的 `~` 是普通目录名。
- 条目名丢弃：空、`.`、`..`、含 `/`、NUL、C0/DEL/C1 控制字符、换行、U+2028/2029、双向控制符（U+061C、U+200E/F、U+202A–E、U+2066–9）、含 U+FFFD（服务器的字节无法原样还原成 UTF-8）、超过 255 UTF-8 字节。被丢弃的名字永远不会出现在补全里。
- 以 `.` 开头的名字默认隐藏，`prefix` 以 `.` 开头才显示。
- 符号链接只做一次跟随链接的 `stat` 来判断是否指向目录，不递归、不继续追踪；只对扫描范围内、名字合规的链接做。

## 缓存与并发

- 缓存键是（连接代，展开后的目录）；TTL 5 秒；最多 16 个目录、合计最多 16384 条目，最近最少使用者先淘汰；单个目录超过 `maxEntriesPerDirectory`（默认 4096，与扫描上限相同）仍然作答，只是不缓存。缓存里是规范名字与类型，不含大小、属主、时间，另有“是否读到末尾”的标志，命中缓存时 `truncated` 照旧。
- 浏览器只取读取器给出的前 4096 个名字，多出的丢弃并按未读完算；读取器自己应当已经停在这个上限。
- `denied`、`notFound`、`timeout`、`failed` 同样缓存 5 秒，避免每个按键重试一个慢目录或无权限目录；`unavailable`、`cancelled`、`invalid` 不缓存。
- 同一目录的并发查询共享一次列目录；一次只跑一个列目录，更新的目录查询取代旧的（旧查询得到 `cancelled`），因此调用方只应查当前显示的目录。调用方取消只撤销自己的等待，没有等待者时才中止这次列目录。
- 中止 = 关闭这条 SFTP channel（`Future.timeout` 只停止等待，不算取消）；下一次查询重新打开。channel 惰性打开，空闲 10 秒关闭，租约丢失或 dispose 立即关闭。
- 除取消和超时外，读取器在有界扫描未读完、或扫描失败后也关闭 channel（目录句柄可能还开着，见“数据来源”）。目录打不开（不存在、无权限）不关：此时服务器上没有句柄。代价是下一次查询多一次开 channel。
- 家目录取一次后在来源存续期间沿用。

## 生命周期与安全边界

- 一个来源对应一个（租约，连接代）。会话连接成功后创建，shell 结束、租约更换或会话关闭时 `dispose()`；dispose 只关自己的 SFTP channel，不 acquire、不 release、不拨号，所以不可能产生未经 HostTrustService 校验的新连接。重连得到新租约，必须新建来源，旧缓存随之作废。
- 补全的目录必须来自调用方信任的来源：OSC 7 或已验证的目录提供器。tmux、su、sudo、嵌套 ssh 下外层 shell 的 cwd 不可信，此时不要拼相对路径。
- `~` 是 SSH 登录用户的家目录。shell 已切到别的用户（`su`、`sudo -i`）或改过 `HOME` 时与 shell 里的 `~` 不同，调用方在不能确认时不要发 `~` 查询。
- 服务器以登录用户身份列目录，可能比 shell 里的用户看到的少；这是只读辅助，不是权限判断。
- 条目名来自不可信的远端：只显示和插入，不当指令；不写日志、不进诊断、不发给 AI、不落盘。`CommandCompletionProvider`（含将来的 AI 来源）拿不到这里的列表。
- 不记录路径和名字；错误只带 kind。

## 测试

`test/terminal_paths_test.dart` 用假的 `RemoteDirectoryReader`、假的 `FileSystem`（普通与带 `BoundedFileListing` 两种）和手工构造的 READDIR 批次，不读任何真实文件系统，也不连服务器：

- 路径规范化与上下级、名称过滤（空格、Unicode、换行、控制字符、超长）、前缀与排序与 200 上限、点文件、符号链接。
- 缓存的 TTL/容量/代、未读完标志随缓存保留、读取器越过 4096 的名字被丢弃、单飞与取代、取消与超时关 channel、家目录展开、dispose。
- 读取器：优先走有界扫描并传入上限与名字过滤；未读完或失败后关 channel、读完不关、打不开目录不关；取消时把令牌交给扫描；回退到 `list` 时截到上限且不关 channel；两条路径的请求超时。
- `scanSftpDirectory`：跳过 `.`/`..`、恰好等于上限为完整、多一个名字为未读完且不再取下一批、被拒的名字照计数但不 `stat`、链接 16 个一组且上限之外不 `stat`、批间与窗口间的取消、链接查询失败向外抛。

2026-11-08 上述单元测试与终端层级浏览组件测试已运行通过，并包含在完整工程 698 项通过、1 项跳过的回归中；模块 import 检查通过。`SftpFileSystem.listBounded` 的真实 readdir/stat 接线、服务器延迟、提前停止后的句柄回收和符号链接密集目录仍未做真实服务器验收。符号链接最多 4096 个时，stat 按 16 个一组需要约 256 个往返，慢链路会先到期限而得到 timeout。

当前会话从 OSC 7 或已有的外层 shell cwd 查询取得目录；无法完整辨认 tmux、su、sudo -i、嵌套 ssh 和自定义 HOME 的身份切换。因此不能保证这些场景的相对路径和 ~ 与内层 shell 一致，不能将此处的来源要求误写成已实现的身份识别。已知该场景时应关闭候选（Esc）或使用明确绝对路径，后续需加可验证的 shell 身份协议。
