# Netcatty 参考依据

只读参考 [binaricat/Netcatty](https://github.com/binaricat/Netcatty) commit `0e3f282657df29a5dc6939c86dbf4ea3ad2be8ea`（2026-11-05）。下列路径/行号均针对该固定版本；没有运行 Netcatty 或做同机内存对照，作者观察的 800 MB+ 原因未核实。Electron/Monaco/多窗口只是栈信息，不能当作高占用的实测归因。

该版本 GPL-3.0-or-later（`package.json:13`），只借鉴交互和失败场景，不复制代码、命令规格或品牌素材。sshairy 的有效规则分别在 DESIGN、MODULES、CONTRACTS、SECURITY、UI 与 AI；本文仅保存参考出处，不另维护功能状态和默认值。

| 参考主题 | 固定版本证据 | 对本项目的取舍 |
|---|---|---|
| 超时与认证 | `domain/sshConnectionTimeouts.ts:3–4`、`electron/bridges/sshBridge.cjs:573–575` 分开 TCP/ready；`sshAuthHelper.cjs:1809,1840` 处理剩余方法/部分成功 | 分开连接阶段，认证是有序策略；不假定一项 authMethod 覆盖多因子 |
| 信任与 rekey | `electron/bridges/hostKeyVerifier.cjs:95,219–223` 区分状态，rekey 的异步提示有协议时序风险；`sshBridge.cjs:525,605` 每跳检查 | 所有路径用统一 HostTrustService，适配 dartssh2 实际回调并实测，不照搬同步确认 |
| 池与路由 | `electron/bridges/sshConnectionPool.cjs:129,475,576,620` 合并拨号/认证路由键；`sshIdleParkPolicy.cjs:10–27` 特殊服务器不能复用；`proxyUtils.cjs:101` 代理尾字节含 SSH banner | key 显式带修订与完整路由，取消单个等待者不取消共享拨号；允许独立 transport，保留代理尾字节 |
| 恢复 | `docs/session-restore.md:10,146` 自动重连与启动不拨号描述有差异 | 布局恢复为未连接，不声称恢复远端进程 |
| 输出流控 | `infrastructure/config/terminalFlowConstants.json`、`electron/bridges/terminalFlowAck.cjs:92`、`components/terminal/runtime/terminalSessionAttachment.ts:685,726` | 借鉴高低水位与消费后返还额度，按无 IPC 的本项目另定预算 |
| 终端适配 | `domain/workspace.ts:48–52` 分屏局部修剪；`terminalCopyShortcut.ts:27–32` Ctrl+C；`terminalImeTextInput.ts`；`package.json:45` 的 xterm 补丁 | 保留祖先比例、终端按键与 IME；库问题限制在适配层，不假定 xterm2 开箱可用 |
| 继承与秘密 | `domain/groupConfig.ts:89,102,193`；`domain/models/connection.ts:172,205`；`electron/bridges/credentialBridge.cjs:98–100,125–127` 明文回退；`secureFieldAdapter.ts:39` 异步写入窗口 | 三态显式表达，小模型/SecretRef、窄凭据端口、写后发布；禁止明文降级 |
| 保护备份与退出 | `application/localVaultBackups.ts:219,438`；`electron/main.cjs:1624–1632` 取消退出不能遗留 quitting；`portForwardingBridge.cjs:419` 停止超时 | 保护失败中止覆盖，统一关闭协调，停止失败不能冒充成功 |
| SFTP | `electron/bridges/transferLimits.cjs:3–27`（#2022/#2030 请求过大损坏，#1507 终端受传输挤占）；`transferBridge.cjs:2345,2655,3096`（#4134 取消断共享连接）；`sftp/useSftpTransfers.ts:1354`（#3559 列表后目标变化） | 固定有界请求、独立 channel、取消不关共享 transport；开始前重验目标、目标旁 .part 发布；不引入 Monaco |
| AI 运行与审批 | `infrastructure/ai/harness/agentRuntime.ts:107`、`agentStop.ts:31`、`cattyToolApproval.ts:28`、`toolResultDedup.ts:49` | 单 turn/唯一 Stop；工具默认不暴露，审批绑定 effect/参数/目标/revision，用 operationId 区分副作用 |
| AI 执行与上下文 | `electron/bridges/ai/ptyExecHelpers.cjs:294`、`ptyExec.cjs:109–110`；`lib/commandBlocklist.json:19–21`；`contextBudget.ts:42–50`、`toolOutputStore.ts:62–70` | 首版独立 exec 与可见记录，取消可结果未知；黑名单不作授权；预算包括 system/tools/reserve，输出存储有界 |
| 布局与焦点 | `components/TopTabs.tsx:1052,1116`、`VaultHostListSection.tsx:605`、`components/ui/button.tsx:15,21` | 参考浏览器式标签/主机库，自定 tokens 与可见焦点；不复制素材或堆工具栏 |
| 补全 | `components/terminal/autocomplete/terminalAutocompleteLayout.ts:283–351,430–565`、`completionEngine.ts:284–714`、`AutocompletePopup.tsx:268–355,416–528`、`useTerminalAutocomplete.ts:964–1215` | 借鉴光标锚定/边界、分支与异步过期保护；AI 顶置是本项目约定，不写成参考项目已有能力 |

AI 产品范围另核对同一固定版本：[README](https://github.com/binaricat/Netcatty/blob/0e3f282657df29a5dc6939c86dbf4ea3ad2be8ea/README.md) 已展示多主机编排；[工具目录](https://github.com/binaricat/Netcatty/blob/0e3f282657df29a5dc6939c86dbf4ea3ad2be8ea/infrastructure/ai/harness/generated/cattyToolSpecs.json) 包含长任务、SFTP 写入和自动化脚本；[系统提示](https://github.com/binaricat/Netcatty/blob/0e3f282657df29a5dc6939c86dbf4ea3ad2be8ea/infrastructure/ai/cattyAgent/systemPrompt.ts) 与 runtime 支持计划；[终端 artifact](https://github.com/binaricat/Netcatty/blob/0e3f282657df29a5dc6939c86dbf4ea3ad2be8ea/components/ai/toolArtifacts/terminalToolArtifact.ts) 已有来源/行范围。因此多机、计划、可复用脚本、结构化终端卡片不能单独声称为 sshairy 独有。所查路径未见完整的跨结果结论—证据关系、确定性跨机字段比较、绑定前置/后置检查的变更闭环；这是所查固定版本的证据边界，未核对最新分支，也不证明上游无法实现。

`electron/main/registerBridges.cjs:633–678` 加载 Fig 规格不证明动态生成器可用，静态序列化会剔除函数。本项目 Fig 数据直接上游来源、许可、固定版本和可重复导入独立见 [COMPLETION_SPECS](COMPLETION_SPECS.md)，不从 Netcatty 提取；不能把锁文件的包许可代替实际数据许可。范围排除项统一见 DESIGN §3。
