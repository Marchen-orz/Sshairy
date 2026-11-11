import 'dart:convert';

import '../../credentials/api.dart';
import '../domain/model_profile.dart';

/// A model-only edit keeps authentication on the same explicitly configured service.
Future<void> preserveModelKey(AiCredentials credentials, String beforeIdentity, ModelProfile after) async {
  if (beforeIdentity.length > 4096) throw StateError('modelKeyDestinationChanged');
  final before = jsonDecode(beforeIdentity);
  if (before is! List ||
      before.length != 3 ||
      before.any((value) => value is! String) ||
      before[0] != after.protocol.name ||
      ModelProfile.normalizeEndpoint(before[1] as String) != after.endpoint) {
    throw StateError('modelKeyDestinationChanged');
  }
  if (beforeIdentity == after.identity) return;
  final existing = await credentials.read(beforeIdentity);
  if (existing == null) throw StateError('modelKeyUnavailable');
  await credentials.save(after.identity, existing);
}
