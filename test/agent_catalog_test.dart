import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sshairy/app/composition.dart';
import 'package:sshairy/features/ai/api.dart';
import 'package:sshairy/features/ai/adapters/model_provider.dart';
import 'package:sshairy/features/capabilities/api.dart';
import 'package:sshairy/foundation/data_dir.dart';
import 'package:sshairy/foundation/result.dart';

void main() {
  test('every real Agent tool has a valid supported schema and request encoding', () {
    final dir = Directory.systemTemp.createTempSync('sshairy-tool-catalog-');
    final container = ProviderContainer(overrides: [dataDirProvider.overrideWithValue(dir.path), ...appOverrides()]);
    addTearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });
    final dispatcher = container.read(capabilityDispatcherProvider);
    for (final tool in agentTools) {
      final capability = dispatcher[tool.capability];
      expect(capability, isNotNull, reason: tool.name);
      expect(capability!.agentExposed, isTrue, reason: tool.name);
      final checked = CapabilitySchema.validate(capability.inputSchema, {});
      if (checked case Err(:final error)) {
        expect(error.code, isNot('invalidSchema'), reason: tool.name);
      }
    }
    for (final protocol in ModelProtocol.values) {
      final request = ModelRequest(
        profile: ModelProfile(protocol: protocol, endpoint: 'https://model.example/v1', model: 'catalog'),
        system: '',
        messages: [ModelMessage(ModelRole.user, text: 'inspect')],
        tools: [
          for (final tool in agentTools)
            ModelTool(tool.name, tool.description, dispatcher[tool.capability]!.inputSchema),
        ],
      );
      expect(encodeModelRequest(request)['tools'], hasLength(agentTools.length));
    }
    final patch = dispatcher['settings.patch']!.inputSchema;
    expect(patch['required'], contains('expectedRevision'));
    expect((patch['properties'] as Map).keys, isNot(contains('shortcuts')));
  });
}
