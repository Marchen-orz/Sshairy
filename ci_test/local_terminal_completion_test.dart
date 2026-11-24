import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/application/configuration.dart';
import 'package:sshairy/features/ai/application/terminal_service.dart';
import 'package:sshairy/features/ai/domain/model.dart';
import 'package:sshairy/features/terminal/adapters/terminal_paths.dart';
import 'package:sshairy/features/terminal/api.dart';
import 'package:sshairy/features/terminal/domain/spec_completion.dart';
import 'package:sshairy/features/terminal/domain/terminal_paths.dart';
import 'package:sshairy/foundation/cancellation.dart';
import 'package:sshairy/foundation/file_system.dart';
import 'package:sshairy/foundation/ids.dart';

class _FakeModel implements ModelProvider {
  _FakeModel(this.reply);

  final String reply;
  final requests = <ModelRequest>[];

  @override
  Stream<ModelEvent> stream(ModelRequest request, CancellationToken cancel) async* {
    requests.add(request);
    yield ModelTextDelta(reply);
    yield ModelMessageComplete(ModelMessage(ModelRole.assistant, text: reply));
  }

  @override
  void close() {}
}

void main() {
  group('local shell prompt and working directory recognition', () {
    test('extracts command draft and directory for PowerShell, CMD, Git Bash and Unix shells', () {
      expect(visibleLocalShellCommand(r'PS C:\Users\Dev\repo> git st', '', powershell: true, bash: false), 'git st');
      expect(
        visiblePromptDirectory(r'PS C:\Users\Dev\repo> git st', localKind: LocalShellKind.powershell),
        r'C:\Users\Dev\repo',
      );
      expect(visibleLocalShellCommand('PS /Users/dev/repo> ls -la', '', powershell: true, bash: false), 'ls -la');
      expect(visiblePromptDirectory('PS /Users/dev/repo> ls -la', localKind: LocalShellKind.pwsh), '/Users/dev/repo');
      expect(visibleLocalShellCommand(r'D:\work\proj>dir .\src', '', powershell: false, bash: false), r'dir .\src');
      expect(visiblePromptDirectory(r'D:\work\proj>dir .\src', localKind: LocalShellKind.cmd), r'D:\work\proj');
      expect(visibleLocalShellCommand(r'$ git status', '', powershell: false, bash: true), 'git status');
      expect(
        visiblePromptDirectory(
          r'$ git status',
          localKind: LocalShellKind.gitBash,
          previousLine: 'dev@PC MINGW64 /d/work/repo (main)',
        ),
        '/d/work/repo',
      );
      expect(visibleUnixShellCommand('dev@box ~/proj% git diff', '', percent: true), 'git diff');
      expect(visiblePromptDirectory('dev@box ~/proj% git diff', localKind: LocalShellKind.zsh), '~/proj');
    });
  });

  group('Windows command and spec completion', () {
    final gitSpec = CompletionSpec.fromJson(
      jsonDecode(r'''
{
  "name": "git",
  "subcommands": [
    {
      "name": "checkout",
      "options": [{"name": "-b", "args": {"name": "branch"}}],
      "args": {"name": "branch", "isOptional": true, "suggestions": ["main", "develop"]}
    },
    {
      "name": "add",
      "options": [{"name": ["-A", "--all"]}],
      "args": {"name": "pathspec", "isVariadic": true, "template": "filepaths"}
    }
  ]
}''') as Map<String, Object?>,
    );

    test('PowerShell and CMD syntax preserve backslashes and normalize .exe command names', () {
      final psCtx = CompletionContext.parse(r'git.exe add .\src\ma', syntax: CompletionSyntax.powershell);
      expect(psCtx.supported, isTrue);
      expect(psCtx.words.first.value, 'git.exe');
      expect(psCtx.current.value, r'.\src\ma');

      final subResult = completeSpec(gitSpec, 'git.exe che', syntax: CompletionSyntax.powershell);
      expect(subResult.suggestions.map((s) => s.value), contains('checkout'));

      final pathResult = completeSpec(gitSpec, r'git add .\src\ma', syntax: CompletionSyntax.powershell);
      expect(pathResult.path, isNotNull);
      expect(pathResult.path!.typedPrefix, r'.\src\ma');
      expect(pathResult.path!.syntax, CompletionSyntax.powershell);

      final cmdResult = completeSpec(null, r'type .\doc', syntax: CompletionSyntax.cmd);
      expect(cmdResult.path, isNotNull);
      expect(cmdResult.path!.typedPrefix, r'.\doc');
      expect(cmdResult.path!.syntax, CompletionSyntax.cmd);
    });
  });

  group('local filesystem path completion', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('sshairy-local-paths-');
      Directory('${temp.path}${Platform.pathSeparator}alpha dir').createSync();
      Directory('${temp.path}${Platform.pathSeparator}assets').createSync();
      File('${temp.path}${Platform.pathSeparator}app.dart').writeAsStringSync('void main() {}');
      File('${temp.path}${Platform.pathSeparator}README.md').writeAsStringSync('# hi');
    });

    tearDown(() => temp.deleteSync(recursive: true));

    test(
      'browses local Windows directories, filters folders, and preserves case-insensitive prefix matching',
      () async {
        final reader = LocalDirectoryReader(windows: true, msys: false);
        final browser = RemotePathBrowser(reader, generation: 1, style: PathStyle.windows);
        addTearDown(browser.dispose);

        final dirPath = temp.path.replaceAll('/', r'\');
        final all = await browser.browse(RemotePathQuery(directory: dirPath, prefix: 'a'));
        expect(all.entries.map((e) => e.name), ['alpha dir', 'assets', 'app.dart']);

        final foldersOnly = await browser.browse(RemotePathQuery(directory: dirPath, prefix: 'A', foldersOnly: true));
        expect(foldersOnly.entries.map((e) => e.name), ['alpha dir', 'assets']);

        final absolute = RemotePaths.absolute(r'.\alpha', cwd: dirPath, style: PathStyle.windows);
        expect(absolute, '$dirPath\\alpha');
      },
    );

    test('converts MSYS paths for Git Bash local terminals', () {
      expect(LocalDirectoryReader.toMsysPath(r'D:\OneDrive\Projects'), '/d/OneDrive/Projects');
      expect(LocalDirectoryReader.fromMsysPath('/d/OneDrive/Projects'), r'D:\OneDrive\Projects');
      expect(LocalDirectoryReader.fromMsysPath('/c'), r'C:\');
    });
  });

  group('local terminal AI completion and generation', () {
    AiConfiguration enabledConfig() => AiConfiguration(
      enabled: true,
      inlineEnabled: true,
      completionEnabled: true,
      profile: ModelProfile(
        protocol: ModelProtocol.openai,
        endpoint: 'https://api.example.com/v1',
        model: 'gpt-4o-mini',
      ),
    );

    test('allows local PowerShell/CMD targets, accepts Windows drafts, and requests grounded completions', () async {
      final model = _FakeModel(r'{"status":"suggest","command":"Get-ChildItem -Path .\\src -Recurse"}');
      final service = AiTerminalService(model: model, configuration: enabledConfig, hosts: () => const []);
      addTearDown(service.dispose);

      const psContext = TerminalAiContext(
        sessionId: SessionId('local-ps'),
        target: LocalTerminalAiTarget(LocalShellKind.powershell),
        generation: 1,
        revision: 1,
        prompt: TerminalAiPrompt.recognized,
        draft: r'Get-ChildItem -Path .\s',
        directory: r'D:\work\repo',
      );
      expect(service.canGenerate(psContext), isTrue);
      expect(service.canComplete(psContext), isTrue);

      const cmdContext = TerminalAiContext(
        sessionId: SessionId('local-cmd'),
        target: LocalTerminalAiTarget(LocalShellKind.cmd),
        generation: 1,
        revision: 1,
        prompt: TerminalAiPrompt.recognized,
        draft: r'dir .\src',
        directory: r'D:\work\repo',
      );
      expect(service.canComplete(cmdContext), isTrue);

      final completion = await service.complete(psContext, [
        TerminalAiHistoryEntry(
          text: r'Get-ChildItem -Path .\src -Recurse',
          at: DateTime.utc(2026, 11, 24),
          generation: 1,
          resultStatus: TerminalAiHistoryResultStatus.available,
          boundary: TerminalAiHistoryBoundary.prompt,
        ),
      ], CancellationToken());
      expect(completion, r'Get-ChildItem -Path .\src -Recurse');
      expect(model.requests, hasLength(1));
      expect(model.requests.single.messages.single.text, contains('powershell'));
    });
  });
}
