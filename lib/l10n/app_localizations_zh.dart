// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get aiConfigTitle => 'AI';

  @override
  String get aiAgentAttach => '添加文件';

  @override
  String get aiAgentAttachmentTooLarge => '文件过大，请选择较小的文件。';

  @override
  String aiAgentAttachmentTooMany(int count) {
    return '一条消息最多添加 $count 个附件。';
  }

  @override
  String aiAgentAttachmentTotalTooLarge(int size) {
    return '本条消息的附件超过 $size MiB，请移除部分文件后重试。';
  }

  @override
  String get aiAgentAttachmentImageTooLarge => '图片像素过高，请缩小图片后重试。';

  @override
  String aiAgentAttachmentFileError(String name, String reason) {
    return '$name：$reason';
  }

  @override
  String get aiAgentAttachmentUnsupported =>
      '请选择 UTF-8 文本或 PNG、JPEG、WebP 图片；不支持二进制文件、凭据和其他格式。';

  @override
  String get aiAgentAttachmentUnreadable => '无法读取所选文件。';

  @override
  String get aiConfigEnabled => '启用 AI';

  @override
  String get aiConfigAnthropic => 'Anthropic Messages';

  @override
  String get aiConfigOpenAi => 'OpenAI Chat Completions';

  @override
  String get aiConfigResponses => 'OpenAI Responses';

  @override
  String get aiConfigEndpoint => 'API 基础地址';

  @override
  String get aiConfigEndpointHint =>
      '不含 /v1 等版本路径时自动补 /v1；仅允许 HTTPS 或精确本机回环 HTTP。';

  @override
  String get aiConfigModel => '模型';

  @override
  String get aiConfigTools => '模型支持工具调用';

  @override
  String get aiConfigContextWindow => '上下文容量（tokens）';

  @override
  String get aiConfigMaxOutput => '最大输出（tokens）';

  @override
  String get aiConfigApiKey => 'API Key';

  @override
  String get aiConfigKeyLoading => '正在检查安全存储…';

  @override
  String get aiConfigKeyLoadFailed => '无法检查系统安全存储中的 API Key。';

  @override
  String get aiConfigKeySaved => '此目的地已保存密钥；留空保留原值。';

  @override
  String get aiConfigKeyMissing => '未保存密钥；不需要认证时可留空。';

  @override
  String get aiConfigKeyRemoved => '保存后将移除此密钥。';

  @override
  String get aiConfigRemoveKey => '移除已存密钥';

  @override
  String get aiConfigInvalid => '请检查 API 地址、模型和 token 上限。';

  @override
  String get aiConfigSaveFailed => 'AI 设置未能保存；密钥修改可能已写入系统安全存储，请检查后重试。';

  @override
  String get aiConfigPartialSave => 'API Key 已更新，但 AI 设置未能保存，请重试保存设置。';

  @override
  String get aiConfigLoadFailed => '无法读取 AI 配置；AI 已禁用，原文件受到保护。';

  @override
  String get aiConfigConflict => 'AI 设置已在其他位置更改，请取消以重新载入后再保存。';

  @override
  String deleteHostsConfirm(int count) {
    return '删除选中的 $count 台主机？';
  }

  @override
  String get hostDeleteCleanupFailed => '主机已删除，但部分已保存凭据未能清理，请检查系统安全存储。';

  @override
  String get closeTabsLeft => '关闭左侧标签';

  @override
  String get closeTabsRight => '关闭右侧标签';

  @override
  String get closeOtherTabs => '关闭其他标签';

  @override
  String get noHosts => '暂无主机';

  @override
  String get noHostsInGroup => '此分组暂无主机';

  @override
  String get hostEmptyHint => '新建主机或导入已有连接，开始使用。';

  @override
  String get moveToGroup => '移动到分组…';

  @override
  String moveHostsTitle(int count) {
    return '移动 $count 台主机到分组';
  }

  @override
  String get completionLoading => '加载中…';

  @override
  String get completionUnavailable => '无法获取此路径';

  @override
  String get completionFailed => '无法读取此目录';

  @override
  String get completionEmpty => '没有匹配项';

  @override
  String get completionTruncated => '继续输入以缩小范围';

  @override
  String get completionCommand => '命令';

  @override
  String get completionSubcommand => '子命令';

  @override
  String get completionOption => '命令选项';

  @override
  String get completionArgument => '参数值';

  @override
  String get openWith => '打开方式…';

  @override
  String get systemDefaultApp => '系统默认';

  @override
  String get defaultApp => '默认';

  @override
  String get chooseProgram => '选择其他应用…';

  @override
  String alwaysOpenWith(String type) {
    return '始终用于 $type';
  }

  @override
  String get errLaunchFailed => '无法打开本地副本。';

  @override
  String get uiScale => '界面缩放';

  @override
  String get motion => '动效';

  @override
  String get motionLight => '轻动效';

  @override
  String get motionFull => '全部动效';

  @override
  String get importChooseAgain => '重新选择来源';

  @override
  String get importChooseFolder => '选择文件夹';

  @override
  String get importChooseFile => '选择文件';

  @override
  String get importLoginOption => '迁移已保存的登录信息';

  @override
  String get importLoginStorage => '仅在本机处理密码，保存到系统安全存储；已有密码不覆盖。';

  @override
  String get importPasswordFound => '已找到可迁移的密码';

  @override
  String get importLoginNeeded => '连接时补充登录信息';

  @override
  String get importCleanupFailed => '导入失败，部分新凭据未能回收。请检查系统安全存储后重试。';

  @override
  String get importSourceChanged => '来源文件已改变或无法读取，请重新选择。';

  @override
  String get importGuideOpenSsh =>
      '选择 .ssh 文件夹内的 config 文件；Include 仅在同一配置目录内读取。';

  @override
  String get importGuidePutty =>
      'Windows 会自动读取 PuTTY 会话注册表。手动导入请选择注册表编辑器导出的 Sessions .reg 文件。';

  @override
  String get importGuideMoba =>
      '选择 MobaXterm.ini，或从连接列表导出的 .mxtsessions 文件。便携版配置通常在程序旁。';

  @override
  String get importGuideSecureCrt =>
      '在 SecureCRT 的全局选项中查看配置文件夹，选择其中的 Sessions 文件夹（内含 .ini 会话）。';

  @override
  String get importGuideXshell =>
      '选择文档目录 NetSarang Computer 对应版本下的 Xshell/Sessions 文件夹（内含 .xsh 会话）。';

  @override
  String get importGuideFinalShell =>
      '选择 FinalShell 程序目录中的 conn 文件夹，或包含 *_connect_config.json 的导出文件夹；压缩包请先解压。便携版和自定义安装位置可手动选择。';

  @override
  String get importGuideTabby => '选择 Tabby 的 config.yaml 配置文件。';

  @override
  String get importGuideCsv =>
      '选择 UTF-8 CSV 文件。第一行应包含 host（或“地址”）表头，可另有 name、port、username、group、key。';

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
  String get showPassword => '显示密码';

  @override
  String get hidePassword => '隐藏密码';

  @override
  String get hostPasswordLoading => '正在读取已存密码…';

  @override
  String get hostPasswordLoadFailed => '无法读取已存密码，请解锁系统安全存储后重试。';

  @override
  String get hostPasswordRetry => '重试读取密码';

  @override
  String get hostPasswordRemove => '移除已存密码';

  @override
  String get hostPasswordKeep => '保留已存密码';

  @override
  String get hostPasswordRemovalPending => '保存后将移除已存密码。';

  @override
  String get hostPasswordSaveFailed => '主机配置已保存，但密码修改未能确认。请检查系统安全存储后再次保存。';

  @override
  String get hostPasswordCleanupFailed =>
      '主机配置已保存，但旧代理凭据未能移除，密码修改尚未保存。请检查系统安全存储后再次保存。';

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
  String get renderer => '渲染模式';

  @override
  String get rendererPerformance => '高性能';

  @override
  String get rendererLight => '轻量';

  @override
  String get rendererPerformanceHint => 'Impeller 引擎：动画更稳，内存约多 150 MB';

  @override
  String get rendererLightHint => 'Skia 引擎：内存更低，动画首次出现时可能卡顿';

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
  String get completionTranslation => '自动翻译补全说明';

  @override
  String get completionTranslationHint => '仅向所选服务发送公开命令说明，关闭后仍可使用缓存译文。';

  @override
  String get translationService => '翻译服务';

  @override
  String get translationConcurrency => '翻译并发数';

  @override
  String get translationConcurrencyAuto => '自动（所有可见项）';

  @override
  String get translationProvider => '服务商';

  @override
  String get translationMyMemory => 'MyMemory';

  @override
  String get translationDeepL => 'DeepL';

  @override
  String get translationGoogle => 'Google Cloud Translation';

  @override
  String get translationMicrosoft => 'Microsoft Translator';

  @override
  String get translationOpenAi => 'OpenAI 兼容服务';

  @override
  String get translationMyMemoryHint => '无需密钥 · 每天 5000 字符，提供有效邮箱可用 50000 字符';

  @override
  String get translationEmail => '邮箱（可选）';

  @override
  String get translationEmailHint => '仅发送给 MyMemory，供其在需要时联系你。';

  @override
  String get translationEmailInvalid => '请输入有效邮箱，最多 254 个 ASCII 字符。';

  @override
  String get translationDeepLFree => '使用 DeepL API Free';

  @override
  String get translationRegion => '区域（可选）';

  @override
  String get translationEndpoint => 'API 基础地址';

  @override
  String get translationEndpointHint =>
      '例如 https://api.example.com/v1，不含 /chat/completions';

  @override
  String get translationModel => '模型';

  @override
  String get translationApiKey => 'API 密钥';

  @override
  String get translationKeySaved => '密钥已保存，留空保留';

  @override
  String get translationKeyMissing => '尚未保存密钥';

  @override
  String get translationKeyRemoved => '保存时移除密钥';

  @override
  String get translationRemoveKey => '移除已存密钥';

  @override
  String get translationKeyLoading => '正在检查安全存储…';

  @override
  String get translationKeyLoadFailed => '无法检查安全存储，请取消编辑后重试。';

  @override
  String get translationEndpointInvalid => '请使用 HTTPS 或本机 HTTP，不含凭据、查询参数或片段。';

  @override
  String get translationModelInvalid => '请输入最多 128 位字母、数字或 . _ : / - 组成的模型名。';

  @override
  String get translationRegionInvalid => '请使用最多 64 位小写字母、数字或连字符。';

  @override
  String get translationConflict => '设置已变化，请取消当前编辑后重试。';

  @override
  String get translationSaveFailed => '未能完成保存，密钥变更可能已写入安全存储。';

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
  String get hostKeys => '主机密钥';

  @override
  String get trustedKeys => '已信任的主机密钥';

  @override
  String get none => '无';

  @override
  String get remove => '移除';

  @override
  String get version => '版本';

  @override
  String get checkForUpdates => '检查更新';

  @override
  String get checkingForUpdates => '正在检查更新…';

  @override
  String get upToDate => '已是最新版本';

  @override
  String get updateFailed => '无法检查更新';

  @override
  String updateAvailable(String version) {
    return '发现新版本 $version';
  }

  @override
  String get releaseNotes => '更新日志';

  @override
  String get openReleasePage => '打开发布页';

  @override
  String get updateDownload => '下载更新';

  @override
  String get updateDownloading => '正在下载更新…';

  @override
  String get updateVerifying => '正在校验下载…';

  @override
  String updateDownloaded(String path) {
    return '已下载到 $path';
  }

  @override
  String get updateInstallPrompt => '现在安装吗？安装前会退出当前软件。';

  @override
  String get updateDownloadFailed => '下载失败，请检查网络后重试。';

  @override
  String get updateNoPackage => '当前平台没有可自动安装的包，请打开发布页下载。';

  @override
  String get installNow => '立即安装';

  @override
  String get later => '稍后';

  @override
  String get cancelDownload => '取消下载';

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
  String get shellIntegrationInstall => '安装 Shell 集成';

  @override
  String get shellIntegrationRemove => '移除 Shell 集成';

  @override
  String get shellIntegrationInstalled => '已安装，新开的终端生效';

  @override
  String get shellIntegrationRemoved => '已移除，新开的终端不再加载';

  @override
  String get shellIntegrationFailed => 'Shell 集成修改失败';

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
  String get hiddenFiles => '显示隐藏文件';

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
  String get sshConfigExisting => '已保存';

  @override
  String get sshConfigBlocked => '无法导入';

  @override
  String sshConfigImported(int count) {
    return '已导入 $count 台主机';
  }

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
  String get resizeMonitor => '调整监控宽度';

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
  String get shortcuts => '快捷键';

  @override
  String get shortcutPress => '按下快捷键…';

  @override
  String get shortcutUnset => '未设置';

  @override
  String get shortcutReset => '恢复默认';

  @override
  String shortcutConflict(Object action) {
    return '已被“$action”使用';
  }

  @override
  String get shortcutCommandPalette => '命令面板';

  @override
  String get shortcutNewConnection => '新建连接';

  @override
  String get shortcutCloseTab => '关闭标签';

  @override
  String get shortcutSettings => '打开设置';

  @override
  String get shortcutToggleAgent => '开合 Agent 侧栏';

  @override
  String get shortcutInlineGenerate => '行内生成命令';

  @override
  String get shortcutTerminalCopy => '终端复制';

  @override
  String get shortcutTerminalPaste => '终端粘贴';

  @override
  String get shortcutTerminalSearch => '终端搜索';

  @override
  String get shortcutCommandHistory => '命令历史';

  @override
  String get shortcutPreviousPane => '上一个面板';

  @override
  String get shortcutNextPane => '下一个面板';

  @override
  String get shortcutPreviousTab => '上一个标签';

  @override
  String get shortcutNextTab => '下一个标签';

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
  String get quitTitle => '退出 Sshairy？';

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

  @override
  String get importHosts => '导入主机';

  @override
  String get importFromFile => '从文件导入';

  @override
  String get importNoGroup => '不放入分组';

  @override
  String get importChanged => '主机库已变化，请重新选择来源';

  @override
  String get importFailed => '无法读取主机';

  @override
  String get importNotSsh => '不是 SSH 会话';

  @override
  String get importNoAddress => '缺少地址';

  @override
  String get importUnreadable => '无法读取此文件';

  @override
  String get importPpk => '未使用 PuTTY .ppk 密钥，请先转换为 OpenSSH 格式';

  @override
  String get proxies => '代理';

  @override
  String get proxySearch => '搜索主机、分组或代理';

  @override
  String get proxyInherit => '继承';

  @override
  String get proxyConfiguredHere => '在此配置';

  @override
  String get proxyVia => '经跳板主机';

  @override
  String get proxyEditHop => '编辑跳板主机的代理';

  @override
  String get proxyNextConnection => '修改在下次连接时生效。';

  @override
  String get proxyInvalid => '请检查代理地址、端口和用户名。';

  @override
  String get proxyChanged => '配置已变化，请重新打开编辑器后再试。';

  @override
  String get proxyCleanupFailed => '代理配置已保存，但旧凭据未能完全清理。';

  @override
  String get logs => '日志';

  @override
  String get logArea => '区域';

  @override
  String get logOutcome => '结果';

  @override
  String get logAllAreas => '全部区域';

  @override
  String get logAllOutcomes => '全部结果';

  @override
  String get logCopyRecord => '复制选中记录';

  @override
  String get logEmpty => '暂无记录';

  @override
  String get logDisabled => '诊断记录已关闭。';

  @override
  String get logWriterFailed => '诊断记录因写入失败而停止。';

  @override
  String get logReadFailed => '无法读取诊断记录，可刷新重试。';

  @override
  String logSkipped(int count) {
    return '已跳过 $count 条无效记录。';
  }

  @override
  String logDropped(int count) {
    return '已丢弃 $count 条排队记录。';
  }

  @override
  String logElapsed(int milliseconds) {
    return '$milliseconds 毫秒';
  }

  @override
  String get logAreaApplication => '应用';

  @override
  String get logAreaConnection => '连接';

  @override
  String get logAreaTransfer => '传输';

  @override
  String get logAreaConfiguration => '配置';

  @override
  String get logOutcomeStarted => '开始';

  @override
  String get logOutcomeSucceeded => '成功';

  @override
  String get logOutcomeFailed => '失败';

  @override
  String get logOutcomeCancelled => '已取消';

  @override
  String get logOutcomeInterrupted => '已中断';

  @override
  String get logActionStart => '启动';

  @override
  String get logActionDial => '连接';

  @override
  String get logActionCopy => '传输';

  @override
  String get logActionPause => '暂停';

  @override
  String get logActionCancel => '取消';

  @override
  String get logActionRead => '读取';

  @override
  String get logActionWrite => '写入';

  @override
  String get logActionRecover => '恢复';

  @override
  String get logActionUncaught => '未处理错误';

  @override
  String get logActionShutdown => '退出';

  @override
  String get appBackgroundImage => '界面背景';

  @override
  String get terminalBackgroundImage => '终端背景';

  @override
  String get backgroundChooseImage => '选择图片';

  @override
  String get backgroundRestoreDefault => '恢复默认背景';

  @override
  String get backgroundOpacity => '图片不透明度';

  @override
  String get backgroundImageTooLarge => '图片超过大小限制。';

  @override
  String get backgroundImageUnsupported => '请选择静态 PNG 或 JPEG 图片。';

  @override
  String get backgroundImageUnreadable => '无法读取图片。';

  @override
  String get backgroundGalleryFull => '已保存的背景图片已满，请先移除一张。';

  @override
  String backgroundImageItem(int number) {
    return '图片 $number';
  }

  @override
  String get commandHistory => '命令历史';

  @override
  String get commandHistoryEmpty => '暂无命令';

  @override
  String get commandHistoryInsert => '插入命令';

  @override
  String get commandHistoryClear => '清空历史';

  @override
  String get terminalMultilineInput => '多行输入';

  @override
  String get terminalMultilineSend => '发送到终端';

  @override
  String get terminalMultilinePlaceholder => '输入命令…';

  @override
  String get localShellsEmpty => '未发现本地终端';

  @override
  String get aiAgentTitle => 'Airy';

  @override
  String get aiAgentRail => 'Airy Agent';

  @override
  String get aiAgentClear => '清空对话';

  @override
  String get aiAgentConfigure => '在设置中配置模型并开启 AI 后即可开始。';

  @override
  String get aiAgentConfigurationFailed => 'AI 配置读取失败，请在设置中检查。';

  @override
  String get aiAgentChooseHost => '选择服务器';

  @override
  String get aiAgentGoal => '描述你想检查或处理的问题…';

  @override
  String get aiAgentSend => '发送';

  @override
  String get aiAgentEmpty => '仅向所选模型发送你输入的文字和明确授权的数据。';

  @override
  String get aiAgentIdle => '就绪';

  @override
  String get aiAgentPreparing => '准备中';

  @override
  String get aiAgentStreaming => '接收回复中';

  @override
  String get aiAgentAwaitingApproval => '等待命令批准';

  @override
  String get aiAgentExecuting => '执行中';

  @override
  String get aiAgentCompleted => '已完成';

  @override
  String get aiAgentStopping => '正在停止';

  @override
  String get aiAgentCancelled => '已停止';

  @override
  String get aiAgentFailed => '请求未能完成。';

  @override
  String get aiAgentOutcomeUnknown => '远端结果未知';

  @override
  String get aiAgentDiagnostics => '固定诊断';

  @override
  String get aiAgentToolHosts => '查看主机列表';

  @override
  String get aiAgentToolHostsHint => '查看已保存主机的名称和标识。';

  @override
  String get aiAgentToolTerminals => '查看终端窗口';

  @override
  String get aiAgentToolTerminalsHint => '列出已连接的标签和分屏，不读取命令或输出。';

  @override
  String get aiAgentToolTerminalHistory => '读取窗口上下文';

  @override
  String get aiAgentToolTerminalHistoryHint => '读取指定终端已知目录、近期命令及对应结果。';

  @override
  String get aiAgentTerminalApproveHint =>
      '允许 Airy 在本轮使用这个终端的已知目录、提示符状态和近期命令结果。窗口编号为发送时的标签位置与分屏位置；不会执行命令。';

  @override
  String get aiAgentToolTerminalScreen => '读取终端屏幕';

  @override
  String get aiAgentToolTerminalScreenHint => '读取指定终端当前可见的文字，最多 200 行，不读取回滚内容。';

  @override
  String get aiAgentTerminalScreenApproveHint =>
      '允许 Airy 只读取这个终端当前可见的文字，最多 200 行。每次读取都会询问；不会执行命令。';

  @override
  String get aiAgentToolFilesList => '列出目录';

  @override
  String get aiAgentToolFilesStat => '查看文件信息';

  @override
  String get aiAgentToolFilesRead => '读取文件';

  @override
  String get aiAgentToolFilesWrite => '写入文件';

  @override
  String get aiAgentToolFilesMkdir => '新建目录';

  @override
  String get aiAgentToolFilesRename => '重命名路径';

  @override
  String get aiAgentToolFilesDelete => '删除路径';

  @override
  String get aiAgentToolFilesHint => '读取或修改远端文件与目录。';

  @override
  String get aiAgentToolTransferList => '查看传输';

  @override
  String get aiAgentToolTransferEnqueue => '开始传输';

  @override
  String get aiAgentToolTransferCancel => '取消传输';

  @override
  String get aiAgentToolTransferHint => '查看或操作文件传输。';

  @override
  String get aiAgentToolSessionOpen => '打开会话';

  @override
  String get aiAgentToolSessionClose => '关闭会话';

  @override
  String get aiAgentToolSessionReconnect => '重连会话';

  @override
  String get aiAgentToolSessionHint => '打开、关闭或重连终端会话。';

  @override
  String get aiAgentToolWorkspaceFocus => '切换窗口';

  @override
  String get aiAgentToolWorkspaceSplit => '分屏';

  @override
  String get aiAgentToolWorkspaceRename => '重命名标签';

  @override
  String get aiAgentToolWorkspaceCloseTabs => '批量关闭标签';

  @override
  String get aiAgentToolWorkspaceHint => '切换或调整窗口布局。';

  @override
  String get aiAgentToolSettingsGet => '查看设置';

  @override
  String get aiAgentToolSettingsPatch => '修改设置';

  @override
  String get aiAgentToolSettingsHint => '读取或修改本机设置。';

  @override
  String get aiAgentToolHostCreate => '新增主机';

  @override
  String get aiAgentToolHostUpdate => '修改主机';

  @override
  String get aiAgentToolHostMove => '移动主机';

  @override
  String get aiAgentToolHostDelete => '删除主机';

  @override
  String get aiAgentToolHostHint => '新增、修改或删除已保存主机。';

  @override
  String get aiAgentToolForwardList => '查看转发';

  @override
  String get aiAgentToolForwardSave => '保存转发规则';

  @override
  String get aiAgentToolForwardDelete => '删除转发规则';

  @override
  String get aiAgentToolForwardStart => '启动转发';

  @override
  String get aiAgentToolForwardStop => '停止转发';

  @override
  String get aiAgentToolForwardHint => '查看或操作端口转发规则。';

  @override
  String get aiAgentToolJobStart => '运行后台任务';

  @override
  String get aiAgentToolJobRead => '读取任务输出';

  @override
  String get aiAgentToolJobStatus => '查看任务状态';

  @override
  String get aiAgentToolJobStop => '停止任务';

  @override
  String get aiAgentToolJobHint => '运行或查看后台任务。';

  @override
  String get aiAgentToolDiagnostics => '收集诊断';

  @override
  String get aiAgentToolDiagnosticsHint => '收集固定的系统或磁盘诊断信息。';

  @override
  String get aiAgentToolExecute => '执行命令';

  @override
  String get aiAgentToolExecuteHint => '通过独立 SSH 通道执行已获授权的命令。';

  @override
  String get aiAgentToolOutput => '读取输出';

  @override
  String get aiAgentToolOutputHint => '读取已获准共享的命令输出。';

  @override
  String get aiAgentDiagnosticScope =>
      '固定 Linux 诊断可向所选模型发送系统、内核、负载、内存、磁盘挂载点及容量，不含进程参数和环境变量。';

  @override
  String aiAgentExitCode(int code) {
    return '退出码：$code';
  }

  @override
  String aiAgentExecutionTimeout(int seconds) {
    return '执行超时：$seconds 秒';
  }

  @override
  String get aiAgentTruncated => '输出已截断。';

  @override
  String get aiAgentShowOutput => '查看本地输出';

  @override
  String get aiAgentHideOutput => '收起输出';

  @override
  String get aiAgentShellPermission =>
      '命令以 SSH 账号权限执行，可能修改文件或访问网络。批准也允许 Airy 使用该操作的有界输出。停止会关闭本客户端的通道，远端进程仍可能继续。';

  @override
  String get aiAgentReject => '拒绝';

  @override
  String get aiAgentApprove => '仅批准此次';

  @override
  String get aiAgentNewTask => '新会话';

  @override
  String get aiAgentWelcome => '有什么想一起解决的？';

  @override
  String get aiAgentWelcomeHint => '默认查看当前终端上下文；读取其他窗口时会请求批准。';

  @override
  String get aiAgentSetupTitle => '你的 SSH 助手';

  @override
  String get aiAgentConfigureAction => '配置 AI';

  @override
  String get aiAgentExampleExplain => '解释一条命令';

  @override
  String get aiAgentExampleExplainGoal => '教我读懂一条 shell 命令，并判断它可能产生的影响。';

  @override
  String get aiAgentExampleDiagnose => '看看服务器状态';

  @override
  String get aiAgentExampleDiagnoseGoal => '检查这台服务器的负载、内存和磁盘空间。在建议修改前说明还缺哪些依据。';

  @override
  String get aiAgentNoHost => '不使用主机';

  @override
  String get aiAgentScopeDetails => '数据与命令权限';

  @override
  String get aiAgentScopeSummary => '允许固定诊断 · 命令逐次确认';

  @override
  String get aiAgentTextOnly => '仅文本';

  @override
  String get aiAgentSendShortcut => '发送 · Enter';

  @override
  String get aiAgentApproveTitle => '确认执行命令';

  @override
  String get aiAgentExecutionFailed => '执行返回错误';

  @override
  String get aiAgentErrorConfiguration => '请在设置中检查模型配置与 API Key。';

  @override
  String get aiAgentErrorModelConfig => '请在设置中检查模型地址与模型名称。';

  @override
  String get aiAgentErrorToolDefinition => '工具定义无效，暂时无法使用。本轮已停止，请检查应用实现。';

  @override
  String get aiAgentErrorNetwork => '无法连接模型，请检查网络后重新发起任务。';

  @override
  String get aiAgentErrorHttp => '模型服务拒绝了请求，请检查凭据、额度和接口设置。';

  @override
  String get aiAgentErrorTimeout => '请求已到期限，请核对任务后再试。';

  @override
  String get aiAgentErrorLimit => '任务已达到上下文、输出或步骤上限，请缩小范围后重试。';

  @override
  String get aiAgentErrorScope => '模型配置或主机连接已变化，请新建任务以授权当前目标。';

  @override
  String get aiAgentErrorJournal => '操作记录未能保存，请先核对执行状态再发起其他命令。';

  @override
  String get aiAgentErrorProtocol => '模型响应不完整或不受支持，未执行不完整的工具请求。';

  @override
  String get aiAgentErrorUnsupported => '当前命令适配器不支持这台主机。';

  @override
  String get aiAgentErrorFileDenied => '文件工具拒绝了该路径或内容（敏感位置、凭据样式文本或策略限制）。';

  @override
  String get aiAgentErrorFileSensitive =>
      '文件包含疑似凭据或密钥内容，已拒绝读取；请让用户直接检查，或缩小到不含该内容的范围。';

  @override
  String get aiAgentErrorFileUnsupported =>
      '该文件操作不受支持：二进制或非 UTF-8、超过 256 KiB，或服务器不支持私有临时文件与原子替换。';

  @override
  String get aiAgentErrorFileConflict => '文件在读取后已变化；请重新读取后再写入。';

  @override
  String get aiAgentErrorFileExists => '目标已存在；请先读取，并在覆盖时提供最新的 sha256。';

  @override
  String get aiAgentErrorFileNotFound => '文件或目录不存在。';

  @override
  String get aiAgentErrorFilePermission => 'SSH 账号没有执行该文件操作的权限。';

  @override
  String get aiAgentErrorFileInvalid => '文件工具参数无效；请检查 hostId、绝对路径和分页参数。';

  @override
  String get aiAgentErrorFileScope => '该主机不在本次任务的授权范围内，请先确认主机后再试。';

  @override
  String get aiReasoningEffort => '思考强度';

  @override
  String get aiReasoningDefault => '跟随模型';

  @override
  String get aiReasoningOff => '关闭';

  @override
  String get aiReasoningLow => '低';

  @override
  String get aiReasoningMedium => '中';

  @override
  String get aiReasoningHigh => '高';

  @override
  String get aiReasoningActive => '思考中…';

  @override
  String get aiReasoningSummary => '思考摘要';

  @override
  String get aiReasoningCompleted => '思考已完成';

  @override
  String get aiReasoningUnsupported => '当前模型暂不支持调节思考强度，请选择跟随模型或切换模型。';

  @override
  String get aiConfigAdvanced => '模型能力与额度';

  @override
  String get aiConfigInline => '行内命令生成';

  @override
  String get aiConfigInlineHint =>
      '点击终端 AI 按钮或按 Ctrl/Cmd+Shift+G，使用需求、已知环境、近期命令及其有界结果生成；检查后再填入。';

  @override
  String get aiConfigCompletion => 'AI 提示补全';

  @override
  String get aiConfigTerminalScope => '允许这些 SSH 主机向模型发送当前输入与已知目录';

  @override
  String get aiConfigTerminalNoHosts => '添加主机后可授权 SSH 提示。本地终端可使用手动触发的行内生成。';

  @override
  String get aiConfigPosix => '已选 SSH 终端使用 Linux / POSIX shell';

  @override
  String get aiConfigPosixHint =>
      '请自行确认输入环境；进入 su、tmux 或嵌套 SSH 时关闭提示，客户端无法确认内层身份。';

  @override
  String get aiConfigCompletionHistory => '使用当前会话近期命令';

  @override
  String get aiConfigCompletionHint =>
      '输入 git st 等明确命令后停顿 800 毫秒触发，使用本会话最多 8 条相关命令及其有界结果。';

  @override
  String get aiAgentErrorHostTrust => '请先正常连接这台主机并核对主机密钥，再使用远程工具。';

  @override
  String get aiAgentErrorAuthentication => '请先正常连接这台主机，提供或更新认证凭据。';

  @override
  String get aiAgentErrorHostUnavailable => '这台主机已不可用，请为新任务重新选择已保存的主机。';

  @override
  String get aiAgentErrorConnection => 'SSH 连接失败，请先通过正常连接检查主机后重试。';

  @override
  String get aiAgentErrorExecution => '命令未能完成，请核对本地输出和退出状态后再试。';

  @override
  String get aiAgentHostAccessTitle => '确认访问其他主机';

  @override
  String aiAgentHostAccessPrompt(String host) {
    return '允许本会话访问“$host”？后续命令仍遵循所选权限模式。';
  }

  @override
  String get aiAgentHostAccessAllow => '允许访问';

  @override
  String get terminalAiFix => '修复上一条失败的命令';

  @override
  String get terminalAiGenerate => '生成命令';

  @override
  String get terminalAiInstruction => '描述你想完成的操作';

  @override
  String get terminalAiAuto => '自动执行';

  @override
  String get terminalAiFailed => '未能生成命令，请重试。';

  @override
  String get terminalAiFailedTimeout => '生成超时，请重试。';

  @override
  String get terminalAiFailedNetwork => '无法连接模型服务，请检查网络或设置。';

  @override
  String terminalAiFailedHttp(int code) {
    return '模型服务返回 HTTP $code。';
  }

  @override
  String get terminalAiFailedInvalid => '模型返回的命令无效，请换个说法重试。';

  @override
  String get aiAgentHistory => '历史会话';

  @override
  String get aiAgentHistoryEmpty => '暂无历史会话';

  @override
  String get aiAgentContinueConversation => '继续会话';

  @override
  String aiAgentHistoryContinueNotice(String destination, String host) {
    return '继续时，将向 $destination 重新发送本会话保留的有限历史；当前主机：$host。';
  }

  @override
  String get aiAgentHistoryTargetChanged => '模型目的地已变化，请新建会话。';

  @override
  String get aiAgentHistoryLoadFailed => '无法读取会话历史，请重试。';

  @override
  String get aiAgentHistorySaveFailed => '会话历史未能保存，当前内容仍保留在内存中。';

  @override
  String get aiAgentHistoryRetry => '重试';

  @override
  String get aiAgentHistoryTruncated => '部分会话记录已按容量限制裁剪。';

  @override
  String get aiAgentHistoryOutputUnavailable => '原始工具输出未保存在历史中。';

  @override
  String get aiAgentHistoryDelete => '删除会话';

  @override
  String get aiAgentHistoryDeleteConfirm => '删除此会话及其本地历史记录？';

  @override
  String get aiAgentHistoryBusy => '请先停止当前任务或等待结束，再切换会话。';

  @override
  String get aiAgentHistoryLocalNotice => '会话文字保存在本地，可能含敏感信息；不保存原始工具输出。';

  @override
  String get aiModelSearch => '搜索模型';

  @override
  String get aiModelsLoadFailed => '无法获取模型列表，可重试或输入模型名称。';

  @override
  String aiModelsLoadHttp(String status) {
    return '服务返回 HTTP $status，请检查密钥和地址。';
  }

  @override
  String get aiModelsLoadTimedOut => '请求超时，可重试或输入模型名称。';

  @override
  String aiModelCustom(String model) {
    return '使用 $model';
  }

  @override
  String get aiModelsEmpty => '未找到模型';

  @override
  String get aiModelsRefresh => '刷新模型';

  @override
  String get aiAgentContextCompacted => '较早上下文已自动压缩，以保持在模型限制内。';

  @override
  String get aiConfigAgentModel => '默认 Airy 模型';

  @override
  String get aiConfigReviewModel => '审批模型';

  @override
  String get aiConfigInlineModel => '行内生成模型';

  @override
  String get aiConfigPrediction => '预测下一条命令（→ 接受）';

  @override
  String get aiConfigCompletionModel => '补全模型';

  @override
  String get aiConfigContextCustom => '自定义';

  @override
  String get aiConfigApiKeyOptional => 'API Key（可选）';

  @override
  String get aiConfigFeatureAdvanced => '高级设置';

  @override
  String get aiConfigAvailableHosts => '可用主机';

  @override
  String get aiConfigFeatureNoHosts => '新增 SSH 主机将自动启用。';

  @override
  String get aiAgentAutoTarget => '自动选择';

  @override
  String get aiAgentPermissionAuto => '全自动';

  @override
  String get aiAgentPermissionConfirm => '确认';

  @override
  String get aiAgentPermissionObserve => '观察';

  @override
  String get aiAgentPermissionReview => '自动确认';

  @override
  String get aiAgentPermissionAutoHint => '自动读取、执行与发送结果';

  @override
  String get aiAgentPermissionConfirmHint => '人工批准读取与执行';

  @override
  String get aiAgentPermissionObserveHint => '只读工具，读取需批准';

  @override
  String get aiAgentPermissionReviewHint => '模型审批，无法判断时由你确认';

  @override
  String get aiAgentReviewing => '审批模型正在审核…';

  @override
  String get aiAgentReadApproveTitle => '确认读取信息';

  @override
  String get aiAgentReadApproveHint => '运行固定只读诊断，并允许 Airy 使用该操作的有界结果。';

  @override
  String get aiAgentContentApproveHint => '允许 Airy 读取这项内容并在本轮使用其有界结果。';

  @override
  String get aiAgentActionApproveTitle => '确认操作';

  @override
  String get aiAgentActionApproveHint => '允许 Airy 执行这项操作并在本轮使用其有界结果。';

  @override
  String get aiAgentDiagnosticSystem => '系统与内存';

  @override
  String get aiAgentDiagnosticStorage => '磁盘容量';

  @override
  String get aiAgentDiagnosticProcesses => '进程资源';

  @override
  String get aiAgentDiagnosticPorts => '监听端口';

  @override
  String get aiAgentDiagnosticServices => '服务状态';

  @override
  String aiAgentContextUsage(int percent, int used, int total) {
    return '上下文估算占用：$percent% · $used / $total tokens';
  }

  @override
  String get aiAgentRegenerate => '重新生成';

  @override
  String get aiAgentRegenerateHint => '重新回答，不重复执行命令';

  @override
  String get aiAgentWithdraw => '撤回上一轮';

  @override
  String get aiAgentWithdrawHint => '将上一轮问题恢复为草稿，不撤销已执行操作；请先清空当前草稿。';

  @override
  String get aiAgentExecutionRecord => '执行记录';

  @override
  String get aiAgentThinkingFlow => '思考流程';

  @override
  String get aiAgentCopied => '已复制';

  @override
  String get aiAgentCopyFailed => '复制失败，请选中文字后手动复制。';

  @override
  String get aiAgentToolLocalRequest => '申请本地访问';

  @override
  String get aiAgentToolLocalList => '列出本地目录';

  @override
  String get aiAgentToolLocalStat => '本地文件信息';

  @override
  String get aiAgentToolLocalRead => '读取本地文件';

  @override
  String get aiAgentToolLocalHint => '使用你在本会话中授权的本地文件和文件夹。';

  @override
  String get aiAgentLocalFolder => '文件夹';

  @override
  String get aiAgentLocalGrantRevoke => '撤销授权';

  @override
  String aiAgentLocalGrantWrite(String name) {
    return '$name · 可写入';
  }

  @override
  String get aiAgentLocalGrantExpired => '本地授权已失效，请重新添加或授权。';

  @override
  String get aiAgentLocalAccessTitle => '授权访问本地文件';

  @override
  String get aiAgentLocalAccessFolder => 'Airy 请求在本会话中读取一个文件夹。';

  @override
  String get aiAgentLocalAccessFile => 'Airy 请求在本会话中读取一个文件。';

  @override
  String get aiAgentLocalAccessWrite => 'Airy 请求在本会话中读写一个文件夹，服务器上的文件可能会下载到这里。';

  @override
  String get aiAgentLocalAccessChooseFolder => '选择文件夹';

  @override
  String get aiAgentLocalAccessChooseFile => '选择文件';

  @override
  String get mcpTitle => 'MCP / Skill';

  @override
  String get mcpChangeFailed => '未能保存更改。';

  @override
  String get mcpStartFailed => 'MCP 启动失败，请检查端口和系统安全存储。';

  @override
  String get mcpModeModel => '模型审核';

  @override
  String get mcpModeHost => '主机确认';

  @override
  String get mcpModeAuto => '范围内自动';

  @override
  String get mcpModeModelHint =>
      '每台主机在会话中首次使用时由你确认，之后每次调用再由审批模型判断，拒绝或无法判断的调用不执行。';

  @override
  String get mcpModeHostHint => '每台主机在会话中首次使用时由你确认，确认后固定诊断直接执行，不再询问。';

  @override
  String get mcpModeAutoHint => '只能访问你选定的主机，固定诊断直接执行，不询问；其他主机一律拒绝。';

  @override
  String mcpScopeHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 台主机',
      zero: '未选主机',
    );
    return '$_temp0';
  }

  @override
  String get mcpAudit => 'MCP 审计';

  @override
  String get mcpAuditEmpty => '暂无 MCP 调用记录。';

  @override
  String get mcpAuditCompleted => '已完成';

  @override
  String get mcpAuditRunning => '进行中';

  @override
  String get mcpAuditCancelled => '已取消';

  @override
  String get mcpAuditHostDenied => '主机未获允许';

  @override
  String get mcpAuditReviewDenied => '审批模型拒绝';

  @override
  String get mcpAuditReviewUnavailable => '审批模型不可用';

  @override
  String get mcpAuditOutsideScope => '主机不在范围内';

  @override
  String get mcpAuditScopeChanged => '调用期间授权已变化';

  @override
  String get mcpAuditNotExposed => '工具未开放';

  @override
  String get mcpAuditInvalid => '参数无效';

  @override
  String mcpAuditFailed(String code) {
    return '失败（$code）';
  }

  @override
  String get mcpClientConflict => '已保留现有配置';

  @override
  String get mcpClientUnavailable => '客户端配置不可用';

  @override
  String mcpClientConnected(String client) {
    return '$client 已连接';
  }

  @override
  String mcpHostPrompt(String client, String host) {
    return '允许 $client 在本次 MCP 会话中诊断「$host」？';
  }

  @override
  String get mcpPortSave => '保存端口';

  @override
  String mcpScopeChanged(String host) {
    return '$host（连接已变化，请重新选择）';
  }

  @override
  String get linkTitle => '手机互联';

  @override
  String get linkTab => '互联';

  @override
  String get linkEnabled => '启用电脑互联';

  @override
  String get linkPort => '互联端口';

  @override
  String get linkDiscovery => '局域网发现';

  @override
  String get linkDeviceName => '设备名称';

  @override
  String get linkAddresses => '本机地址';

  @override
  String linkRunning(int port) {
    return '正在监听端口 $port';
  }

  @override
  String get linkStopped => '未开启';

  @override
  String get linkStartFailed => '无法启动互联服务';

  @override
  String get linkPairDevice => '配对新设备';

  @override
  String get linkCancelPairing => '取消配对';

  @override
  String get linkPairingCode => '配对码';

  @override
  String get linkCopyUri => '复制配对链接';

  @override
  String get linkCopied => '已复制';

  @override
  String get linkPairedDevices => '已配对设备';

  @override
  String get linkNoPeers => '暂无已配对设备。';

  @override
  String get linkOnline => '已连接';

  @override
  String get linkOffline => '离线';

  @override
  String get linkPermMirror => '终端镜像';

  @override
  String get linkPermProxy => '电脑代理连接';

  @override
  String get linkPermSync => '配置同步';

  @override
  String get linkPermApproval => '远程审批';

  @override
  String get linkRevoke => '取消配对';

  @override
  String get linkDisconnect => '断开';

  @override
  String get linkPushCredentials => '推送凭据';

  @override
  String linkPushCredentialsTitle(String device) {
    return '向「$device」推送加密凭据';
  }

  @override
  String linkPushCredentialsSent(String device) {
    return '已向「$device」发送加密凭据';
  }

  @override
  String get linkPushCredentialsEmpty => '请至少选择一个主机密码或私钥。';

  @override
  String get linkScanLan => '扫描局域网';

  @override
  String get linkScanning => '扫描中...';

  @override
  String get linkDiscoveredDesktops => '附近电脑';

  @override
  String get linkSavedDesktops => '已保存电脑';

  @override
  String get linkManualConnect => '与电脑配对';

  @override
  String get linkHostOrIp => '电脑 IP / Tailscale 地址';

  @override
  String get linkPasteUri => '粘贴配对链接';

  @override
  String get linkPairNow => '配对';

  @override
  String get linkReconnect => '连接';

  @override
  String linkConnectedTo(String desktop) {
    return '已互联：$desktop';
  }

  @override
  String get linkSyncConfig => '同步配置';

  @override
  String linkSyncDone(int hosts, int snippets, int keys) {
    return '已同步 $hosts 台主机、$snippets 条片段、+$keys 条信任密钥';
  }

  @override
  String get linkPendingApprovals => '待审批请求';

  @override
  String get linkDesktopOnlyAction => '请在电脑端完成';

  @override
  String get linkAllow => '批准';

  @override
  String get linkDeny => '拒绝';

  @override
  String get linkDesktopTerminals => '电脑实时终端';

  @override
  String get linkNoDesktopTerminals => '电脑端暂无打开的终端。';

  @override
  String get linkMirrorTag => '镜像';

  @override
  String get linkProxyTag => '经电脑连接';

  @override
  String get linkDesktopHosts => '经电脑代理连接';

  @override
  String get linkNoDesktopHosts => '电脑端暂无已保存主机。';

  @override
  String get linkCredentialOfferTitle => '电脑端推送了加密凭据';

  @override
  String linkCredentialOfferDetail(int passwords, int keys) {
    return '$passwords 个密码、$keys 把私钥';
  }

  @override
  String get linkCredentialImport => '存入系统安全存储';

  @override
  String linkCredentialImported(int count) {
    return '已安全导入 $count 项凭据';
  }

  @override
  String get linkPasswordSyncConfirmTitle => '确认同步服务器密码';

  @override
  String linkPasswordSyncConfirmBody(String device, int count) {
    return '「$device」请求同步 $count 个已保存的服务器密码。';
  }

  @override
  String get linkPasswordSyncAllow => '同步密码';

  @override
  String get linkPasswordSyncSkip => '不同步密码';

  @override
  String get linkPasswordSyncWaiting => '请在电脑端确认同步服务器密码…';

  @override
  String linkPasswordSyncImported(int count) {
    return '已同步 $count 个服务器密码';
  }

  @override
  String get linkPasswordSyncDeclined => '电脑端已取消服务器密码同步';

  @override
  String get linkErrorAuth => '设备身份校验失败';

  @override
  String get linkErrorCode => '配对码错误';

  @override
  String get linkErrorExpired => '配对码已过期';

  @override
  String get linkErrorRevoked => '电脑端已取消此设备配对';

  @override
  String get linkErrorNetwork => '无法连接到电脑端';

  @override
  String get mobileNoActiveTerminal => '暂无打开的终端';

  @override
  String get mobileSessions => '会话';

  @override
  String get mobileTools => '工具';

  @override
  String get mobileTabAiry => 'Airy';

  @override
  String get mobileTabMe => '我的';

  @override
  String get mobileScanQr => '扫码配对电脑';

  @override
  String get mobileScanQrHint => '对准电脑端 Sshairy 手机互联二维码';

  @override
  String get mobileHandoffToDesktop => '在电脑上继续打开';

  @override
  String get mobileHandoffSent => '已在电脑端打开';

  @override
  String get mobilePushClipboard => '推送剪贴板';

  @override
  String get mobileClipboardSent => '已发送剪贴板到电脑';

  @override
  String get mobileDirectTag => '直连';

  @override
  String get mobileKeepScreenOn => '终端常亮';

  @override
  String get mobileKeepAlive => '后台连接保活';

  @override
  String get mobileKeepAliveTitle => 'Sshairy 连接运行中';

  @override
  String mobileKeepAliveSubtitle(int count) {
    return '$count 个活跃会话';
  }

  @override
  String get mobileHaptics => '触觉反馈';

  @override
  String get mobileBiometricLock => '生物识别锁定';

  @override
  String get mobileUnlockPrompt => '验证身份以解锁 Sshairy';

  @override
  String get mobileUnlockAction => '解锁';

  @override
  String get mobileTrackpad => '触控板';

  @override
  String get mobileDraftMode => '命令草稿栏';

  @override
  String get mobileDraftPlaceholder => '输入命令，或直接描述让 Airy 生成…';

  @override
  String get mobileAskAiry => '问 Airy';

  @override
  String get mobileSyncAiFromDesktop => '从电脑同步 AI 配置';

  @override
  String get mobileAiQuickSystem => '负载与内存';

  @override
  String get mobileAiQuickDisk => '磁盘占用';

  @override
  String get mobileAiQuickLogs => '最近报错日志';

  @override
  String get mobileAiQuickPorts => '监听端口';

  @override
  String get mobileFileEditor => '编辑';

  @override
  String get mobileFileSaved => '已保存';

  @override
  String get mobileFileTooLarge => '文件过大，不支持手机端直接编辑';

  @override
  String get mobileSendPathToTerminal => '发送路径到终端';

  @override
  String get mobileNewFile => '新建文件';

  @override
  String get mobileNewFolder => '新建文件夹';

  @override
  String get mobileUploadFile => '上传文件';

  @override
  String get mobileGenerateKey => '生成 Ed25519 密钥';

  @override
  String get mobilePublicKeyCopied => '公钥已复制';

  @override
  String get mobileSecuritySection => '安全与后台';

  @override
  String get mobileTerminalSection => '终端与触控';

  @override
  String get mobileQuickConnect => '快速连接';

  @override
  String get mobileAllGroups => '全部';

  @override
  String get mobilePinned => '置顶';

  @override
  String get mobileSyncAiIncluded => '+ AI 配置';
}
