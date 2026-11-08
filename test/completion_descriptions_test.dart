import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/terminal/domain/command_assistance.dart';
import 'package:sshairy/features/terminal/presentation/completion_descriptions.dart';

void main() {
  CommandCandidate spec(String? detail, {String text = 'example', CommandKind kind = CommandKind.option}) =>
      CommandCandidate(text, source: CommandCandidateSource.builtin, kind: kind, detail: detail);

  test('English and unsupported languages keep the original specification explanation', () {
    const detail = '  List directory contents.  ';
    final candidate = spec(detail);
    expect(translatedCompletionDescription('en', candidate), detail);
    expect(translatedCompletionDescription('en-US', candidate), detail);
    expect(translatedCompletionDescription('fr', candidate), detail);
    expect(candidate.detail, detail);
  });

  test('Chinese translates reviewed descriptions with harmless formatting differences', () {
    final candidate = spec('  LIST\n directory   contents.  ', text: 'ls', kind: CommandKind.command);
    for (final language in ['zh', 'zh-CN', 'zh_TW', 'ZH-hans']) {
      expect(translatedCompletionDescription(language, candidate), '列出目录内容', reason: language);
    }
    expect(candidate.text, 'ls');
    expect(candidate.detail, '  LIST\n directory   contents.  ');
  });

  test('unknown descriptions return null for a localized kind fallback without guessing from option names', () {
    expect(
      translatedCompletionDescription('zh', spec('An untranslated vendor-specific option', text: 'tool -f')),
      isNull,
    );
    expect(translatedCompletionDescription('zh', spec('List directory contents and upload them')), isNull);
    expect(translatedCompletionDescription('zh', spec('   ')), isNull);
    expect(translatedCompletionDescription('zh', spec(null)), isNull);
  });

  test('snippet labels and external provider content are never translated as static specifications', () {
    for (final source in CommandCandidateSource.values.where((source) => source != CommandCandidateSource.builtin)) {
      final candidate = CommandCandidate('example', source: source, detail: 'List directory contents');
      expect(translatedCompletionDescription('zh', candidate), 'List directory contents', reason: source.name);
    }
  });

  test('translation is based on exact explanation rather than ambiguous short options', () {
    final head = spec('Show document info only', text: 'curl -I');
    final key = spec(
      'Selects a file from which the identity (private key) for public key authentication is read',
      text: 'ssh -i',
    );
    final remove = spec('Request confirmation before attempting to remove each file', text: 'rm -i');
    expect(translatedCompletionDescription('zh', head), '仅获取响应头');
    expect(translatedCompletionDescription('zh', key), '指定认证私钥文件');
    expect(translatedCompletionDescription('zh', remove), '逐个文件询问删除确认');
  });

  test('reviewed everyday commands resolve from the packaged specification text', () {
    final cases = <String, Map<String, String>>{
      'ls': {'': '列出目录内容', '-l': '以长格式显示文件详情', '-a': '显示以点开头的隐藏文件'},
      'grep': {'': '按普通模式或正则表达式搜索文本', '-i': '匹配时忽略大小写', '-n': '在匹配行前显示行号'},
      'ssh': {'': '登录远程主机', '-p': '指定远程主机端口', '-N': '仅建立连接，不执行远程命令'},
      'curl': {'': '向 URL 传输或获取数据', '-L': '跟随重定向', '-I': '仅获取响应头'},
      'git': {'': '分布式版本控制工具', 'status': '显示工作区和暂存区状态', 'commit': '将更改提交到仓库'},
      'docker': {'': '构建和运行容器', 'run': '创建新容器并运行命令', 'exec': '在运行中的容器内执行命令'},
      'tmux': {'': '管理多个终端会话、窗口和窗格', 'attach-session': '连接到最近的会话', 'new-session': '创建新会话'},
      'systemctl': {'status': '查看单元运行状态', 'restart': '启动或重启指定单元'},
      'apt': {'': '管理 Debian 系 Linux 软件包', 'update': '更新软件包索引', 'install': '安装软件包'},
      'npm': {'': '管理 Node.js 软件包', 'install': '安装软件包及其依赖', 'run': '运行软件包中定义的脚本'},
    };
    for (final command in cases.entries) {
      final root = jsonDecode(File('assets/completions/specs/${command.key}.json').readAsStringSync()) as Map;
      for (final expected in command.value.entries) {
        final children = <dynamic>[...?(root['subcommands'] as List?), ...?(root['options'] as List?)];
        final node = expected.key.isEmpty
            ? root
            : children.cast<Map>().firstWhere((node) {
                final name = node['name'];
                return name == expected.key || (name is List && name.contains(expected.key));
              });
        final candidate = spec(node['description'] as String?, text: '${command.key} ${expected.key}');
        expect(translatedCompletionDescription('zh', candidate), expected.value, reason: candidate.text);
      }
    }
  });

  test('repeated packaged argument type descriptions have Chinese translations', () {
    expect(translatedCompletionDescription('zh', spec('String')), '字符串参数');
    expect(translatedCompletionDescription('zh', spec('List')), '列表参数');
    expect(translatedCompletionDescription('zh', spec('Polling interval in seconds')), '设置轮询间隔，单位秒');
  });

  test('common AWS JSON parameters resolve from the packaged nested specification', () {
    final root = jsonDecode(File('assets/completions/specs/aws__s3api.json').readAsStringSync()) as Map;
    final command = (root['subcommands'] as List).first as Map;
    final options = (command['options'] as List).cast<Map>();
    for (final expected in {
      '--cli-input-json': '使用指定 JSON 字符串作为服务操作的输入',
      '--generate-cli-skeleton': '仅输出 JSON 结构示例，不发送 API 请求',
    }.entries) {
      final option = options.firstWhere((node) => node['name'] == expected.key);
      final candidate = spec(option['description'] as String?, text: expected.key);
      expect(translatedCompletionDescription('zh', candidate), expected.value, reason: expected.key);
    }
  });
}
