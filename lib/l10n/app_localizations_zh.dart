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
  String get accent => '主题色';

  @override
  String get accentBlue => '蓝';

  @override
  String get accentGreen => '绿';

  @override
  String get accentViolet => '紫';

  @override
  String get accentOrange => '橙';

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
  String get renameGroup => '重命名分组';

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
}
