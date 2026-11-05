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
  String get newConnection => '新建连接';
}
