# 主机导入（2026-11-08）

把其他 SSH 客户端或文件里的主机元信息导入主机库。只读本机文件和注册表，不连接服务器、不执行配置里的命令，也不读私钥内容。参考 Netcatty 的入口形式（首次引导、弹窗里选来源），实现自有，不复制代码。SSH config 的细则仍见 `SSH_CONFIG_IMPORT.md`。

## 入口

- 主机库工具栏的导入按钮（`Icons.input_rounded`），打开居中对话框（`AppDialog`），不用侧边抽屉。
- 首次启动：主机库为空且设置 `importOffered` 为 false 时自动打开一次，底部按钮是“跳过”；打开时即写 `importOffered = true`，之后不再自动出现。该设置 `agentExposed: false`，AI 看不到也改不了。

## 来源

对话框第一步：上方是“从文件导入”（任意文件，按内容识别格式），下方是各软件的方块，使用独立绘制的简化 SVG 标识（OpenSSH、PuTTY、MobaXterm、SecureCRT、Xshell、FinalShell、Tabby；CSV 使用表格文件图形），不再用名称前两个字母代替图标，保留文字名称与所需文件/目录名。图形是导入来源识别用途，不复制 Netcatty 素材；SVG 随应用打包，不联网获取。检测已知位置的主机数量；有结果可直接预览，没有结果先展示该来源的选取指引、示例路径与选择按钮，再打开系统选择器，不能让用户猜测应选哪个目录。预览中可重新选择来源文件或文件夹。

FinalShell 自动发现覆盖用户配置目录、Program Files、本地 Programs、系统盘根目录和 macOS app bundle 等已知位置；Windows 额外只读查询固定 App Paths 与名称匹配 FinalShell 的卸载信息（InstallLocation/DisplayIcon），不全盘搜索，不执行安装程序/卸载命令。跳过空目录，采用第一个含主机的来源，不合并不同来源；自定义便携目录可手动选择。预览显示真实来源路径，可重新选择。

| 来源 | 默认位置 | 读取内容 |
|---|---|---|
| OpenSSH | `~/.ssh/config` | 沿用 SSH config 解析（Include、ProxyJump、IdentityFile） |
| PuTTY | Windows 注册表 `HKCU\Software\SimonTatham\PuTTY\Sessions`；或 regedit 导出的 `.reg` | HostName、PortNumber、UserName、Protocol、PublicKeyFile。会话名按 PuTTY 的百分号编码解码 |
| MobaXterm | `%APPDATA%\MobaXterm\MobaXterm.ini`；或 `.mxtsessions` 导出 | `[Bookmarks*]` 节中 `#109#` 类型（SSH）的会话：地址、端口、用户名；`SubRep` 作为分组 |
| SecureCRT | `%APPDATA%\VanDyke\Config\Sessions` | 每个 `.ini`：`S:"Hostname"`、`S:"Username"`、`D:"[SSH2] Port"`（十六进制）、`S:"Protocol Name"`；子文件夹作为分组，跳过 `__FolderData__.ini` 与 `Default.ini` |
| Xshell | `文档\NetSarang Computer\*\Xshell\Sessions` | 每个 `.xsh`（常为 UTF-16）：`[CONNECTION]` 的 Host、Port、Protocol，`[CONNECTION:AUTHENTICATION]` 的 UserName；子文件夹作为分组 |
| FinalShell | 已知用户/安装目录的 `conn`，Windows 安装信息；macOS app bundle；Linux `~/.finalshell/conn` 等 | 每个 `*_connect_config.json`：name、host、port、user_name；选中来源后可迁移支持的 password |
| Tabby | `%APPDATA%\tabby\config.yaml`、`~/Library/Application Support/tabby/config.yaml`、`~/.config/tabby/config.yaml` | `profiles` 中 `type: ssh` 的 name、group、options.host/port/user、首个 privateKeys（`file://` 或路径） |
| CSV | 无 | 第一行是表头，按列名识别：名称（name/label/alias/名称）、地址（host/hostname/address/ip/主机/地址，必填）、端口、用户名、分组（group/folder/分组）、密钥路径（key/identityfile/密钥）；RFC 4180 引号 |

- 注册表经 `%SystemRoot%\System32\reg.exe query <固定路径> /s` 读取：固定参数、不经 shell、只读。其他平台没有 PuTTY 方块。
- 文件识别：`.reg` 头或 PuTTY 注册表路径 → PuTTY；`[Bookmarks` 与 `#109#` → MobaXterm；`S:"Hostname"=` → SecureCRT；`[CONNECTION]` 与 `Host=` → Xshell；带 host 和 user_name 的 JSON → FinalShell；带 `profiles:` 的 YAML → Tabby；首行像表头的逗号分隔文本 → CSV；其余按 SSH config。选文件夹时按扩展名找 SecureCRT、Xshell、FinalShell 的会话文件。
- 解码：带 BOM 的 UTF-8/UTF-16 按 BOM；否则先试 UTF-8，失败按系统代码页（中文 Windows 为 GBK）。
- 上限：单文件 2 MiB（SSH config 仍为 1 MiB 总量）；文件夹深 8 层、最多 4096 个文件、共 16 MiB；每次最多 512 台主机，超出部分报告。

## 登录信息

FinalShell 支持 `authentication_type` 缺省或为 `1`、无 `secret_key_id` 的旧式 Base64（8 字节头 + DES/ECB/PKCS5Padding）已保存登录密码；只用于本机用户主动选择的连接来源。实现独立依据公开格式整理，密码不显示、不导出。自动发现不解码；预览重新读取所选来源，仅输出逐项“已找到密码/连接时输入”等状态；提交重新读取并核对主机元信息，内存解码、写入系统安全存储，最后一次 revision 校验提交主机库。已有密码不覆盖；已有同端点/用户/路由且直接使用密码认证的主机可再次选中补齐。未知编码、未保存密码、密钥认证引用不当作可迁移密码，仍可导入元信息，连接时补充登录。

来源重新选择、返回或关闭会释放预览引用；预览不保存配置原文或秘密。Dart String 不能保证物理擦除，不宣称内存安全擦除。

公开格式参考：[旧式密码编码](https://mg-freedom.org/mg/finalshell-decrypt-password/)、[私钥引用字段说明](https://github.com/BitsFlowCloud/DengShell/blob/main/build/FINALSHELL-IMPORT.md)。仅以合成配置验证算法及失败处理；未验证作者的真实 FinalShell 版本。

## 暂不支持

- 其他软件的密码、私钥口令，以及 FinalShell 的专有密钥库引用（`secret_key_id`）。这类记录提示连接时补充登录信息，不把旧账号密码当作密钥口令。有已知可用密钥路径的其他来源继续保留路径。
- PuTTY 的 `.ppk` 密钥路径不写入主机（dartssh2 不读 PPK），在报告里提示先转换。
- 非 SSH 会话（Telnet、RDP、串口等）列入报告，标为“不是 SSH 会话”。
- 代理、端口转发、终端外观、脚本等其他设置。各软件的跳板配置目前只有 OpenSSH 的 ProxyJump 会导入。

## 预览与提交

第二步：返回按钮与来源名、目标分组选择（不放入分组或已有分组），然后是主机列表。

- 每项显示名称、`用户@地址:端口`、来源分组、可迁移登录信息状态；已存在（同地址、端口、用户名、路由）的仅在可补登录信息时允许勾选，无法导入的标出原因。
- 来源分组保留在目标分组之下（`目标/来源`）。
- 无法读取的文件、被跳过的会话、超出上限都在列表下方列出，带文件名。
- 提交沿用 `HostsNotifier.importDrafts`：主机串行队列持有期间核对来源并迁移密码，凭据串行队列先只补缺失，再一次 revision 校验写入主机库；失败回收本次尝试写入的引用。预览期间主机库变了就要求重新选择；已有代理路由不接受直接来源的密码。凭据回收失败单独提示，不静默当作成功。
- 关闭对话框不保存任何东西。

## 测试

每种解析器都有单元测试（构造样例：注册表查询输出与 `.reg`、MobaXterm 书签、SecureCRT/Xshell 会话、FinalShell JSON、Tabby YAML、CSV 引号与中文表头），文件识别、编码、上限、首次引导和对话框流程有组件测试。新增的安装位置/注册表发现使用合成数据和临时目录；密码使用独立 PyCryptodome DES 生成的合成样本，覆盖 Unicode、负头字节、填充、未知格式、UTF-16 BOM、重复导入、代理端点拒绝、来源变化、revision 冲突、存储写后报错和不完整回收。组件测试覆盖 960×640 下的来源指引、重选路径、已有主机补密码与迁移开关。各软件的真实安装、默认位置和作者的 FinalShell 版本未验证；新流程没有连接真实服务器。
