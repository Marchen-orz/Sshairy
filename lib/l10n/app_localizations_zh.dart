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
}
