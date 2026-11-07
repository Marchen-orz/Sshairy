# 主机导入（2026-11-08）

把其他 SSH 客户端或文件里的主机元信息导入主机库。只读本机文件和注册表，不连接服务器、不执行配置里的命令，也不读私钥内容。参考 Netcatty 的入口形式（首次引导、弹窗里选来源），实现自有，不复制代码。SSH config 的细则仍见 `SSH_CONFIG_IMPORT.md`。

## 入口

- 主机库工具栏的导入按钮（`Icons.input_rounded`），打开居中对话框（`AppDialog`），不用侧边抽屉。
- 首次启动：主机库为空且设置 `importOffered` 为 false 时自动打开一次，底部按钮是“跳过”；打开时即写 `importOffered = true`，之后不再自动出现。该设置 `agentExposed: false`，AI 看不到也改不了。

## 来源

对话框第一步：上方是“从文件导入”（任意文件，按内容识别格式），下方是各软件的方块。启动时只检查默认位置是否存在，方块上显示找到的会话数；点击时有默认位置就直接读，没有就打开文件或文件夹选择器。

| 来源 | 默认位置 | 读取内容 |
|---|---|---|
| OpenSSH | `~/.ssh/config` | 沿用 SSH config 解析（Include、ProxyJump、IdentityFile） |
| PuTTY | Windows 注册表 `HKCU\Software\SimonTatham\PuTTY\Sessions`；或 regedit 导出的 `.reg` | HostName、PortNumber、UserName、Protocol、PublicKeyFile。会话名按 PuTTY 的百分号编码解码 |
| MobaXterm | `%APPDATA%\MobaXterm\MobaXterm.ini`；或 `.mxtsessions` 导出 | `[Bookmarks*]` 节中 `#109#` 类型（SSH）的会话：地址、端口、用户名；`SubRep` 作为分组 |
| SecureCRT | `%APPDATA%\VanDyke\Config\Sessions` | 每个 `.ini`：`S:"Hostname"`、`S:"Username"`、`D:"[SSH2] Port"`（十六进制）、`S:"Protocol Name"`；子文件夹作为分组，跳过 `__FolderData__.ini` 与 `Default.ini` |
| Xshell | `文档\NetSarang Computer\*\Xshell\Sessions` | 每个 `.xsh`（常为 UTF-16）：`[CONNECTION]` 的 Host、Port、Protocol，`[CONNECTION:AUTHENTICATION]` 的 UserName；子文件夹作为分组 |
| FinalShell | Windows `%LOCALAPPDATA%\finalshell\conn`，macOS `~/Library/FinalShell/conn`，Linux `~/.finalshell/conn` | 每个 `*_connect_config.json`：name、host、port、user_name |
| Tabby | `%APPDATA%\tabby\config.yaml`、`~/Library/Application Support/tabby/config.yaml`、`~/.config/tabby/config.yaml` | `profiles` 中 `type: ssh` 的 name、group、options.host/port/user、首个 privateKeys（`file://` 或路径） |
| CSV | 无 | 第一行是表头，按列名识别：名称（name/label/alias/名称）、地址（host/hostname/address/ip/主机/地址，必填）、端口、用户名、分组（group/folder/分组）、密钥路径（key/identityfile/密钥）；RFC 4180 引号 |

- 注册表经 `%SystemRoot%\System32\reg.exe query <固定路径> /s` 读取：固定参数、不经 shell、只读。其他平台没有 PuTTY 方块。
- 文件识别：`.reg` 头或 PuTTY 注册表路径 → PuTTY；`[Bookmarks` 与 `#109#` → MobaXterm；`S:"Hostname"=` → SecureCRT；`[CONNECTION]` 与 `Host=` → Xshell；带 host 和 user_name 的 JSON → FinalShell；带 `profiles:` 的 YAML → Tabby；首行像表头的逗号分隔文本 → CSV；其余按 SSH config。选文件夹时按扩展名找 SecureCRT、Xshell、FinalShell 的会话文件。
- 解码：带 BOM 的 UTF-8/UTF-16 按 BOM；否则先试 UTF-8，失败按系统代码页（中文 Windows 为 GBK）。
- 上限：单文件 2 MiB（SSH config 仍为 1 MiB 总量）；文件夹深 8 层、最多 4096 个文件、共 16 MiB；每次最多 512 台主机，超出部分报告。

## 不导入的东西

- 密码、口令及其加密或混淆形式（PuTTY 不存密码；MobaXterm、SecureCRT、Xshell、FinalShell、Tabby 的密码字段一律忽略）。导入的主机认证方式：有密钥路径为密钥，否则为密码，连接时照常询问并经 HostTrustService。
- PuTTY 的 `.ppk` 密钥路径不写入主机（dartssh2 不读 PPK），在报告里提示先转换。
- 非 SSH 会话（Telnet、RDP、串口等）列入报告，标为“不是 SSH 会话”。
- 代理、端口转发、终端外观、脚本等其他设置。各软件的跳板配置目前只有 OpenSSH 的 ProxyJump 会导入。

## 预览与提交

第二步：返回按钮与来源名、目标分组选择（不放入分组或已有分组），然后是主机列表。

- 每项显示名称、`用户@地址:端口`、来源分组；已存在（同地址、端口、用户名、路由）的默认不选且不可选；无法导入的标出原因。
- 来源分组保留在目标分组之下（`目标/来源`）。
- 无法读取的文件、被跳过的会话、超出上限都在列表下方列出，带文件名。
- 提交沿用 `HostsNotifier.importDrafts`：一次 revision 校验写入；预览期间主机库变了就要求重新选择。
- 关闭对话框不保存任何东西。

## 测试

每种解析器都有单元测试（构造样例：注册表查询输出与 `.reg`、MobaXterm 书签、SecureCRT/Xshell 会话、FinalShell JSON、Tabby YAML、CSV 引号与中文表头），文件识别、编码、上限、首次引导和对话框流程有组件测试。各软件的真实安装与默认位置没有在作者机器上验证；FinalShell、MobaXterm 的字段按公开的配置样例整理，可能随版本变化。
