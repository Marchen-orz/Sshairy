// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get hosts => '主机';

  @override
  String get newHost => '新建主机';

  @override
  String get searchHint => '搜索主机或 user@host';

  @override
  String connectTo(String target) {
    return '连接 $target';
  }

  @override
  String get connect => '连接';

  @override
  String get edit => '编辑';

  @override
  String get delete => '删除';

  @override
  String deleteHost(String name) {
    return '删除 $name？';
  }

  @override
  String hostInUse(String names) {
    return '是 $names 的跳板';
  }

  @override
  String get save => '保存';

  @override
  String get cancel => '取消';

  @override
  String get close => '关闭';

  @override
  String get retry => '重新连接';

  @override
  String get label => '名称';

  @override
  String get address => '地址';

  @override
  String get port => '端口';

  @override
  String get username => '用户名';

  @override
  String get password => '密码';

  @override
  String get privateKey => '私钥';

  @override
  String get keyPath => '私钥文件';

  @override
  String get passphrase => '私钥口令';

  @override
  String get remember => '记住';

  @override
  String get required => '必填';

  @override
  String get invalidPort => '1–65535';

  @override
  String get connecting => '正在连接…';

  @override
  String get disconnected => '连接已断开';

  @override
  String get hostKeyUnknown => '未知主机';

  @override
  String get hostKeyChanged => '主机密钥已改变';

  @override
  String get hostKeyChangedWarning => '可能存在中间人攻击。只有确认服务器更换过密钥时才替换。';

  @override
  String get previousKey => '已保存';

  @override
  String get currentKey => '本次收到';

  @override
  String get trustOnce => '仅本次';

  @override
  String get trustSave => '信任';

  @override
  String get replaceKey => '替换已保存的密钥';

  @override
  String errConnect(String detail) {
    return '无法连接：$detail';
  }

  @override
  String get errAuth => '认证失败';

  @override
  String get errHostKeyRejected => '已拒绝主机密钥';

  @override
  String errKeyFile(String detail) {
    return '无法读取私钥：$detail';
  }

  @override
  String get errCancelled => '已取消';

  @override
  String get settings => '设置';

  @override
  String get theme => '主题';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get fontSize => '终端字号';

  @override
  String get language => '语言';

  @override
  String get langZh => '中文';

  @override
  String get langEn => 'English';

  @override
  String get paste => '粘贴';

  @override
  String get noMatches => '没有匹配的主机';

  @override
  String get more => '更多';

  @override
  String get renderer => '渲染器';

  @override
  String get restartToApply => '重启后生效';

  @override
  String get accent => '配色方案';

  @override
  String get themeNameBlue => '冰蓝薄荷';

  @override
  String get themeNameGreen => '薄荷绿';

  @override
  String get themeNameViolet => '紫罗兰';

  @override
  String get themeNameOrange => '日落橙';

  @override
  String get themeNameDeepSea => '深海蓝';

  @override
  String get themeNamePink => '樱花粉';

  @override
  String get navigationExpand => '展开导航';

  @override
  String get navigationCollapse => '收起导航';

  @override
  String get commandPalette => '命令面板';

  @override
  String get paletteHint => '主机、会话、操作';

  @override
  String get split => '分屏';

  @override
  String get splitRight => '向右分屏';

  @override
  String get splitDown => '向下分屏';

  @override
  String get closePane => '关闭窗格';

  @override
  String get newConnection => '新建连接';

  @override
  String get appearance => '外观';

  @override
  String get terminal => '终端';

  @override
  String get connection => '连接';

  @override
  String get dataSecurity => '数据与安全';

  @override
  String get about => '关于';

  @override
  String get cursorShape => '光标';

  @override
  String get cursorBlock => '方块';

  @override
  String get cursorUnderline => '下划线';

  @override
  String get cursorBar => '竖线';

  @override
  String get scrollback => '回滚行数';

  @override
  String get copyOnSelect => '选中即复制';

  @override
  String get rightClick => '右键';

  @override
  String get rightClickMenu => '菜单';

  @override
  String get confirmPaste => '多行粘贴前确认';

  @override
  String get connectTimeout => '连接超时';

  @override
  String get keepAlive => '保活间隔';

  @override
  String get idleTtl => '空闲连接保留';

  @override
  String get autoReconnect => '自动重连';

  @override
  String get off => '关闭';

  @override
  String seconds(int n) {
    return '$n 秒';
  }

  @override
  String get appliesNextConnection => '新连接生效';

  @override
  String get appliesNewSessions => '新会话生效';

  @override
  String get trustedKeys => '已信任的主机密钥';

  @override
  String get none => '无';

  @override
  String get remove => '移除';

  @override
  String get version => '版本';

  @override
  String get dataDir => '数据目录';

  @override
  String get open => '打开';

  @override
  String get find => '查找';

  @override
  String matchCount(int current, int total) {
    return '$current/$total';
  }

  @override
  String get noResults => '无结果';

  @override
  String get previous => '上一个';

  @override
  String get next => '下一个';

  @override
  String get caseSensitive => '区分大小写';

  @override
  String get regex => '正则表达式';

  @override
  String get copy => '复制';

  @override
  String get selectAll => '全选';

  @override
  String get clearScreen => '清屏';

  @override
  String get openLink => '打开链接';

  @override
  String get copyLink => '复制链接';

  @override
  String get rename => '重命名';

  @override
  String get duplicate => '复制标签';

  @override
  String reconnectingIn(int n) {
    return '$n 秒后重连';
  }

  @override
  String get stop => '停止';

  @override
  String get keys => '密钥';

  @override
  String get importKey => '导入密钥';

  @override
  String get generateKey => '生成密钥';

  @override
  String get keySource => '私钥内容或文件路径';

  @override
  String get keyFile => '密钥文件';

  @override
  String get copyPublicKey => '复制公钥';

  @override
  String keyInUse(String names) {
    return '正在被 $names 使用';
  }

  @override
  String deleteKey(String name) {
    return '删除密钥 $name？之后主机将无法使用它。';
  }

  @override
  String get errKeyUnsupported => '不支持的私钥格式';

  @override
  String get errKeyNeedsPassphrase => '该密钥已加密，请输入口令';

  @override
  String get errKeyWrongPassphrase => '口令错误';

  @override
  String errKeyDuplicate(String name) {
    return '已导入为 $name';
  }

  @override
  String get errKeyUnreadable => '无法读取文件';

  @override
  String get group => '分组';

  @override
  String get tags => '标签';

  @override
  String get tagsHint => '用逗号分隔';

  @override
  String get allHosts => '全部';

  @override
  String get pin => '置顶';

  @override
  String get unpin => '取消置顶';

  @override
  String get sortName => '按名称';

  @override
  String get sortRecent => '按最近连接';

  @override
  String get gridView => '网格';

  @override
  String get listView => '列表';

  @override
  String copyOf(String name) {
    return '$name 副本';
  }

  @override
  String get dissolveGroup => '解散分组';

  @override
  String get sftp => 'SFTP';

  @override
  String get files => '文件';

  @override
  String get thisComputer => '本机';

  @override
  String get back => '后退';

  @override
  String get forward => '前进';

  @override
  String get up => '上级目录';

  @override
  String get refresh => '刷新';

  @override
  String get filter => '筛选';

  @override
  String get editPath => '编辑路径';

  @override
  String get newFolder => '新建文件夹';

  @override
  String get hiddenFiles => '隐藏文件';

  @override
  String get uploadFiles => '上传文件…';

  @override
  String get downloadTo => '下载到…';

  @override
  String get sendToOther => '发送到另一侧';

  @override
  String get editFile => '编辑';

  @override
  String get copyPath => '复制路径';

  @override
  String get permissions => '权限';

  @override
  String get colName => '名称';

  @override
  String get colModified => '修改时间';

  @override
  String get colSize => '大小';

  @override
  String get colOwner => '所有者';

  @override
  String get emptyFolder => '空文件夹';

  @override
  String deleteOne(String name) {
    return '删除“$name”？';
  }

  @override
  String deleteTree(String name, int count) {
    return '删除“$name”及其中的 $count 项？';
  }

  @override
  String deleteMany(int count) {
    return '删除 $count 项？';
  }

  @override
  String get permOwner => '所有者';

  @override
  String get permGroup => '组';

  @override
  String get permOthers => '其他人';

  @override
  String get permRead => '读';

  @override
  String get permWrite => '写';

  @override
  String get permExecute => '执行';

  @override
  String get transfers => '传输';

  @override
  String get clearFinished => '清除已结束';

  @override
  String get tsQueued => '排队中';

  @override
  String get tsWaiting => '等待选择';

  @override
  String get tsCompleted => '完成';

  @override
  String get tsFailed => '失败';

  @override
  String get tsCancelled => '已取消';

  @override
  String get tsInterrupted => '已中断';

  @override
  String get tsScanning => '扫描中';

  @override
  String get tsVerifying => '校验中';

  @override
  String get tsPublishing => '发布中';

  @override
  String skippedCount(int count) {
    return '跳过 $count 项';
  }

  @override
  String filesCount(int done, int total) {
    return '$done/$total 个文件';
  }

  @override
  String conflictFile(String name) {
    return '“$name”已存在';
  }

  @override
  String conflictDir(String name) {
    return '文件夹“$name”已存在';
  }

  @override
  String conflictType(String name) {
    return '“$name”已存在，类型不同';
  }

  @override
  String get existingItem => '现有';

  @override
  String get incomingItem => '传入';

  @override
  String get replace => '替换';

  @override
  String get merge => '合并';

  @override
  String get keepBoth => '保留两者';

  @override
  String get skip => '跳过';

  @override
  String get applyToAll => '本批次同类冲突都这样处理';

  @override
  String get upload => '上传';

  @override
  String get autoUpload => '保存时自动上传';

  @override
  String get finishEdit => '结束编辑';

  @override
  String discardEdit(String name) {
    return '“$name”有未上传的修改，要放弃吗？';
  }

  @override
  String get discard => '放弃';

  @override
  String get editConflict => '下载后服务器上的文件已被修改';

  @override
  String get overwrite => '覆盖';

  @override
  String get uploadAsCopy => '另存为副本';

  @override
  String get redownload => '重新下载';

  @override
  String get esModified => '未上传';

  @override
  String get esUploading => '上传中';

  @override
  String get esClean => '已同步';

  @override
  String get errFsNotFound => '不存在';

  @override
  String get errFsPermission => '没有权限';

  @override
  String get errFsExists => '已存在';

  @override
  String get errFsUnsupported => '服务器不支持此操作';

  @override
  String get errFsLost => '连接已断开';

  @override
  String get errFsFailed => '操作失败';

  @override
  String get errBadName => '名称无效';

  @override
  String get errSizeMismatch => '大小校验失败，未发布';

  @override
  String get errTargetChanged => '目标在此期间被修改，已保持原样';

  @override
  String get errReplaceUnsupported => '服务器不支持安全替换，已保留原文件';

  @override
  String get errSourceMissing => '源文件不存在';

  @override
  String errTooMany(int count) {
    return '超过 $count 项';
  }

  @override
  String errTooDeep(int count) {
    return '嵌套超过 $count 层';
  }

  @override
  String get errStalled => '30 秒没有进展';

  @override
  String get errNotRegular => '不是普通文件';

  @override
  String get errTooLarge => '超过 64 MB，请改用下载';

  @override
  String get transferConcurrency => '同时传输数';

  @override
  String transfersRunning(int count) {
    return '$count 个传输进行中';
  }

  @override
  String editsUnsaved(int count) {
    return '$count 个编辑未上传';
  }

  @override
  String get quitNote => '进行中的传输会被取消；未上传的编辑会保留，下次仍可上传。';

  @override
  String get quit => '退出';

  @override
  String get proxyPassword => '代理密码';

  @override
  String get errProxyAuth => '代理认证失败，请检查用户名和密码。';

  @override
  String get errRouteLoop => '跳板链存在循环。';

  @override
  String get errRouteMissing => '跳板主机已不存在，请修改连接路由。';

  @override
  String get errRouteTooLong => '连接路由最多包含 8 台主机。';

  @override
  String get errRouteInvalid => '连接路由无效。';

  @override
  String get route => '连接路由';

  @override
  String get jumpHost => '跳板主机';

  @override
  String get directConnection => '直连';

  @override
  String get proxy => '代理';

  @override
  String get proxyAddress => '代理地址';

  @override
  String get proxyUser => '代理用户名（可选）';

  @override
  String get legacyAlgorithms => '旧版算法';

  @override
  String get legacyAlgorithmsHint => '仅当旧服务器需要时，为此主机允许 SHA-1 和 CBC。';

  @override
  String get errHostSave => '无法保存主机，请检查数据目录和安全存储的访问权限。';

  @override
  String get snippets => '片段';

  @override
  String get newSnippet => '新建片段';

  @override
  String get insertSnippet => '插入';

  @override
  String get runSnippet => '运行';

  @override
  String get snippetText => '命令内容';

  @override
  String get snippetUnavailable => '目标终端不可用，未发送任何内容。';

  @override
  String get snippetInvalid => '请填写名称和命令，命令不能超过 64 KiB。';

  @override
  String get snippetSaveFailed => '无法保存片段。';

  @override
  String get importKnownHosts => '导入 known_hosts';

  @override
  String get importAction => '导入';

  @override
  String get knownHostsNew => '新密钥';

  @override
  String get knownHostsTrusted => '已信任';

  @override
  String get knownHostsConflict => '与已保存的密钥不同，保持不变';

  @override
  String get knownHostsSkipped => '未导入';

  @override
  String get knownHostsSavedKey => '已保存';

  @override
  String get knownHostsFileKey => '文件中';

  @override
  String get knownHostsMalformed => '无法解析的行';

  @override
  String get knownHostsMarker => '不支持的标记';

  @override
  String get knownHostsWildcard => '不支持的通配模式';

  @override
  String get knownHostsNegation => '不支持否定模式';

  @override
  String get knownHostsKeyType => '不支持的密钥类型';

  @override
  String get knownHostsBadKey => '密钥数据无效或与类型不符';

  @override
  String get knownHostsHashed => '哈希主机名未匹配任何已保存主机';

  @override
  String get knownHostsFileConflict => '文件内的密钥互相冲突';

  @override
  String knownHostsTooLarge(int mb) {
    return '文件超过 $mb MB';
  }

  @override
  String get knownHostsUnreadable => '无法读取文件';

  @override
  String knownHostsImported(int count) {
    return '已导入 $count 个密钥';
  }

  @override
  String get knownHostsSaveFailed => '无法保存信任记录';

  @override
  String get tsPaused => '已暂停';

  @override
  String get tsPausing => '正在暂停';

  @override
  String get pause => '暂停';

  @override
  String get resume => '继续';

  @override
  String get pauseFolderUnsupported => '文件夹传输不能暂停';

  @override
  String get errSourceChanged => '源文件已变化，无法继续传输';

  @override
  String get errPartInvalid => '临时文件缺失或与源文件不再一致，无法继续';

  @override
  String leftoverPart(String path) {
    return '无法删除临时文件 $path';
  }

  @override
  String editCleanupFailed(String path) {
    return '无法删除本地副本 $path';
  }

  @override
  String get portForwarding => '端口转发';

  @override
  String get fwHost => '主机';

  @override
  String get fwLocal => '本地';

  @override
  String get fwRemote => '远程';

  @override
  String get fwDynamic => '动态（SOCKS5）';

  @override
  String get fwListen => '监听';

  @override
  String get fwDestination => '目标';

  @override
  String get fwExposed => '对外开放';

  @override
  String get fwAutoStart => '随应用启动';

  @override
  String get fwStart => '启动转发';

  @override
  String fwExposeConfirm(String endpoint) {
    return '监听 $endpoint 会让其他设备也能使用此转发，继续吗？';
  }

  @override
  String get fwExposeAllow => '允许';

  @override
  String get fwInvalid => '请检查地址和端口';

  @override
  String get fwSaveFailed => '保存失败';

  @override
  String get fwBusy => '请先停止转发';

  @override
  String get fwNoHosts => '请先添加主机';

  @override
  String get fwErrInUse => '端口已被占用';

  @override
  String get fwErrPermission => '没有权限使用此端口';

  @override
  String get fwErrAddress => '本机没有此地址';

  @override
  String get fwErrRefused => '服务器拒绝了此转发';

  @override
  String get fwErrHost => '主机已不存在';

  @override
  String get fwErrLost => '连接已断开';

  @override
  String get fwErrStop => '无法确认端口已释放，连接已保留';

  @override
  String get fwErrTarget => '无法连接目标';

  @override
  String get fwErrTimeout => '超时';

  @override
  String get fwErrSocks => 'SOCKS5 请求无效';

  @override
  String get fwErrLimit => '连接过多';

  @override
  String forwardsRunning(int count) {
    return '$count 条转发正在运行';
  }

  @override
  String get quitFailed =>
      '部分更改未能保存，或任务未能停止。可以重试或返回应用。仍然退出可能丢失未保存的更改，本地编辑副本会保留。';

  @override
  String get returnToApp => '返回应用';

  @override
  String get quitAnyway => '仍然退出';

  @override
  String configUnavailable(String name) {
    return '无法安全读取 $name';
  }

  @override
  String get configPreserved => '原文件已保留。请在数据目录中检查或恢复文件后重试。';

  @override
  String get openDataFolder => '打开数据目录';

  @override
  String get windowMinimize => '最小化';

  @override
  String get windowMaximize => '最大化';

  @override
  String get windowRestore => '还原';

  @override
  String get windowClose => '关闭窗口';

  @override
  String get sshConfigImport => '导入 SSH config';

  @override
  String get sshConfigPick => '选择配置';

  @override
  String get sshConfigExisting => '已保存';

  @override
  String get sshConfigBlocked => '无法导入';

  @override
  String sshConfigImported(int count) {
    return '已导入 $count 台主机';
  }

  @override
  String get sshConfigChanged => '主机库已变化，请重新选择配置';

  @override
  String get sshConfigFailed => '无法导入配置';

  @override
  String get sshConfigMalformed => '语法无效';

  @override
  String get sshConfigUnsupported => '不支持的选项';

  @override
  String get sshConfigMatch => '已跳过 Match 区块';

  @override
  String get sshConfigPattern => '主机模式仅用于默认值';

  @override
  String get sshConfigIncludeOutside => 'Include 超出所选目录';

  @override
  String get sshConfigIncludeLimit => 'Include 文件数、深度或大小超限';

  @override
  String get sshConfigIncludeMissing => '无法读取 Include 文件';

  @override
  String get sshConfigIncludeCycle => 'Include 循环';

  @override
  String get sshConfigIncomplete => '配置未完整读取';

  @override
  String get sshConfigProxyCommand => 'ProxyCommand 需要手动配置';

  @override
  String get sshConfigInvalid => '主机设置无效';

  @override
  String get sshConfigJump => '无法解析跳板主机';

  @override
  String get sshConfigJumpCycle => '跳板链循环或过长';

  @override
  String get sshConfigAmbiguous => '匹配到多个已保存主机';

  @override
  String get sshConfigIdentity => '无法解析私钥路径';

  @override
  String get sshConfigExtraIdentity => '仅支持第一个 IdentityFile';

  @override
  String get sshConfigHostLimit => '配置中的主机过多';

  @override
  String get retryAction => '重试';

  @override
  String get resizeToolPanel => '调整工具面板宽度';

  @override
  String get resizeNavigation => '调整导航宽度';

  @override
  String get configRestoreSnapshots => '恢复快照';

  @override
  String get configNoSnapshots => '没有有效快照';

  @override
  String get configRestore => '恢复';

  @override
  String get configRestoreFailed => '无法恢复快照，当前文件已保留。';

  @override
  String configSnapshotRevision(int revision) {
    return '修订 $revision';
  }

  @override
  String inheritedFrom(String source) {
    return '继承自 $source';
  }

  @override
  String useInherited(String source) {
    return '改用 $source 的值';
  }

  @override
  String get inheritBuiltIn => '默认';

  @override
  String get globalDefaults => '全局默认值';

  @override
  String get identities => '身份';

  @override
  String get identity => '身份';

  @override
  String get customLogin => '自定义';

  @override
  String get newIdentity => '新建身份';

  @override
  String get keyThenPassword => '密钥，再密码';

  @override
  String get allowInteractive => '键盘交互验证';

  @override
  String get newGroup => '新建分组';

  @override
  String get editGroup => '编辑分组';

  @override
  String dissolveGroupConfirm(String name) {
    return '解散 $name？其中的主机会移到上一级，该分组的默认设置将被丢弃。';
  }

  @override
  String get errGroupInvalid => '分组路径已被占用或无效。';

  @override
  String deleteIdentity(String name) {
    return '删除身份 $name？';
  }

  @override
  String get errSave => '无法保存，请检查数据目录和安全存储的访问权限。';

  @override
  String get monitor => '服务器监控';

  @override
  String get cpu => 'CPU';

  @override
  String get gpu => 'GPU';

  @override
  String get memory => '内存';

  @override
  String get swap => '交换';

  @override
  String get network => '网络';

  @override
  String get disks => '磁盘';

  @override
  String get load => '负载';

  @override
  String get uptime => '运行';

  @override
  String cores(int count) {
    return '$count 核';
  }

  @override
  String uptimeDays(int days, int hours) {
    return '$days 天 $hours 小时';
  }

  @override
  String uptimeHours(int hours, int minutes) {
    return '$hours 小时 $minutes 分';
  }

  @override
  String get monitorUnsupported => '这台服务器没有 /proc，无法显示监控';

  @override
  String get monitorFailed => '读取失败，正在重试';

  @override
  String get monitorOffline => '连接后显示';

  @override
  String get uiFont => '界面字体';

  @override
  String get uiFontSize => '界面字号';

  @override
  String get terminalFont => '终端字体';

  @override
  String get defaultFont => '默认';

  @override
  String get searchFonts => '搜索字体';

  @override
  String get workspaceSection => '工作区';

  @override
  String get filesDock => '文件面板位置';

  @override
  String get dockLeft => '左侧';

  @override
  String get dockRight => '右侧';

  @override
  String get dockBottom => '下方';

  @override
  String get dockPosition => '停靠位置';

  @override
  String get confirmQuit => '退出前确认';

  @override
  String get quitTitle => '退出 sshairy？';

  @override
  String sessionsOpen(int count) {
    return '$count 个会话将断开';
  }

  @override
  String get monitorInterval => '刷新间隔';

  @override
  String get copyAddress => '复制地址';

  @override
  String get monitorSystem => '系统';

  @override
  String get processes => '进程';

  @override
  String get showAllProcesses => '查看全部进程';

  @override
  String get allInterfaces => '全部网卡';

  @override
  String get diskFree => '可用 / 大小';

  @override
  String get processUser => '用户';

  @override
  String get processResident => '常驻';

  @override
  String get processState => '状态';

  @override
  String get processThreads => '线程';

  @override
  String get processElapsed => '运行时长';

  @override
  String get processCommand => '命令';

  @override
  String get searchProcesses => '搜索进程';

  @override
  String get copyPid => '复制 PID';

  @override
  String get copyCommand => '复制命令';

  @override
  String get terminateProcess => '结束进程';

  @override
  String get killProcess => '强制结束';

  @override
  String terminateConfirm(String name, int pid) {
    return '结束 $name（PID $pid）？';
  }

  @override
  String killConfirm(String name, int pid) {
    return '强制结束 $name（PID $pid）？进程没有机会保存数据。';
  }

  @override
  String signalFailed(String detail) {
    return '未能结束进程：$detail';
  }

  @override
  String tasks(int count) {
    return '$count 个任务';
  }

  @override
  String get gpuTemperature => '温度';

  @override
  String get gpuPower => '功耗 / 上限';

  @override
  String get gpuFan => '风扇';

  @override
  String get gpuCoreClock => '核心频率';

  @override
  String get gpuMemoryClock => '显存频率';

  @override
  String get gpuMemory => '显存';
}
