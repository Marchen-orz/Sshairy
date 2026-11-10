# 公共契约与资源生命周期

v0.2。本文定义应保持稳定的语义，不提供假装可编译的 Dart 伪代码。具体类型实现以首个真实用例为准，不预建通用 RPC 框架。

## 1. 类型与用例边界

- 使用独立 HostId、SessionId、TransportId、PaneId、TransferId、OperationId，不能混用字符串 ID。
- 预期失败返回 Result<T, AppError>；错误含稳定 code、用户消息 key、可重试性、stage、operationId、安全细节。库异常在适配器转换，堆栈留在脱敏诊断日志。
- Programmer error 允许异常与堆栈，不把所有 bug 转成“网络失败”。没有退出码不等于退出码 0。
- CancellationToken 与 deadline 分开：取消需要实际停止工作、清资源；Future.timeout 只停止等待，不是实现。
- 事件携带 ownerId、generation、单调 sequence。消费者拒绝旧 generation 结果；订阅者有明确取消时机。
- 进度 Stream 为有界、可合并状态流；终端字节为独立有序数据流，不能经过全局状态通知。

建议公开 API：

| 接口 | 输入/输出与边界 |
|---|---|
| HostRepository | query / save(expectedRevision) / delete；输出无秘密 HostProfile |
| ConnectionResolver | HostId → 不可变 ResolvedConnectionSpec；包含 route/auth/trust revision |
| CredentialAccess | 按 SecretRef 按需取凭据；UI 和 AI 不得拿全库映射 |
| ConnectionManager | acquire(spec, purpose, cancellation) → TransportLease；release 幂等 |
| TransportLease | openShell / exec / openFiles（SFTP，返回 foundation 的 FileSystem）/ connectTo（direct-tcpip，返回 Tunnel，用于本地与动态转发和跳板）/ listen（tcpip-forward，返回 RemoteListener）；不泄露 dartssh2 类型 |
| TerminalSessionManager | open / openLocal / reconnect / close / readSnapshot；SSH/local typed target，模型独立于视图；本地不申请 SSH 租约 |
| TerminalIo | 有序 bytes、writeInput、resize、close；数据路径不 JSON 化 |
| Terminal AI 端口（M4，待实现） | 受限环境/草稿/历史投影 → 行内生成或补全，带 requestId/目标/代次/草稿/授权/目的地修订；不含 shell/目录列表；terminal 定义 DTO/端口、app 注入 AI 实现，无循环依赖 |
| TerminalDraftAcceptor（M4，待实现） | 用户接受完整生成命令时须空提示符，接受补全只追加精确回显前缀的后缀；重验输入状态/代次，无换行/删行/自动执行参数；不是 Agent 工具 |
| TransferManager | enqueue / cancel / retry / watch；任务不由 SftpPane 持有 |
| SettingsService | get / patch(expectedRevision)；类型、范围、策略统一验证 |
| WorkspaceService | openTab / split / move / focus / close；布局只引用 sessionId |
| CommandExecutor（M4，待实现） | start(command, target, cwd, deadline, cancellation) → executionId + 有界 stdout/stderr/终态事件；先 acquire，再启动单次执行，不把已发请求包进自动重拨重试回调 |

`TransportLease.exec(command, limit, timeout, cancel)` 保留一次性有界结果；timeout 覆盖打开与运行，取消/超时返回稳定的 typed 执行错误，不能返回部分输出冒充成功。开始前取消不打开 channel；已返回的执行 session 在正常终态、错误、取消或超时时统一销毁本次 channel、取消订阅和计时器，不关闭共享 transport。监控停止/切换与目录查询失效要取消各自在途执行。关闭 channel 只证明客户端收束，不承诺远端全部子进程已终止，也不自动重跑结果未知的命令。

当前 dartssh2 4.1.0 的公开 `execute` 在执行请求应答后才暴露 session：打开/应答期间取消会先结束调用者等待，并销毁之后迟到的 session；若服务器始终不回复请求，公开接口无法立即取得并销毁该内部 channel。`destroy` 完成本地关闭；库的内部 channel 登记仍需收到对端 `CHANNEL_CLOSE` 才移除，不能据本地收束承诺不合作对端下的全部底层对象立即回收。这些限制保留为待上游接口支持的边界，不通过断开其他任务使用的共享连接绕过。适配器在单次 exec 的错误 zone 内打开 session，承接库内部 channel 流未转发到 stdout/stderr 的异步错误，以失败收束本次执行；不能把错误后的部分输出当作正常结果。

## 2. 资源所有权

| 资源 | 所有者 | 释放规则 |
|---|---|---|
| Socket、SSH transport、跳板链 | ConnectionManager | 无租约且 TTL 到期；出错/主动断开；逆序销毁跳板 |
| SSH shell channel / 本地 PTY + terminal model | TerminalSessionManager | 用户关闭会话、失败清理或应用退出；本地 PTY 的进程、读写与退出资源由适配器收束 |
| TerminalView / focus / selection UI | pane Widget | 卸载即可；不得关闭 shell |
| SFTP 浏览 channel | 浏览会话控制器 | 关闭浏览器时释放自己的 lease |
| 传输 channel / 文件句柄 / .part | TransferManager 中的 task | 完成/取消/失败后按 checkpoint 策略清理 |
| 转发 listener 与 accepted sockets | ForwardManager | stop 必须解除监听并收束连接，之后归还 lease |
| 监控 exec 租约 | 监控面板的 ServerMonitor | 面板卸载、标签切走、会话断开时停止轮询并归还；只在主机已连接时取用，不自己拨号 |
| 文件 watcher / 临时副本 | ExternalEditManager | 用户结束编辑或退出处理完成；失败稿保留 |
| Auth/host-key challenge | ConnectionAttempt | 完成、取消、超时或 generation 过期时失效 |
| Agent stream / tool jobs | AgentRuntime | 单 turn 终态后清理；长 job 的所有者/期限/输出有界，Stop 不与独立轻量请求串错 |
| 行内生成 / AI 补全（M4） | 当前会话输入控制器持短请求 token，共用 AI 网络调度 | 草稿/焦点/代次/上下文/授权/目的地变化取消，迟到结果不回填；关闭总 AI/退出全部收束，本地 loading 不写远端 |

关闭标签只关闭其中 shell；传输、隧道可继续持有 transport。断开主机是另一动作，需列出受影响任务。一个 acquire 等待者取消不得撤销其他等待者的共享拨号。

关闭 shell 是 `ShellChannel.close()`：双向结束 channel（EOF 加 CHANNEL_CLOSE），服务器随即挂断登录 shell。只关己方（只发 EOF）不够：带 pty 的登录 shell 收到 EOF 不会退出，远端进程会留到连接结束，channel 也一直登记在连接里（2026-11-07 在真实服务器上发现并修复：关标签 3 秒内远端 shell 消失）。

`ConnectionManager.connected` 是认证完成后的 `Stream<HostId>` 通知，只在新 transport 可用时发送，不因复用租约重复发送，不带凭据或会话内容；监听者自行核对当前主机与状态，停止/卸载时取消订阅。监控据此在首次连接和重连成功时立即采样，管理器关闭时关闭通知流。

租约的 `done` 属于租约本身，不挂在共享 transport 上：transport 丢失时，仍持有的租约各自完成 `done`，已释放的租约不会完成。Future 没法移除监听，监听若挂在长寿的 transport 上，它捕获的已关闭终端和回滚缓冲会跟着连接一直活着（2026-11-07 用 VM 保留路径确认）。`lost` 反映 transport 当前是否已关闭，与租约是否释放无关。

初始池 key 至少含目标端点、用户名、身份/凭据修订、完整跳板链、代理策略、算法策略、信任修订。信任修订与凭据修订只在收回信任或凭据时递增：忘记、替换或移除已保存的主机密钥，删除或改写不同的凭据；首次信任一个主机密钥和首次保存刚认证成功的凭据不递增，因为它们发生在拨号过程内，递增会使刚建立的连接无法被重连、分屏和同主机新标签复用（2026-11-07 对真实服务器的集成测试发现）。显式主机表单通过 HostPasswordEditor 新存或更换密码属于拨号之外的凭据修改：实际值变化才写入并递增 revision（包括首次预存），明确删除同样递增；平台写/删即使报错也可能已生效，尝试后递增以废止不确定的池快照，读取失败不写不递增，空值保留且相同值不写不递增。旧的连接内 remember 首次保存语义不变。密码不出现在 key 的字符串或日志中。禁复用选项、单通道服务器、失活连接均可走独立 transport；不保证同主机永远只有一条 TCP。

## 3. Capability：共享业务行为

每项描述包含：id、version、typed input/output、参数校验、effect、target resolver、availability、cancellation、undoPolicy、agentExposure。ID 采用 `host.update` 风格；工具名可映射下划线，但保留版本和原 ID。

- effect 分为查询、本地可逆变更、连接/执行、远程写入、秘密/安全管理；不能只用一项静态 low/high 判断全部参数。
- 默认不向 AI 暴露。M4 经人工审阅选入工具目录；只导出安全 DTO，绝不通用序列化所有对象。
- Typed UI façade 与 dispatcher 最终调用同一 application handler。校验和必要授权不能只写在 Widget 或 prompt 中。
- RequestContext 来自应用装配：origin、actor、scope、operationId、deadline、cancellation。AI 参数不能伪造 origin=ui、grant 或 approval。
- 流程：解析与校验 → 解析实际目标/版本 → 策略 → 预览/审批（若需要）→ 执行前再次校验范围与修订 → handler → 安全结果/审计。
- 审批绑定 capability/version、规范参数摘要、目标 ID、scope revision、有效期；参数或目标变化需要新批准，不能用 host label 替代 ID。
- 并行读按资源限流；同一路径写入、同终端受控命令串行。同主机不同只读通道可并行，不设阻塞全应用的总锁。
- 普通 UI 查询不要求走 registry。hover、草稿、滚动、拖动中间帧、逐键终端输入不登记成远程工具。

一期最小目录：host.list/create/update/move/delete/deleteMany、group.reorder、session.open/openLocal/close/reconnect、workspace.split/focus/closeTabs、settings.get/patch；随 M2/M3 添加 files 与 forwarding。`session.openLocal` 只从本机发现的 shell 中按 executable 选取，不允许模型传任意程序/参数，当前不向 Agent 开放。没有实现的 capability 不注册，不用空成功响应占位。

`workspace.split` 保留 axis（horizontal/vertical，向右/下分屏），可提供 tabId、paneId 与 side（left/right/top/bottom）固定目标和方向；typed UI 同样复用该用例，可带 expectedLayout 拒绝过期拖放。为命中 pane 的同一目标新建一个 shell，校验缺失/超限在创建前完成，布局单次发布/保存；新会话继续走原信任/认证或本地 PTY 流程，原会话不重启。

`workspace.moveTerminal` 接收 sourceTabId、可选 sourcePaneId、targetTabId、targetPaneId 与 side（left/right/top/bottom），搬移整个标签树或一个 pane，typed UI 可另带源/目标布局身份以拒绝过期拖放。`workspace.detachPane` 接收 tabId、paneId 与插入标签索引，将 pane 移到独立标签；均为 localChange，复用同一确定性布局校验，缺失/自包含/超限整次拒绝，不打开或关闭会话，不向 Agent 开放。几何可用性在 UI 检查，松开时重验；移动后资源所有者仍为 TerminalSessionManager。

`workspace.closeTabs` 接收 tabId 和 scope（left/right/others），保留基准标签，按标签顺序关闭目标中的所有 shell，再单次更新和保存工作区；活动标签被关闭时切到基准，否则保留原活动页。缺失标签返回 notFound，空目标返回 closed: 0，不向 agent 开放。传输和隧道遵循原租约所有权，不因批量关闭 shell 而被主动取消。主机批量删除和同级组排序的原子边界见 HOST_INHERITANCE。

## 4. 重试、撤销与审计

OperationId 用于识别一次调用；重试协议请求与重复执行业务副作用是两件事。

- 明确无副作用且尚未执行的请求可重试。远端命令发出后连接断开，结果为 `outcomeUnknown`，不得自动重跑。
- 同 OperationId 已有完成结果可返回该结果；不能仅按 command 文本去重，用户可能有意重复运行。
- 本地设置、布局、主机元数据可保存 before/after 与 expectedRevision 实现撤销；有冲突就提示，不覆盖新编辑。
- 删除远端文件、执行 shell、上传覆盖、修改凭据和断开连接不承诺通用撤销。补偿操作是新的有风险动作。
- 撤销 AI 对话只是历史分支，绝不表示撤销服务器变化。
- 审计默认保存时间、来源、目标 ID、动作、脱敏摘要与结果码；不逐键记录终端，不默认存命令全文/输出。M4 敏感执行记录按 SECURITY 处理。

## 5. 关闭协调

ShutdownCoordinator 是应用退出唯一入口：收集未保存配置、正在传输、未上传编辑稿、转发与 AI 工作 → 用户选择继续等待/取消退出/结束 → 停止接收新任务 → 有界取消和写入 → 关闭通道与 transport → 销毁平台资源。

用户确认退出后窗口先隐藏（任务栏按钮一并消失），有界取消、写入和断开在窗口消失后进行，不让界面停在冻结的画面上；清理失败时窗口重新显示并让用户选择返回、重试或强制退出。

用户取消退出时恢复正常工作，不提前置全局 quitting。保存失败不能显示“全部保存成功”；强制退出保留 interrupted 任务与恢复稿。取消只保证客户端不再继续发新操作，不能保证远端进程一定已终止。
