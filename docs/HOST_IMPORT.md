# 主机导入

从本机 SSH 客户端配置或文件导入主机元信息。只读文件和注册表，不连接服务器、不执行配置命令、不读私钥内容、不修改来源。入口参考 Netcatty，代码与素材独立实现。验证状态见 ROADMAP、TESTING。

## 入口与来源

主机库导入按钮打开居中 `AppDialog`。库为空且 `importOffered` 为 false 时自动打开一次，可跳过；打开即保存该标记，它不向 AI 暴露。第一步提供“从文件导入”和各软件来源，使用随包、自行绘制的简化 SVG 及文字，不联网获取标识。有已发现主机可直接预览，否则先说明所需文件/目录、示例路径，再打开选择器；预览可重新选择来源。

| 来源 | 默认位置 | 读取内容 |
|---|---|---|
| OpenSSH | `~/.ssh/config` | Host、Include、ProxyJump、IdentityFile，规则见下文 |
| PuTTY | Windows `HKCU\Software\SimonTatham\PuTTY\Sessions` 或导出的 `.reg` | HostName、PortNumber、UserName、Protocol、PublicKeyFile；会话名按 PuTTY 百分号编码解码 |
| MobaXterm | `%APPDATA%\MobaXterm\MobaXterm.ini` 或 `.mxtsessions` | `[Bookmarks*]` 中 `#109#` SSH 会话的地址、端口、用户；SubRep 为分组 |
| SecureCRT | `%APPDATA%\VanDyke\Config\Sessions` | `.ini` 中 Hostname、Username、十六进制 SSH2 Port、Protocol Name；子目录作分组，跳过 `__FolderData__.ini` 和 `Default.ini` |
| Xshell | `文档\NetSarang Computer\*\Xshell\Sessions` | `.xsh` 的 CONNECTION 与 AUTHENTICATION 中 Host、Port、Protocol、UserName；子目录作分组 |
| FinalShell | 已知用户/安装目录的 `conn`、Windows 安装信息、macOS app bundle、Linux `~/.finalshell/conn` | `*_connect_config.json` 的 name、host、port、user_name；可迁移支持的保存密码 |
| Tabby | `%APPDATA%\tabby\config.yaml`、`~/Library/Application Support/tabby/config.yaml`、`~/.config/tabby/config.yaml` | `type: ssh` profile 的 name、group、options.host/port/user、首个 privateKeys（路径或 `file://`） |
| CSV | 手选 | RFC 4180 引号；名称（name/label/alias/名称）、地址（host/hostname/address/ip/主机/地址，必填）、端口、用户名、分组（group/folder/分组）、密钥路径（key/identityfile/密钥） |

FinalShell 自动发现只查已知用户/安装目录、Program Files、本地 Programs、系统盘根目录、macOS app bundle；Windows 另读固定 App Paths 和名称匹配 FinalShell 的卸载信息（InstallLocation/DisplayIcon）。不全盘搜索或执行安装/卸载命令，跳过空目录，取首个含主机的来源，不合并来源；便携目录可手选，预览显示实际路径。

注册表通过 `%SystemRoot%\System32\reg.exe query <固定路径> /s` 只读查询，固定参数、不经 shell；其他平台不显示 PuTTY 来源。文件格式按特征识别：`.reg` 头/注册表路径、MobaXterm Bookmarks 与 `#109#`、SecureCRT `S:"Hostname"=`、Xshell CONNECTION 与 Host、FinalShell host/user_name JSON、Tabby profiles YAML、CSV 表头；其余按 SSH config。文件夹按扩展名读取会话文件。

UTF-8/UTF-16 BOM 优先，否则先试 UTF-8，再按系统代码页（中文 Windows 为 GBK）。普通单文件最多 2 MiB；文件夹最多深 8 层、4096 文件、合计 16 MiB；每次最多 512 台主机，超限报告。OpenSSH 使用下方更小的读取上限。

## OpenSSH 读取与解析

- 用户选择 config；Include 仅可读取所选文件目录树内的相对路径，支持文件名 `*`/`?`，不支持绝对路径、`~`、`..`、环境替换或 `**`。规范化后还须检查真实路径，符号链接不能越界。最多 4 层 Include、32 次读取、合计 1 MiB；循环、缺失、超限、越界均报告。Include 在原位置展开，保持首值匹配顺序；任何 Include 未完整读取，整个预览禁止提交，防止遗漏路由后导入成直连。
- 关键字不区分大小写，接受空格或 `=`、引号及引号外注释；非法行报告文件和行号。仅显式 Host 别名生成草稿，含 `*`、`?` 或否定的 Host 只提供按别名匹配的默认值；每项取第一个匹配值。
- 支持 HostName、User、Port、IdentityFile、ProxyJump。缺省地址为别名、端口 22、用户为本机用户名。IdentityFile 只存路径引用；`~` 展开当前用户 home，支持 `%h`（解析后地址）、`%n`（别名）、`%r`（用户）、`%d`（home）、`%%`，其他变量阻止该草稿。多个 IdentityFile 仅取第一项并报告额外项。
- Match 区块直到下个 Host 不应用并报告，不执行判断。ProxyCommand 不执行，有效非 `none` 值阻止对应草稿；其他未支持项仅报告关键字和位置，不展示可能含凭据的原始值。
- 地址、用户、端口、路径变量无效，或跳板缺失、循环、超长，均阻止对应草稿，不静默删路由改成直连。ProxyJump 可引用配置别名或唯一匹配的已保存主机，支持 `user@host:port` 和括号 IPv6；多跳按入口到目标构建，引用链最多 8 台。
- 不修改已保存跳板的上游；需要不同上游时复制为新的元信息草稿。必要的新跳板与目标作为整个新增集合提交。已有同地址（忽略大小写）/端口/用户的主机不覆盖且默认不选，路由与登录补齐限制同下文。

## 登录信息

FinalShell 仅支持 `authentication_type` 缺省或为 `1` 且无 `secret_key_id` 的旧式 Base64（8 字节头 + DES/ECB/PKCS5Padding）保存密码，用于用户主动选择的本机来源。迁移默认开启、可关闭；自动发现不解码。预览重读选中来源，只显示“已找到密码/连接时输入”等状态，不显示或导出秘密。提交再次读取并核对元信息，在内存解码后写入系统安全存储；配置草稿、日志和 AI 不含密码或配置原文。

已有密码不覆盖；只有端点、用户、路由精确匹配且直接使用密码认证的已有主机，才可重新选中补缺。代理路由、未知编码、未保存密码和密钥认证引用不当作可迁移密码；仍可导入元信息并在连接时补登录。来源重选、返回、关闭释放预览引用；Dart String 不保证物理擦除，不宣称安全擦除。

格式参考：[旧式密码编码](https://mg-freedom.org/mg/finalshell-decrypt-password/)、[私钥引用字段](https://github.com/BitsFlowCloud/DengShell/blob/main/build/FINALSHELL-IMPORT.md)。算法与失败处理仅以合成配置验证，作者真实 FinalShell 版本未验。

## 不支持的内容

- 其他软件的密码、私钥口令、FinalShell 专有密钥库引用（`secret_key_id`）。提示连接时补充，不把旧密码当密钥口令；可用的普通密钥路径仍保留。
- PuTTY `.ppk` 路径不写入主机，报告需转换；非 SSH 会话列出并标记。
- 代理、端口转发、终端外观与脚本等设置；跳板仅支持 OpenSSH ProxyJump。

## 预览与提交

第二步显示来源与返回入口、目标分组（不分组或已有组）、可勾选主机及报告。每项显示名称、`用户@地址:端口`、来源分组和登录迁移状态；已有同端点/用户/路由的记录仅在可补登录时允许选中，阻止项解释原因。来源分组置于目标分组下；无法读取、跳过和超限报告带文件名。

提交经 `HostsNotifier.importDrafts` 单写队列：核对预览 hosts revision、来源与整个新增引用链；需要密码时在凭据串行队列只补缺失，再一次 revision 校验写盘后发布主机库。预览期间库变化要求重新预览；失败回收本次尝试写入的秘密引用，回收失败单独提示，不伪称完全成功。密钥路径不自动导入安全存储；以后连接仍经凭据流程和 HostTrustService。关闭不提交草稿或凭据，首次引导标记仍按入口规则保留。

## 验证范围

解析、编码、Include 边界、跳板链、revision、读取上限和各格式使用构造样例；发现流程用合成注册表与临时目录。密码样本独立用 PyCryptodome DES 生成，覆盖 Unicode、负头字节、填充、未知格式、UTF-16 BOM、重复导入、代理拒绝、来源变化、并发冲突、写后报错与回收失败。组件测试覆盖来源指引、960×640、重选、首次引导和迁移开关；实际通过记录集中在 TESTING。各软件真实安装、默认位置、作者 FinalShell 版本及系统选择器未验，不由合成测试推定通过。
