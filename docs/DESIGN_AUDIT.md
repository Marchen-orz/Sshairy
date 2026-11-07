# 2026-11-06 设计复核

范围：最早提交 `ed04a9a` 的 DESIGN / UI / SECURITY，与当前 DESIGN、CONTRACTS、SECURITY、UI、NETCATTY_REVIEW、CORRECTION、TRANSFER_RESUME 及实际代码。评估时业务代码基线为 `db45d93`。评估当时只改图标与文档；下面三项业务缺陷已在 2026-11-07 修复，见各条“结果”。

## 结论

产品方向与模块化单体路线未变，上轮纠偏中的依赖方向、凭据公开边界、连接池安全 revision、配置损坏保护及退出失败反馈已落实到代码。仍不能声称“严格完成最初设计”：评估时发现的续传缺陷已修复，但 UI 保留了第一版的简化布局，流控、真实环境验收尚未完成。

无边框 Windows 窗口和明亮冰蓝是用户授权变更（ADR-12、CORRECTION），不算擅自偏离。用户要求的 GPT 生图也已实际执行；图标来源与导出见 BRAND。

## 已确认纠正的边界

| 约束 | 代码证据 |
|---|---|
| typed 用例，业务模块不反向依赖 capabilities | `lib/app/composition.dart:42` 装配目录；`tool/check_imports.dart:57`–`:69` 检查 app 依赖、跨 feature API 与反向 capability 依赖 |
| 凭据不进入 Host DTO，安全存储不直接公开给其他 feature | `lib/features/hosts/domain/host.dart:34`；`lib/features/credentials/api.dart:1`；`application/credential_access.dart:7` 的 ConnectionCredentials / HostCredentialCleanup |
| 密钥引用校验属于业务用例，删除前与主机引用提交串行 | `lib/features/credentials/application/keys.dart:63`、`:119`；`lib/app/composition.dart:21` 注入引用查询 |
| 每条拨号路径经统一信任校验，池键含安全修订 | `lib/features/connections/adapters/ssh.dart:208`–`:255` 的跳板/代理/直连与 verifier；`application/providers.dart:43`；`application/connection_manager.dart:76` |
| 损坏或未来配置不当空库覆盖 | `lib/foundation/json_file.dart:59`、`:84`、`:120`、`:205`、`:224`；损坏恢复先保护原件、校验领域结构 |
| 退出失败不假装保存完成，取消退出恢复工作 | `lib/app/shutdown.dart:60`–`:86`；transfers/edits/forwards 分别 shutdown 与 resumeAfterShutdown |
| 不提前建立 AI harness，能力默认不向 AI 暴露 | `lib/features/capabilities/domain/capability.dart:30`；当前 feature 中没有 M4 的空壳实现 |

这些结论是代码边界核查，不代替真实服务器与所有窗口行为的验收。

## 复现的业务缺陷（已修复）

### 1. 合法的“保留两者”名称无法续传和清理

`lib/features/files/domain/transfer.dart:140` 在比较第一个候选后，只要其长度不小于实际名称就立即返回 false。实际目标 `a (2).txt` 与 `a (1).txt` 等长，因此循环在检查到 `(2)` 前就退出。

影响：保留两者产生 `(2)`–`(9)` 等正常名字时，已暂停任务恢复报 partInvalid；移除或从头重试也复用 partDerived，因此清理会被拒绝为 leftoverPart。只覆盖 `(1)` 的现有测试没有暴露此问题。

违反：TRANSFER_RESUME §Checkpoint / §恢复与资源保护，合法同目录保留两者路径应可恢复及清理。

结果：已修复；`test/files_test.dart` 的“every allocated keep-both suffix is resumable on both path styles”与“later keep-both targets resume and clean up without touching existing copies”覆盖。

### 2. 文件变为目录时，恢复绕过源身份检查并误报完成

`lib/features/files/application/transfers.dart:244` 先按当前 stat 的类型进入 directory 分支，只有 file 分支才在 `:253` 检查 checkpoint 并调用 resumeFile。

本机复现：创建普通文件与 settled checkpoint → 删除源文件并在同路径创建目录 → 恢复。实际结果是 completed，目录中的新文件被复制，checkpoint 被清除，原先 `.part` 留在目标旁；预期应为 sourceChanged，且不开始目录复制。

违反：TRANSFER_RESUME §恢复与资源保护规定恢复前检查源的类型、大小和修改时间。

结果：已修复；“a file replaced by a directory fails before copying and keeps its part”覆盖。

### 3. 恢复任务 ID 可以破坏 `.part` 的同目录约束

`lib/foundation/ids.dart:14` 的 TransferId 包装任意字符串；`lib/features/files/domain/transfer.dart:271` 从历史直接还原。partPathFor 在 `:46` 将 ID 直接拼入路径；partDerived 在 `:131` 只检查字符串派生关系，没有拒绝 ID 中的分隔符或 `..` 路径段。

纯结构探针：ID 为 `x/../../outside`，目标 `/safe/a.txt` 时，派生 `.part` 为 `/safe/.a.txt.x/../../outside.part`，checkpointProblem 返回 null。该路径已经不是同目录单个文件名。探针仅验证校验结果，未访问或删除派生路径。

影响：当前恢复 JSON 的校验不能兑现“不信任历史提供的任意删除路径”的约束；后续清理通过校验即可 stat/delete cp.part。应在领域反序列化时验证任务 ID 为安全文件名片段，并在清理/恢复前再次检查路径约束。此处不声称可防御已控制当前 OS 用户的程序，也不把本机配置问题描述为远程可利用漏洞。

违反：TRANSFER_RESUME §Checkpoint；SECURITY §5。

结果：已修复；“unsafe historical IDs cannot create or own a part on either path style”与恢复记录非法时进入配置保护页的测试覆盖。

## 尚未完成的原始设计

- **UI 布局**：2026-11-07 起终端工作区已接入主机树（`workspace_page.dart` 的 `HostTree`）。评估当时指出的整页切换、片段和转发放在更多菜单仍以现有布局为准；工具栏收敛和编辑抽屉符合纠偏要求，但不等于原始信息架构已完成，也未做新的窗口手动验收。
- **面板自适应**：`workspace_page.dart:398` 的文件侧栏固定 360，没有 300–560 可调宽度及空间不足转覆盖面板的逻辑。最小 960 窗口可给主终端留下空间，但分屏或大字时没有规范要求的自适应行为。
- **终端流控**：已按 TERMINAL_FLOW 实现应用层有界队列、水位和时间切片并有单元测试；库背压与队列测试不能等同 T-03 已完成，高输出下 Ctrl+C、最小化和实际内存仍需 Windows/Ubuntu 实测。
- **配置恢复与迁移**：JsonFile 已有 revision、写保护、自动快照恢复、逐版迁移和启动恢复入口（CONFIG_RECOVERY）；hosts.json 已有 schema 1→2 迁移。
- **主机模型**：已实现独立 Group、Identity、全局默认值与继承解析（HOST_INHERITANCE），含编辑界面与 Capability；真实服务器上的 key→password、keyboard-interactive、密钥加载未验。
- **验收**：本轮未连接服务器，未测真实转发 L/R/D、SFTP 续传哈希、10 GB 传输、多会话日常内存和全部无边框窗口交互。200 MB 仍是目标，不作为当前运行结论。

## 文档一致性

本轮发现 SECURITY §4“当前实现”仍写着“无 revision”“坏文件当空数据”“备份失败不阻止保存”，ROADMAP“第一版简化”仍写“池键没有凭据/信任 revision”，MODULES §5 仍称转发入口和退出流程待接线；这些描述已落后代码。本轮同步修订当前状态，保留未完成与未验收项，不通过放宽原始硬约束消除缺陷。

## 验证记录

2026-11-07：`flutter test --no-pub` 全量 284 项通过；`flutter analyze --no-pub` 无问题；`dart run tool/check_imports.dart` imports ok。新增 host_library/host_inheritance/host_capabilities/host_editor 与 external_edits 测试已含在内。仍未连接真实服务器，也未做新的窗口手动验收。

以下为 2026-11-06 评估当时的记录：

- 当前正式测试：`flutter test --reporter expanded`，200 项通过。
- `flutter analyze --no-pub`：无问题；`dart run tool/check_imports.dart`：imports ok。
- 3 个临时本机探针复现上述三项业务问题；探针对“现状缺陷”作断言，因此其执行成功表示复现成功，不表示实现正确。探针放在忽略目录 `.dart_tool/`，不加入正式测试套件。
- 临时探针首次运行遇到 Windows 的 `build/unit_test_assets` 目录占用，改用 `--no-test-assets` 后执行完成；不涉及远程服务器。
- 新 logo 的 PNG alpha、ICO 16/24/32/48/64/128/256 与 macOS 导出尺寸已核对；明暗背景和小尺寸预览已查看；`flutter build windows --debug --no-pub` 成功。未进行新的窗口手动交互验收。

续传缺陷已修复并有正式回归测试；后续补原始布局、终端流控及真实环境验收。新功能数量不能代替这些可靠性要求。
