# 主机分组、身份与继承（一期）

MODULES §1 的具体落地；与当前 Host/连接端口保持兼容，用户无需手工改配置。

- `hosts.json` schema 2 在同一快照保存主机、独立 Group（id/parentId/name/order/defaults）、Identity（id/revision/label/username/AuthPolicy）和全局 defaults。Host 增加 groupId 与 connectionOverrides；显示用 group 路径从组关系导出，不作为树的身份。
- schema 1→2 为纯转换：按旧 `/` 分组路径生成稳定的组 ID、建立父子关系，将原用户名/认证/端口/跳板/代理/legacy 全部变为显式主机覆盖。旧连接行为不因迁移突然继承新默认值。读取只转换内存，首次成功保存前由 JsonFile 保护旧副本；失败保留原件，不回落空库。
- `OverrideValue<T>` 区分 inherit / disabled / value。认证（用户名与整个 AuthPolicy）、端口和 legacy 不可 disabled；jump/proxy 可 disabled，表示显式直连。value(false) 不等于 inherit，禁用某字段不影响其他字段。
- 纯解析按内置默认值（port 22、现代算法、无跳板/代理、未指定身份）→全局→根组→子组→主机覆盖。认证整体替换，Identity 引用解析为一份 username/AuthPolicy；不能混合继承另一个身份的密码和密钥。解析返回每个字段的来源，编辑界面显示继承来源。缺引用、组循环、重名组、无效端口/用户/认证策略在提交前拒绝。
- AuthPolicy 使用系统密钥库 keyId 或现有 keyPath，绝不持有秘密。提供密码、密钥、密钥后密码三种偏好，keyboard-interactive 可单独允许/禁止；这是 dartssh2 当前公开 API 支持的顺序，反向顺序明确拒绝。密码仍绑定主机 SecretRef；Identity 共享用户名与认证配置，不偷偷共享已记住的主机密码。导入密钥的口令继续绑定密钥引用。
- HostsNotifier 保持现有 List<Host> 观察接口，内部只有一份不可变 library 快照；目录变更和主机变更共用串行队列与 expectedRevision。组/身份删除不级联删除主机；组解散把直接子项移到父组，身份仍被任何默认值/主机引用时拒绝删除；主机仍是别的主机、组或全局默认值的跳板时同样拒绝删除（`HostInUse`，列出引用方），不留悬挂引用。密钥引用检查覆盖未使用的 Identity、各级覆盖及主机，提交与密钥删除共用现有 withKeys 队列。
- ConnectionManager 在任何拨号前同步解析目标和完整跳板链，池键使用解析后的认证、路由与交互策略。配置编辑不关闭/重连现有连接；重连会重新取当前配置，既有连接保持创建时快照。所有直连、跳板、SFTP、转发继续走原 HostTrustService。
- 主机、分组、全局默认值共用一个 ConnectionEditor：端口、登录（身份或用户名+认证）、路由（跳板/代理）和 legacy 每项旁有链接图标，链接时禁用控件并显示继承值，提示来源（全局默认值 / 组路径 / 内置默认值）；取消链接以继承值为起点再改。新建主机只在没有任何默认值可继承的端口上直接取消链接，其余跟随上层；已有主机按其 overrides 回显，保存不改变它没动过的字段。分组与全局默认值的登录可以不设；主机必须从某一层得到登录。链接的登录不校验必填。代理仅在有效跳板为空时出现。
- 组面板同一次写入完成改名/移动与默认值替换，新建与改名遇到已存在路径一律拒绝（不合并）；解散组把成员上移并丢弃其默认值，有默认值时先确认。空组在主机库和树中可见，主机库的调节菜单进入全局默认值、身份和密钥。
- `HostsNotifier.moveToGroup(ids, groupId, expectedRevision:)` 单次串行写入移动单台或多台主机。目标必须是现有稳定组 ID，null 表示不分组并同时清空旧路径；从执行时最新主机读取，只改分组归属，保留 ID、覆盖、凭据引用及其他元信息。继承项按新组重新解析，新增无效路由、缺主机/目标、过期 revision 或写失败时整批不发布。UI 目标对话框绑定打开时 revision；保存失败保留对话框和选择。`host.move` 供 dispatcher 使用，输入非空 hostIds 数组和 groupId（可省略/null），仍不向 agent 开放。
- Capability（均不对 agent 开放）：`group.list/create/update/delete`、`identity.list/create/update/delete`、`hostDefaults.get/update`；`host.create/update` 沿用同一连接字段词汇：port、identityId、username、auth、methods、keyPath、keyId、allowInteractive、jumpHostId（空串=显式直连）、proxy（null=无）、legacy，另有 `inherit: [port|login|jump|proxy|legacy]` 表示该项继承。DTO 输出生效值与 `inherit`，不含 keyPath 和任何秘密。身份仍被引用时 `identity.delete` 返回 `inUse`；主机仍被当作跳板时 `host.delete` 也返回 `inUse`（detail 为引用方，全局默认值写作 `global`）。

已知限制：合并到已有组路径被拒绝；解散组丢弃其默认值；密钥文件无法加载时“密钥→密码”主机连接失败，不静默降级；引用身份的主机不共享已记住的密码；代理凭据仍按主机 ID 与代理键保存；新建主机在无默认值时自带端口，不跟随之后才设的全局端口。折叠的“连接路由”区里的代理地址或端口校验失败时，保存会自动展开该区，错误可见。

验证：纯三态/多层顺序/来源、认证整体替换、组循环与缺引用、schema1兼容、过期revision不覆盖、保存失败不发布、Identity引用的密钥不能删除、连接前解析（host_library_test、host_inheritance_test）；Capability 的字段词汇、归一化、拒绝与 inUse 映射（host_capabilities_test）；主机/组/全局默认值/身份/主机库的 widget 交互（host_editor_test，含组改名与拒绝已存在路径、解散确认、保存失败时展开折叠的路由区、被引用的跳板主机删除被拒并提示引用方）；主机库的删除保护与 `host.delete` 的 `inUse` 另见 host_library_test、host_inheritance_test、host_capabilities_test。真实服务器上的 key→password、keyboard-interactive 与密钥加载行为尚未验证，不由模型测试代替。
