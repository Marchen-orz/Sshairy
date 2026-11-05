# Netcatty 参考分析

v0.2。依据 [binaricat/Netcatty](https://github.com/binaricat/Netcatty) commit `0e3f282`（2026-11-05），路径和行号都针对该版本。

只读源码，没有运行 Netcatty，也没有测量。许可证 GPL-3.0-or-later（`package.json:13`）：只参考设计和失败场景，不复制代码、图标、品牌素材。

## 1. 总体判断

| 项 | 事实 | 结论 |
|---|---|---|
| 运行栈 | Electron 42、Monaco、`@xterm/xterm` 6.1 beta、`ai` SDK 7 及多个 provider（`package.json:155-174`）；设置、编辑器、弹出终端等各有独立 BrowserWindow（`electron/bridges/windowManager/`） | 单进程 Flutter 有降低占用的空间，但需实测 |
| 800 MB+ | 来自用户观察，源码无法证实原因 | **未核实**。运行栈只是嫌疑，不写作结论；M0 同机对照（P-01） |
| 代码量 | 非测试 TS/JS 约 57.8 万行，测试约 42.2 万行 | 体量大部分来自功能范围和真实兼容问题，不等于浪费（ADR-08） |
| 分布（按路径粗算，有重叠） | 终端约 10.6 万、SFTP/传输约 5.8 万、插件约 4.3 万、AI 约 3.8 万 | 不做插件和 Mosh/ET/串口等是主要减法；终端和传输的复杂度多半省不掉 |

统计：`git ls-files` 取 `.ts/.tsx/.cjs/.js/.mjs`，以 `.test.` 区分测试。

阅读时注意：issue 编号和注释记录了实际踩过的坑，是本文最有价值的部分。Netcatty 的默认值不代表 sshairy 也该用，差异都在 MODULES 中单独决定。

## 2. SSH 连接

| 主题 | Netcatty 证据 | sshairy |
|---|---|---|
| 超时 | TCP 20s、认证就绪 120s（`domain/sshConnectionTimeouts.ts:3-4`）；就绪计时从 TCP 连上开始，因为 ssh2 的 readyTimeout 从拨号算起（`electron/bridges/sshBridge.cjs:573-575`） | 学习：同样初值，分开计时 |
| 多因子 | authHandler 处理 methodsLeft 和 partialSuccess（`electron/bridges/sshAuthHelper.cjs:1809`、`:1840`） | 学习：AuthPolicy 是有序偏好，不是单一 authMethod |
| 主机密钥 | 分类判断（`electron/bridges/hostKeyVerifier.cjs:95`）；提示 2 分钟超时（`:5`） | 学习：unknown/changed/新算法分开处理 |
| rekey | 同步比对已接受的密钥，从不再次提示，否则异步提示会造成 “Bad packet length”（`hostKeyVerifier.cjs:219-223`） | 学习：写入 C-01，并由 E-08 验证 dartssh2 的回调时序 |
| 池 key | 含认证指纹和路由（`electron/bridges/sshConnectionPool.cjs:475`、`:576`、`:620`） | 学习：key 用完整 ResolvedConnectionSpec，改进为显式包含 revision |
| 合并拨号 | `beginTransportDial`（`sshConnectionPool.cjs:129`） | 学习：C-03，且一个等待者取消不影响其他人 |
| 停泊和保活 | 空闲 5 分钟（`:40`）；保活默认 10s×3（`:509-521`） | 改进：停泊 60s、保活 30s×3，默认更保守；实测后复核 |
| 受限堡垒机 | TERM-SSHD 复用时第二个 shell 立即退出，按 banner 禁用复用并做 350ms 存活检查（`electron/bridges/sshIdleParkPolicy.cjs:10`、`:14`、`:27`） | 学习：不写死厂商名单作为唯一手段，可判定复用失败时走独立 transport |
| 跳板 | 每跳单独校验主机密钥（`sshBridge.cjs:525`、`:605`）并建下一跳转发（`:957`） | 学习：每跳认证、校验、超时独立 |
| 代理 | 代理响应后的字节可能已带 SSH banner（`electron/bridges/proxyUtils.cjs:101`） | 学习：写入 C-04 |
| 恢复语义 | 文档一处说自动重连恢复（`docs/session-restore.md:10`），另一处说启动恢复不得发起网络连接（`:146`） | 改进：默认恢复为 disconnected，自动连接单独开关，不声称恢复进程 |

## 3. 终端

| 主题 | Netcatty 证据 | sshairy |
|---|---|---|
| 流控 | 高水位 1 MiB、低水位 8 KiB、每 4096 字符确认（`infrastructure/config/terminalFlowConstants.json`）；后端按未确认字节暂停（`electron/bridges/terminalFlowAck.cjs:92`） | 学习原则；水位另定（1 MiB / 256 KiB），无 IPC 不需要相同确认粒度 |
| 确认时机 | 写入完成后才确认（`components/terminal/runtime/terminalSessionAttachment.ts:685`、`:726`） | 学习：消费后才返还额度 |
| 批量与上限 | 128 KiB、洪泛 768 KiB、待写上限 8 MiB（`electron/bridges/ptyOutputBuffer.cjs:36-38`） | 参考；前提是验证 pause 能传到 SSH 窗口（E-03） |
| 隐藏页 | 休眠默认关（`domain/models/terminal.ts:619`）；有 generation 与驱逐状态（`components/Terminal.tsx:2292`、`application/state/hiddenTabEviction.ts:27`） | 改进：M1 只停绘制、继续解析，不做 serialize/休眠 |
| 分屏修剪 | 只有失去直接子节点的层级才重排，祖先比例保留（`domain/workspace.ts:48-52`） | 学习：写入 W-01 |
| resize | 观察器防抖 250ms（`components/terminal/useTerminalEffects.ts:1677-1685`） | 改进：拖动节流，结束立即提交最终值 |
| 复制键 | 无选区时 Ctrl+C 透传为 SIGINT（`components/terminal/runtime/terminalCopyShortcut.ts:27-32`） | 学习原则；默认复制键用 Ctrl+Shift+C |
| IME | 有专门修复与测试（`components/terminal/runtime/terminalImeTextInput.ts`） | 学习：把 IME 当一等验收（E-04），修法因渲染方式不同不可照搬 |
| 库补丁 | postinstall 运行 6 个 xterm 修补脚本（`package.json:45`），`patches/` 另有 node-pty、ssh2 等补丁 | 警示：xterm.js 尚且需要补丁，xterm2 不能假设开箱可用；问题留在 terminal 适配层 |

## 4. 主机库与存储

| 主题 | Netcatty 证据 | sshairy |
|---|---|---|
| 分组继承 | `resolveGroupDefaults`（`domain/groupConfig.ts:89`）；身份设置特殊处理（`:102`）；部分空字符串表示覆盖（`:193`） | 学习继承；改进：用 `Override<T>` 明确三态，不靠空字符串和 undefined |
| Host 模型 | `Host` 约 100 个字段（`domain/models/connection.ts:172` 起），含 `password`（`:205`） | 改进：小模型组合；凭据不进 Host DTO（ADR-05） |
| 明文回退 | 系统加密不可用或加密失败时返回明文（`electron/bridges/credentialBridge.cjs:98-100`、`:125-127`） | **不学**：无明文降级，只能本次使用 |
| 写入窗口 | 密钥状态先发布、异步写存储，连接要等写入完成才读（`infrastructure/persistence/secureFieldAdapter.ts:39`） | 学习场景；改进：用提交顺序和 revision，不靠读时等待 |
| 备份 | 保留 20 份（`application/localVaultBackups.ts:68`）；破坏性恢复前必须有保护备份（`:219`、`:438`） | 学习：保护备份失败就中止；保留 10 份 |
| 转发 stop | `unforwardIn` 5s 超时（`electron/bridges/portForwardingBridge.cjs:419`） | 学习：显示 stopFailed，不假装已停 |
| 转发自动化 | autoStart 和 autoReconnect 语义不同（`application/state/usePortForwardingAutoStart.ts:115`、`:121`） | 学习：独立字段，默认都关 |
| 退出 | 取消退出时不能留下 isQuitting，否则后续窗口行为变化（`electron/main.cjs:1630-1632`）；渲染进程检查 5s 超时（`:1624-1626`） | 学习：ShutdownCoordinator 在用户确认后才进入退出态 |

## 5. SFTP 与传输

| 主题 | Netcatty 证据 | sshairy |
|---|---|---|
| 请求大小 | 32 KiB，部分服务器遇更大请求会静默损坏（`electron/bridges/transferLimits.cjs:3-5`，#2022、#2030） | 学习：固定 32 KiB |
| 并发 | 每文件 64 个在途请求，为高延迟链路（`transferLimits.cjs:7-17`）；TERM-SSHD 降为 1（`:19-27`） | 改进：起步 16，内存更稳；E-06 和 P-03 实测后调整；保留按服务器降级的能力 |
| 终端隔离 | 上传优先用独立 channel/会话以免饿死终端（`transferLimits.cjs:7-11`，#1507） | 学习：E-06 验证 |
| 取消 | 传输中 `sftp.end()` 可能断掉共享 SSH（`electron/bridges/transferBridge.cjs:2345`、`:2655`、`:3096`，#4134） | 学习：F-03 的来源 |
| 暂存发布 | 目标旁 `.part` 再发布（`transferBridge.cjs:334`） | 学习；SECURITY §5 说明无原子覆盖时如何处理 |
| 重新 stat | 列表后文件可能被其他会话改变（`application/state/sftp/useSftpTransfers.ts:1354`，#3559） | 学习：开始前重新 stat |
| 跳过未变 | size+mtime，按整秒比较（`domain/sftpTransferSkip.ts:1-7`） | 可选且默认关，不当校验 |
| 内置编辑器 | Monaco，限 10 MB（`components/sftp/sftpEditorFileLimits.ts:1`） | 不做：外部编辑优先（ADR-07） |

## 6. AI

| 主题 | Netcatty 证据 | sshairy |
|---|---|---|
| 循环 | AI SDK `streamText`，`isStepCount(maxIterations)`（`infrastructure/ai/harness/turnDrivers/cattyStreamProcessor.ts:155`），默认 20（`infrastructure/ai/types.ts:451`） | 改进：自建状态机，直接 HTTP；初值同为 20 |
| 单 turn | 忙时拒绝（`infrastructure/ai/harness/agentRuntime.ts:107`） | 学习 |
| 唯一停止 | `stopAgentTurn`（`infrastructure/ai/harness/agentStop.ts:31`） | 学习 |
| 能力目录 | 工具由 `electron/capabilities/catalog/` 生成；Catty 75 个规格（`infrastructure/ai/harness/generated/cattyToolSpecs.json`） | 学习生成思路；改进：默认不暴露，人工挑选，按上下文给子集 |
| 审批 | `write && !bypassesApproval`（`infrastructure/ai/harness/cattyToolApproval.ts:28`） | 改进：按 effect、目标和 revision 绑定，不是单一布尔 |
| 重放去重 | 写操作重放用指纹（`infrastructure/ai/harness/toolResultDedup.ts:49`） | 改进：用 operationId，不按命令文本判断 |
| 命令执行 | 写入可见 PTY，用 marker 包裹（`electron/bridges/ai/ptyExecHelpers.cjs:294`）；取消每 5s 重试，30s 上限（`electron/bridges/ai/ptyExec.cjs:109-110`） | 改进：首版独立 exec + 可见记录（ADR-06）；取消结果可能未知 |
| 黑名单 | 含 `eval`、`$(`、反引号（`lib/commandBlocklist.json:19-21`） | 只作风险提示，不是授权边界 |
| 压缩 | 窗口 − 输出 − 缓冲 − 压缩提示（`infrastructure/ai/harness/contextBudget.ts:42-50`） | 学习：预算计入 system、tools 和 reserve |
| 输出句柄 | 单次读 12k 字符、TTL 30 分钟、单句柄 4M（`infrastructure/ai/harness/toolOutputStore.ts:62-70`） | 学习机制；缩小上限（8 KiB、8 MiB） |

## 7. UI

| 主题 | Netcatty 证据 | sshairy |
|---|---|---|
| 版式 | 浏览器式标签、主机库、彩色主机图标、终端工作区 | 学习布局，不复制 logo 和素材 |
| 尺寸 | 标签栏 36、控件 28（`components/TopTabs.tsx:1052`、`:1116`）；主机卡 68（`components/vault/VaultHostListSection.tsx:605`）；头像 44（`components/vault/VaultEntityIcon.tsx:11`）；快速切换 672（`components/QuickSwitcher.tsx:529`）；radius 10.4（`index.html:38`） | 参考；自定尺寸见 UI.md |
| 主题 | 多套界面主题，如 Snow（`infrastructure/config/uiThemes.ts:33`） | 首版只做 Light/Dark，自有配色 |
| 焦点 | 按钮 `focus-visible:outline-none`（`components/ui/button.tsx:15`） | 改进：2px 可见焦点 |
| 按钮 | 默认高 40（`button.tsx:23`）；ghost 悬停用 accent 色（`:21`） | 改进：36 高；悬停用中性层次 |

## 8. 明确不做

插件平台（`packages/plugin-*`）、MCP、云同步、内嵌浏览器、Monaco、Mosh/ET/Telnet/串口/X11/ZMODEM、FIDO、终端图片协议、外部 CLI Agent。完整清单见 DESIGN §3。
