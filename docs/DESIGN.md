# sshairy 设计总纲

> Lightweight SSH. Powered by AI.

版本：v0.3 · 2026-11-06。Flutter 桌面应用已可运行，实际完成与验证范围以 ROADMAP 为准；本文件同时包含后续设计目标。此前聊天中的示意代码和未经实测的性能数字不作为实现依据。

## 1. 确定的产品约束

- Flutter + Dart，Windows / macOS / Linux 桌面端，不做移动端和 Web。
- 开源，主要供作者自用，不提供兼容性和可用性保障；参考 Netcatty 的现代界面与实用工作流，交互应更流畅。
- 日常内存约 200 MB；不为极端压缩内存牺牲可用性。
- 先完成 SSH 客户端，再加入 AI；AI 后续可管理主机、会话、布局和设置。
- 高内聚、低耦合、便于扩展；文档支持不同模型接续开发。
- 界面靠布局表达含义，减少多余的标题和说明。

采用模块化单体、独立实现。MIT 是建议许可证：用户已确认开源，未单独确认许可证；发布前确定 LICENSE，审计依赖、代码、字体、图标许可。不能因参考功能而复制 GPL 代码或品牌素材。

约 200 MB 是目标，不是实测结果，也不是任意会话数量下的硬上限。不承诺空闲必低于 100 MB 或包体必低于 40 MB。测量口径见 TESTING。

## 2. 文档入口

| 文档 | 权威范围 |
|---|---|
| [DESIGN.md](DESIGN.md) | 产品约束、架构、依赖、决策 |
| [MODULES.md](MODULES.md) | 功能、模型、状态机、边界 |
| [CONTRACTS.md](CONTRACTS.md) | 能力调用、资源所有权、错误与事件 |
| [SECURITY.md](SECURITY.md) | 凭据、主机信任、存储与安全边界 |
| [UI.md](UI.md) | 视觉、布局、交互、键盘与无障碍 |
| [AI.md](AI.md) | 二期 harness 与模型协议 |
| [TESTING.md](TESTING.md) | 真实环境测试规则、技术实验、功能检查 |
| [ROADMAP.md](ROADMAP.md) | 里程碑、当前进度、交接记录 |
| [NETCATTY_REVIEW.md](NETCATTY_REVIEW.md) | 固定版本源码证据和取舍理由 |
| [CORRECTION.md](CORRECTION.md) | 2026-11-06 纠偏与自绘窗口实施约束 |
| [BRAND.md](BRAND.md) | GPT 生成图标的设计约束、来源与导出 |
| [DESIGN_AUDIT.md](DESIGN_AUDIT.md) | 对照最早设计的复核、已确认边界和未修复缺陷 |
| [HOST_INHERITANCE.md](HOST_INHERITANCE.md) | 分组、身份、全局默认值与三态继承 |
| [CONFIG_RECOVERY.md](CONFIG_RECOVERY.md) | 配置迁移、进程锁与快照恢复 |
| [DIAGNOSTICS.md](DIAGNOSTICS.md) | 结构化、脱敏的诊断日志 |
| [EXTERNAL_EDITS.md](EXTERNAL_EDITS.md) | 外部编辑器、私有副本与清理 |
| [TERMINAL_FLOW.md](TERMINAL_FLOW.md) | 终端输出的流控与背压 |
| [WORKSPACE_LAYOUT.md](WORKSPACE_LAYOUT.md) | 工作区、主机树与工具面板布局 |

每次先读本文件与 ROADMAP，再读对应专题。用户新指示优先于文档。发现代码、测试、文档冲突时记录并修订，不把待验证项当事实。涉及决策的修改同步更新对应规范，不机械要求每个代码变更都修改全套文档。

## 3. 范围与阶段

| 阶段 | 交付能力 |
|---|---|
| M0 技术验证 | Windows 上的最小窗口，SSH+终端；验证背压、IME、主机校验，测内存与帧耗时基线 |
| M1 SSH 可用版 | 主机/分组、密码/密钥/交互认证、凭据、known hosts、多标签、重连、设置、命令面板 |
| M2 文件工作流 | SFTP 浏览、可靠上传下载、队列、冲突处理、外部编辑 |
| M3 桌面主力版 | 分屏、跳板/代理、L/R/D 转发、片段、SSH config 导入、布局恢复 |
| M4 AI 首版 | 两类模型协议、诊断循环、审批、终端上下文、应用设置/布局能力 |
| M5 按反馈扩展 | 本地 PTY、ssh-agent、应用锁、广播、关键词高亮、监控、加密备份 |

一期 = M0–M3；AI 在 M4。M5 不阻塞 AI。分屏领域模型可以先做，正式交付在 M3。

本轮不做：插件市场、MCP、云同步、内嵌浏览器、Monaco/完整 IDE、独立笔记、Mosh/ET/Telnet/串口/X11/ZMODEM、FIDO、终端图片协议、外部 CLI Agent 集成。可记录新需求，不预建占位实现。

## 4. 架构

采用单 Flutter 应用、按功能组织、静态依赖装配。先用目录边界，不拆成一堆 package，不建运行时插件注册平台。

```text
lib/
  app/                 启动、静态装配、关闭协调、模块组合
  foundation/          ID、Result、错误、取消、时钟、脱敏日志
  design/              tokens、主题、无业务含义的基础组件
  platform/            凭据库、文件对话框、窗口、外部程序等适配
  features/
    hosts/             主机、分组、身份和连接配置解析
    credentials/       密钥元信息、SecretRef、凭据存储
    connections/       SSH transport/channel/lease/信任校验
    terminal/          terminal model、输入输出与视图适配
    workspace/         标签、分屏、焦点和布局快照
    files/             SFTP 浏览、文件操作、传输、外部编辑
    forwarding/        隧道规则与运行实例
    snippets/          命令片段
    settings/          定义、校验、变更和持久化
    capabilities/      可编排能力描述、调度、策略接口
    ai/                M4 才建立
```

模块按需要拥有 `domain/`、`application/`、`adapters/`、`presentation/`、`api.dart`。没有对应职责就不建空目录。小模块不用凑齐四层。

### 4.1 依赖规则

- domain 为纯 Dart 模型与规则，不依赖 Flutter、Riverpod、IO 或供应商库。
- application 持有用例与运行状态，依赖窄接口；Riverpod 用于装配、订阅和 UI 状态，不让 Ref 贯穿领域接口。
- adapters 实现 SSH、持久化等接口。第三方库限定在适配目录，不是强制只准一个文件。终端 Widget 的第三方引用留在专用视图适配器，不假装它是纯数据层。
- presentation 只用公开用例和状态，不自行拨号、写文件、读私钥或调用模型。
- 跨模块只能 import `api.dart`；导出本模块实际公共契约，不导出全部内部文件。禁止循环依赖。
- foundation 不知道任何 feature；design 只含通用控件。HostCard 属于 hosts，不放通用设计系统。

允许依赖方向：

```text
hosts -> credentials 公共元信息/引用
connections -> hosts 的 ResolvedConnectionSpec、credentials 的凭据解析端口
terminal -> connections 的 ShellChannel/Lease
files、forwarding -> connections 的通道/租约
workspace -> terminal 的会话 API
snippets -> terminal 的受控发送 API
capabilities -> 各模块公开用例（不反向依赖 capabilities）
ai -> capabilities、受限上下文/执行端口
app -> 以上模块，负责跨模块流程组合
```

连接模块内部持有 KnownHostRepository 端口；信任管理页面也可放在 connections，不与 hosts 互相调用。各模块通过构造参数获得 Settings 子集，避免所有模块订阅整个设置对象。

### 4.2 状态和通信

每份状态有唯一所有者：HostRepository 管配置；ConnectionManager 管 transport；TerminalSessionManager 管 shell/model；WorkspaceController 管布局；TransferManager 管任务；ForwardManager 管隧道。Widget 挂载不是后台任务的寿命边界。

需要结果就直接调用 typed API；需要变化通知就订阅该服务的类型化 Stream。先不建全局 EventBus，也不靠事件串行触发重要业务事务。转发进度只更新转发区域，终端字符输出不触发全应用重建。

并发操作使用资源级串行队列（同路径、同设置修订、同会话），异步结果带 generation，过期结果不能覆盖新状态。每个资源都有明确 dispose/cancel 和所有者，详见 CONTRACTS。

### 4.3 为 AI 保留能力边界，而非把 UI 变成 RPC

统一的是业务用例及其授权校验，不是每次 setState。主机变更、连接、传输、持久化设置、布局命令可登记为 Capability；光标移动、hover、拖动中间帧、表单草稿和每个终端按键不经过 JSON 注册表，也不逐键审计。

UI 可以通过 typed façade 调用同一用例；命令面板和 AI 经 CapabilityDispatcher 调用。所有有副作用的入口共享必要校验。调度器集中做来源、范围、审批和安全投影。凭据挑选、信任密钥变更等用户专属操作另有明确入口，AI 不获同等权限。

一期只实现已存在功能的少量能力描述，不建模型 provider、聊天表或 Agent 循环。不承诺二期“一行既有代码都不改”；目标是无需重写 SSH/SFTP/设置核心，只扩展公开契约与装配。

## 5. 技术选型与验证门槛

| 项目 | 选择/候选 | 实施要求 |
|---|---|---|
| UI | Flutter stable + 其匹配 Dart | M0 记录精确版本；提交 lockfile；不提前固定过时大版本 |
| 状态与装配 | Riverpod | 使用实施时兼容稳定版；不叠加 get_it/另一套全局状态框架 |
| SSH/SFTP | dartssh2 候选 | 验证多轮 KI、加密密钥、host verifier、rekey、取消、转发与背压 |
| Terminal | xterm2 候选 | 验证中文 IME、重排、宽字符、搜索、buffer API、性能；不能等同 xterm.js |
| 渲染（Windows） | Skia 默认，设置里可切 Impeller | runner 启动前读设置，重启生效；升级 Flutter 时复测两者内存，Skia 被移除时重新评估 ADR-11 |
| 持久化 | 小配置 JSON、任务快照/有界日志 | 单写入者、版本迁移、备份恢复；规模增长后再评估 SQLite |
| 密钥存储 | flutter_secure_storage 候选 | 在实际使用的平台上验证，禁止明文降级；见 SECURITY |
| 窗口/文件 | window_manager、系统文件选择器候选 | 原生拖动、缩放、DPI、键盘可访问性先通过验证 |
| 模型类 | Dart sealed/final，不可变值 | JSON 编解码按需生成；不强制所有类用 Freezed |
| 本地 PTY | flutter_pty 或其他维护实现 | M5 再验证 ConPTY/Unix PTY；不阻塞 SSH |

依赖批准需记录版本、许可、维护和未解决问题。xterm3 的 AGPL 许可与 MIT 目标存在发行约束，不能作为无成本替换；替换 SSH 库也不能解决终端渲染瓶颈。先定位瓶颈，再决定优化、维护 fork 或 FFI。

## 6. 关键决策记录

| ID | 决策 | 理由与替代方案 |
|---|---|---|
| ADR-01 | 模块化单体，静态装配 | 单应用阶段足够；不用插件总线、动态加载或多 package 框架 |
| ADR-02 | typed 用例 + 精选 Capability | 兼顾 UI 性能、编译检查与 AI 编排；替代“所有变化都 JSON 化” |
| ADR-03 | transport/channel/lease/view 分离 | 关闭面板不能断掉传输；不同路由和身份不能错复用 |
| ADR-04 | 200 MB 作为可测日常目标 | 不用第三方回滚测试按行数线性推算内存 |
| ADR-05 | 凭据不进入 Host DTO | SecretRef、显式读取和安全投影；不依赖 toString 脱敏作为安全保证 |
| ADR-06 | AI 首版独立 exec + 可见执行记录 | 不抢占用户 vim/交互 shell；专用可见 PTY 后续验证 |
| ADR-07 | 外部编辑优先 | 保留远端冲突检查；不内嵌 Monaco，不静默覆盖 |
| ADR-08 | 源码复杂度不等于浪费 | 流控、原子发布、取消、迁移均有真实失败场景；只删未选功能 |
| ADR-09 | M0 只验证终端方案 | 信任库的基础能力，只测集成风险和未证实行为；SFTP、凭据、窗口等到用到时验证，失败代价可控 |
| ADR-10 | 只在作者真实环境测试 | 开源自用，不做兼容性保障；Windows + 作者的 Ubuntu 服务器为准，其他平台未验证不阻塞；不建 Docker、fixture、CI 矩阵。安全规则不因此放宽 |
| ADR-11 | Windows 默认 Skia 渲染 | 空白 Flutter 应用开 Impeller 就占 244 MB，最大化后 430 MB，主要是核显共享内存里的渲染缓冲；Skia 下 97/131 MB（TESTING §6）。界面以文字和平面控件为主，Impeller 预编译着色器的好处用不上。保留切换，作为 Skia 出问题或被移除时的退路 |
| ADR-12 | Windows 无系统顶栏、自绘窗口控件 | 用户于 2026-11-06 明确要求；Flutter 顶栏与标签区域融合，原生 runner 保留缩放、DPI 和系统关闭生命周期。macOS/Linux 尚无同等实测，不假装自绘已覆盖三端。实现和验证见 CORRECTION、ROADMAP |

新增决策在此记录，详细实现只放对应专题，避免多个文件维护不同默认值。
