# AI harness 设计（M4）

v0.2。M0–M3 不实现 AI，保留业务用例、能力目录、受限终端快照与独立 exec 端口即可。SSE 是传输协议；Agent 是模型、工具执行、上下文、授权与运行控制组成的闭环。

## 1. 目标和边界

首版覆盖：解释选中输出、生成待执行命令、多步服务器诊断、授权范围内多主机检查、调整主题/字体/布局、打开已授权主机的会话。后续逐项加入远程文件修改与复杂运维任务。

不引入 Node/Python 常驻运行时、MCP、外部 CLI Agent、插件系统或子 Agent 编排。直接 HTTP 是否比 SDK 更省内存必须实测；不要把自建 harness 描述成“几十行循环即可完成”。

AI 关闭/未配置时 SSH 全部能力正常，启动不探测模型端点、不发遥测或模型请求。AI 页签只在 M4 实装后出现。

## 2. 模块结构

```text
ai/domain/          Conversation、Turn、ToolCall、ToolResult、AgentEvent
ai/application/     AgentRuntime、ContextManager、ToolAdapter、ApprovalCoordinator
ai/adapters/        ModelProvider、SSE parser、ConversationStore、OutputStore
ai/presentation/    对话、引用、计划、执行记录、审批卡片
```

AI 依赖 capabilities/api 与经过授权的上下文端口，其他 feature 不 import ai。策略由应用注入执行边界，不能靠 prompt 要求模型“自觉守规矩”。

ModelProvider 只实现请求构建与事件归一；AgentRuntime 不知道 HTTP 字段；UI 不负责拼 tool messages 或推进循环。

## 3. 模型适配与流协议

候选协议：Anthropic Messages、OpenAI-compatible Chat Completions；兼容服务并不保证相同 tool-call/stream 行为，逐个建立契约样例。实施时复核供应商正式文档和模型功能，不把当前型号写死。

ModelConfig：endpoint、protocol、model、SecretRef、contextWindow、outputLimit、timeouts、明确支持的能力。自定义 headers 需拒绝影响安全/授权的保留字段；默认校验 TLS。模型发现失败允许手填，不能伪造可用模型。

内部事件：textDelta、toolCallStart、toolArgumentsDelta、toolCallComplete、usage、turnComplete、error。要求：

- SSE 增量 UTF-8 解码，支持跨 chunk 分隔符、CRLF、多行 data、heartbeat、分片 JSON；有事件大小和总缓冲上限。
- 用 index/id 聚合同一轮多个工具调用。参数在流完整结束、JSON 解析及 schema 校验后才执行；半截 arguments 绝不调用工具。
- 区分 finish reason、HTTP 错误、流中错误、EOF 与合法完成。连接中断不能当“模型不再调用工具所以任务完成”。
- tool call/result 一一配对，保留 provider 要求的 opaque continuation；不把私有签名、reasoning 块随意删改后重放。
- UI 文字更新按 30–60ms 合并；Markdown 不随每字符重排整个历史。需要完整保留文本，不丢增量。
- 云端 endpoint 默认 HTTPS；本机模型 HTTP 仅限明确本地配置，用户知道请求目的地。跨源重定向不携带 API Key。

## 4. 运行状态机

```text
idle → preparing → streaming → validatingTools → awaitingApproval
     → executingTools → recordingResults → preparing → … → completed
任意状态 → stopping → cancelled；错误 → failed / outcomeUnknown
```

每个 conversation 同时最多一个 turn；开始新的输入可以排队或用户明确停止，不隐式并发覆盖历史。

每轮流程：构建有界上下文 → 发请求 → 累积完整 assistant message → 验证工具 → 固定目标与参数 → 策略/审批 → 执行前重验 → 执行并记录 → 添加匹配 tool result → 下一轮。达到限制要报告部分完成与未完成事项。

设计初值：最多 20 次模型轮次、每轮最多 8 个工具、默认命令 60s、流空闲 120s、活动运行总计 15min；审批等待单独计时，最长 5min，超时拒绝。总工具并发 3，同一资源写操作串行。M4 实测后统一调整，不使用 Netcatty 数小时的预算作为默认。

Stop 唯一入口：取消 HTTP → 失效所有未决审批 → 停止调度新工具 → 取消该 turn 所有执行 → 有界等待 → 返回每项 cancelled/unknown 状态。关闭聊天面板不等于停止任务；退出应用则经关闭协调处理。

## 5. 工具与软件控制

所有工具默认不暴露，按 allowlist 从已有 capability 导出；上下文决定当前可用子集，不一次塞入几十个 CRUD 工具。

| 工具组 | 初期能力 | 约束 |
|---|---|---|
| 应用上下文 | app.getState、host.list、session.list | 只返回授权范围；“当前”在调用时固化为具体 ID |
| 诊断 | command.execute、terminal.read、output.read | 任意 shell 默认审批；buffer 有行数/字节上限 |
| 外观布局 | settings.patch、workspace.split/focus | 只允许普通设置白名单，可逆变更记录 before/after |
| 会话 | session.open/reconnect | 已授权主机；不能扩大 scope；认证由用户完成 |
| 文件 | files.list/stat/read；随后 write | 路径限制、敏感读取策略、大小限制，写入预览 diff |
| 后续 | forwarding.start/stop、host.update | 逐项审计；不能因存在 capability 就自动加入 |
| 计划 | plan.update | 表示任务进度，不作为权限或执行证据 |

getState 提供 activeTabId、focusedPaneId、scope revision、授权 host/session 摘要、相关任务状态。模糊的“关掉那个”无法解析时询问，不根据 hostname 模糊匹配删除对象。

## 6. 命令执行与可见性

Netcatty 默认会把包装后的命令写入用户可见 PTY，靠开始/结束 marker 捕获退出码；其网络设备还用空闲超时判断结束。这需要处理 shell 探测、正在运行的 TUI、用户同时输入、marker 串流切分与无退出码，不能简单照搬。

**sshairy 首版选择：独立 SSH exec channel + 可见的执行记录卡片。** 展示完整目标、命令、stdout/stderr、退出码、耗时、停止按钮。该内容不伪装成用户交互终端中的真实输入。

- 每次 exec 是独立环境；cwd 必须显式给出，执行 cd/export 不会修改用户 shell。POSIX/PowerShell 等引用由已验证的 shell adapter 处理，未知 shell 则不自动执行包装。
- 交互命令、sudo 密码、全屏 TUI 需要用户接管；AI 不能读取认证输入，也不能在后台等一个永远不会出现的密码框。
- 后续可增加 AI 自有可见 PTY 会话，需单一输入所有权与显式接管；绝不直接抢占用户正在 vim/tmux 的 shell。
- exec 不支持或堡垒机只允许单通道时明确 unsupported/需要独立连接，不能偷偷改为在用户 terminal 输入。
- 关闭 channel/Ctrl+C 不能证明远端全部子进程已停；状态可为 terminationUnknown。后台 job 若引入，需 jobId、轮询 offset、TTL、停止语义，另行验收。

## 7. 权限与提示注入

默认 Confirm 模式。Observer 只允许限定元数据和用户授权读取，不运行任意 shell；Auto 仅在明确主机/能力/期限范围内授予，后续再做。

- 任意 shell 不能可靠归类“只读”；`cat` 也能读秘密，命令可含替换、重定向、函数。黑名单仅提供风险提示，不是授权边界。
- 授权来自用户选择和应用上下文，模型不能生成 grant。审批绑定精确参数/目标/revision；暂停期间改了 scope 或 host 配置后要重验。
- 首版只支持允许一次、拒绝、对普通可逆设置的会话授权；不实现 `git *` 这类宽泛永久 shell 前缀授权。
- 远端文件、终端输出、主机标签、摘要均标为不可信数据；其中的“忽略规则/新增主机授权”等不改变策略。
- AI 不得改 host trust、API endpoint、凭据、安全选项、审批开关或 scope。删除主机、导出配置、远程写入不能借 settings.patch 旁路完成。
- 脱敏覆盖请求文本、工具参数、结果、输出句柄、日志和压缩摘要；regex 不保证发现所有秘密。用户发送引用需看见将发送的范围，敏感文件路径按策略限制。

## 8. 上下文、持久化和重试

保留系统规则、用户目标、授权 scope、关键决定、计划和未完成任务。估算 budget 同时计入 system/tools/messages/output reserve，不能仅计算聊天文本。初值达到可用输入预算约 70% 时压缩，给长工具结果留余量；精确阈值随模型配置验证。

单工具模型可见输出默认 8 KiB，首尾保留且返回有权限/TTL 的 outputHandle；完整输出全局内存上限初值 8 MiB，单项 2 MiB，超额明确截断或安全落盘。output.read 每次最多 8 KiB，并限制每轮累计读取。终端全屏缓冲不是每轮自动发送的上下文。

摘要不得切开 call/result 配对；保留最近完整轮次、错误和用户修正。摘要不是权限来源。压缩失败可保留安全尾部并告知，不能虚构任务结果。仅将用户当前 scope 所需工具和主机信息送入模型。

重试规则：

- 429/5xx 的未完成模型请求最多 2 次指数退避，遵守 Retry-After，总预算内进行；中途断流不能导致半个 tool call 执行。
- 413 最多一次强制压缩再发，不自动重跑已执行工具。
- tool 执行使用 operationId 日志；已完成调用返回已有结果。写入已发送但结果未知时必须停下核实，不能只用 command 文本指纹保证“恰好一次”。
- 同命令被用户明确再次请求应有新 operationId，允许正常再次执行。

对话按文件保存版本化、脱敏、有界记录；写失败保留内存并提示。历史分支/撤回只改变对话，不撤销远程行为。AI 改设置可调用真正有 revision 校验的 undo；shell 不显示虚假“撤销成功”。

验收：A-01 流协议分片；A-02 工具配对/取消；A-03 权限与注入；A-04 重试不重放；A-05 AI 设置操作与禁用后的 SSH 独立性。标准见 TESTING。
