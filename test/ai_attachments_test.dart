import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/features/ai/adapters/attachments.dart';
import 'package:sshairy/features/ai/adapters/conversation_store.dart';
import 'package:sshairy/features/ai/adapters/model_provider.dart';
import 'package:sshairy/features/ai/application/context.dart';
import 'package:sshairy/features/ai/domain/conversation.dart';
import 'package:sshairy/features/ai/domain/model.dart';

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

AgentAttachment _text([String id = 'text']) => AgentAttachment.text(id: id, name: 'example.txt', text: 'hello 中文\n');

Future<Uint8List> _noisePng() async {
  const size = 640;
  final random = Random(1);
  final pixels = Uint8List(size * size * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = random.nextInt(256);
    pixels[i + 1] = random.nextInt(256);
    pixels[i + 2] = random.nextInt(256);
    pixels[i + 3] = 255;
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final descriptor = ui.ImageDescriptor.raw(buffer, width: size, height: size, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  final image = (await codec.getNextFrame()).image;
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('attachment boundaries reject unsafe text, paths, duplicate IDs and oversized inputs', () {
    expect(() => AgentAttachment.text(id: 'one', name: '/private/file.txt', text: 'content'), throwsFormatException);
    for (final value in ['a\u0000b', 'PASSWORD=synthetic-private', '-----BEGIN PRIVATE KEY-----\nsynthetic']) {
      expect(() => AgentAttachment.text(id: 'one', name: 'example.txt', text: value), throwsFormatException);
    }
    expect(
      () => AgentAttachment.text(id: 'one', name: 'example.txt', text: 'x' * (AgentAttachmentLimits.totalBytes + 1)),
      throwsFormatException,
    );
    expect(() => checkedAgentAttachments([_text(), _text()]), throwsFormatException);
    expect(
      () => checkedAgentAttachments([for (var i = 0; i <= AgentAttachmentLimits.count; i++) _text('text-$i')]),
      throwsFormatException,
    );
    final image = base64Decode(_png);
    image.setRange(16, 20, [0, 0, 8, 1]);
    expect(
      () => AgentAttachment.image(id: 'image', name: 'image.png', base64: base64Encode(image)),
      throwsFormatException,
    );
    expect(() => AgentAttachment.fromJson({..._text().toJson(), 'path': 'C:/private.txt'}), throwsFormatException);
  });

  test('both protocols encode inline user content with metadata and no local paths', () {
    final attachments = [_text(), AgentAttachment.image(id: 'image', name: 'image.png', base64: _png)];
    for (final protocol in ModelProtocol.values) {
      final request = ModelRequest(
        profile: ModelProfile(protocol: protocol, endpoint: 'https://model.invalid/v1', model: 'test'),
        system: '',
        messages: [ModelMessage(ModelRole.user, text: 'inspect attachments', attachments: attachments)],
      );
      final encoded = encodeModelRequest(request);
      final responses = protocol == ModelProtocol.responses;
      final content = ((encoded[responses ? 'input' : 'messages'] as List).single as Map)['content'] as List;
      expect(content.where((value) => (value as Map)['type'] == (responses ? 'input_text' : 'text')), hasLength(3));
      final image = content.last as Map;
      if (responses) {
        expect(image['type'], 'input_image');
        expect(image['image_url'], startsWith('data:image/png;base64,'));
      } else if (protocol == ModelProtocol.openai) {
        expect(image['type'], 'image_url');
        expect((image['image_url'] as Map)['url'], startsWith('data:image/png;base64,'));
      } else {
        expect(image['type'], 'image');
        expect((image['source'] as Map)['type'], 'base64');
        expect((image['source'] as Map)['media_type'], 'image/png');
      }
      expect(jsonEncode(encoded), contains('hello 中文'));
      expect(jsonEncode(encoded), isNot(contains('C:/')));
      expect(
        () => encodeModelRequest(
          ModelRequest(
            profile: request.profile,
            system: '',
            messages: [ModelMessage(ModelRole.assistant, attachments: attachments)],
          ),
        ),
        throwsA(isA<ModelFailure>()),
      );
    }
  });

  test('attachments count toward context budget and survive tool-group compaction', () {
    final attachment = _text();
    final context = AgentContext(
      input: 'question',
      goalInput: 'question',
      attachments: [attachment],
      previous: {
        'entries': [
          {'kind': 'user', 'text': 'old question'},
        ],
      },
    );
    final empty = AgentContext(input: 'question', goalInput: 'question');
    final profile = ModelProfile(
      protocol: ModelProtocol.openai,
      endpoint: 'https://model.invalid/v1',
      model: 'test',
      contextWindow: 32000,
    );
    expect(context.estimatedTokens(profile, '', []), greaterThan(empty.estimatedTokens(profile, '', [])));
    context.add(ModelMessage(ModelRole.assistant, calls: [ModelCall('call', 'host_list', {})]));
    context.add(ModelMessage(ModelRole.tool, toolCallId: 'call', text: '[]'));
    expect(
      context.prepare(
        profile,
        '',
        [],
        estimateBytes: (messages) => messages.first.text.contains('contextSummary') ? 100 : 100000,
      ),
      isTrue,
    );
    expect(context.messages.first.attachments.single, same(attachment));
  });

  test('selected files are decoded strictly, normalized, and paths discarded', () async {
    final directory = await Directory.systemTemp.createTemp('sshairy-attachment-test-');
    addTearDown(() => directory.delete(recursive: true));
    final text = File('${directory.path}/example.txt');
    await text.writeAsString('hello 中文\n');
    final image = File('${directory.path}/image.png');
    await image.writeAsBytes(base64Decode(_png));
    final picker = AgentAttachmentPicker(pick: () async => [text.path, image.path]);
    final attachments = await picker.choose([]);
    expect(attachments.map((value) => value.name), ['example.txt', 'image.png']);
    expect(attachments.first.content, 'hello 中文\n');
    expect(attachments.last.isImage, isTrue);
    expect(jsonEncode(attachments.map((value) => value.toJson()).toList()), isNot(contains(directory.path)));
    for (final file in [
      File('${directory.path}/bad.txt'),
      File('${directory.path}/.env'),
      File('${directory.path}/file.pdf'),
    ]) {
      await file.writeAsBytes(Uint8List.fromList([255, 254, 0]));
      await expectLater(AgentAttachmentPicker(pick: () async => [file.path]).choose([]), throwsFormatException);
    }
    await text.writeAsString('x' * (AgentAttachmentLimits.totalBytes + 1));
    await expectLater(AgentAttachmentPicker(pick: () async => [text.path]).choose([]), throwsFormatException);
    expect(await AgentAttachmentPicker(pick: () async => []).choose(attachments), same(attachments));
  });

  test('ordinary image and log batches exceed the old limits and survive saving', () async {
    final directory = await Directory.systemTemp.createTemp('sshairy-large-attachments-');
    addTearDown(() => directory.delete(recursive: true));
    final png = await _noisePng();
    expect(png.length, greaterThan(256 << 10));
    final paths = <String>[];
    for (var i = 0; i < 5; i++) {
      final file = File('${directory.path}/screenshot-$i.png');
      await file.writeAsBytes(png);
      paths.add(file.path);
    }
    final log = File('${directory.path}/application.custom-log');
    await log.writeAsString('log line 中文\n' * 8000);
    paths.add(log.path);
    final attachments = await AgentAttachmentPicker().importFiles(paths, []);
    expect(attachments, hasLength(6));
    expect(attachments.last.bytes, greaterThan(64 << 10));
    expect(attachments.fold(0, (size, item) => size + item.bytes), greaterThan(2 << 20));
    final now = DateTime.now().toUtc();
    final store = JsonConversationStore(directory.path);
    await store.save([
      AgentConversationRecord(
        id: 'large',
        title: 'Images and log',
        createdAt: now,
        updatedAt: now,
        destination: '["openai","https://model.invalid/v1"]',
        entries: [ConversationEntry(kind: ConversationEntryKind.user, text: 'inspect', attachments: attachments)],
      ),
    ]);
    final restored = (await JsonConversationStore(directory.path).load()).single.entries.single.attachments;
    expect(restored.map((a) => a.toJson()), attachments.map((a) => a.toJson()));
    expect(restored.last.content, 'log line 中文\n' * 8000);
  });

  test('only the failing filename is reported and an over-budget batch stays atomic', () async {
    final directory = await Directory.systemTemp.createTemp('sshairy-attachment-errors-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/over-budget.txt');
    await file.writeAsString('x' * (9 << 20));
    final current = [AgentAttachment.text(id: 'existing', name: 'previous.txt', text: 'x' * (8 << 20))];
    await expectLater(
      AgentAttachmentPicker().importFiles([file.path], current),
      throwsA(
        isA<AttachmentImportFailure>()
            .having((error) => error.message, 'reason', 'attachmentTotalTooLarge')
            .having((error) => error.fileName, 'name', 'over-budget.txt'),
      ),
    );
    expect(current.single.name, 'previous.txt');
    expect(current.single.bytes, 8 << 20);
  });

  test('file paste and drop share picker validation without exposing paths', () async {
    final directory = await Directory.systemTemp.createTemp('sshairy-file-inputs-');
    addTearDown(() => directory.delete(recursive: true));
    final text = File('${directory.path}/copy.txt');
    await text.writeAsString('copied text 中文');
    final picker = AgentAttachmentPicker(clipboard: () async => [text.path]);
    final pasted = await picker.importFiles(await picker.clipboardFiles(), []);
    final dropped = await picker.importFiles([text.path], []);
    expect(pasted.single.content, dropped.single.content);
    expect(pasted.single.name, 'copy.txt');
    expect(jsonEncode(pasted.single.toJson()), isNot(contains(directory.path)));
    final folder = await Directory('${directory.path}/folder.txt').create();
    await expectLater(picker.importFiles([folder.path], pasted), throwsFormatException);
    final unsupported = File('${directory.path}/document.pdf');
    await unsupported.writeAsString('unsupported');
    await expectLater(picker.importFiles([text.path, unsupported.path], pasted), throwsFormatException);
    expect(pasted, hasLength(1), reason: 'A rejected batch does not modify existing attachments');
    await text.writeAsString('TOKEN=synthetic-private');
    await expectLater(picker.importFiles([text.path], pasted), throwsFormatException);
    expect(await picker.importFiles([], pasted), same(pasted));
  });

  test('file clipboard count and path length are bounded before files are opened', () async {
    await expectLater(
      AgentAttachmentPicker(clipboard: () async => List.filled(AgentAttachmentLimits.count + 1, 'ignored.txt'))
          .clipboardFiles(),
      throwsFormatException,
    );
    await expectLater(
      AgentAttachmentPicker(clipboard: () async => ['x' * 32768]).clipboardFiles(),
      throwsFormatException,
    );
    final picker = AgentAttachmentPicker();
    await expectLater(
      picker.importFiles(List.filled(AgentAttachmentLimits.count + 1, 'ignored.txt'), []),
      throwsFormatException,
    );
  });

  test('history round-trips attachment content and applies the existing whole-turn byte limit', () async {
    final directory = await Directory.systemTemp.createTemp('sshairy-attachment-store-');
    addTearDown(() => directory.delete(recursive: true));
    final now = DateTime.now().toUtc();
    AgentConversationRecord record(List<ConversationEntry> entries) => AgentConversationRecord(
      id: 'conversation',
      title: 'Attachments',
      createdAt: now,
      updatedAt: now,
      destination: '["openai","https://model.invalid/v1","test"]',
      entries: entries,
    );
    final attachments = [_text(), AgentAttachment.image(id: 'image', name: 'image.png', base64: _png)];
    final store = JsonConversationStore(directory.path);
    await store.save([
      record([ConversationEntry(kind: ConversationEntryKind.user, text: '', attachments: attachments)]),
    ]);
    final restored = (await JsonConversationStore(directory.path).load()).single.entries.single.attachments;
    expect(restored.map((value) => value.toJson()), attachments.map((value) => value.toJson()));
    final large = [
      for (var i = 0; i < 4; i++) AgentAttachment.text(id: 'large-$i', name: 'large.txt', text: 'x' * (2 << 20)),
    ];
    final bounded = boundedConversationRecords([
      record([
        for (var turn = 0; turn < 5; turn++) ...[
          ConversationEntry(kind: ConversationEntryKind.user, text: 'turn $turn', attachments: large),
          const ConversationEntry(kind: ConversationEntryKind.assistant, text: 'answer'),
        ],
      ]),
    ]).single;
    expect(bounded.historyTruncated, isTrue);
    expect(bounded.entries.first.text, isNot('turn 0'));
    expect(bounded.entries.last.text, 'answer');
  });
}
