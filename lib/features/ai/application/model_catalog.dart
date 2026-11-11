import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../credentials/api.dart';
import '../adapters/model_catalog.dart';
import '../domain/model_catalog.dart';
import 'configuration.dart';

final aiModelCatalogProvider = Provider<ModelCatalog>((ref) {
  final credentials = ref.read(aiCredentialsProvider);
  final catalog = HttpModelCatalog(readKey: credentials.read);
  final keys = credentials.changes.listen((_) => catalog.cancelAll());
  ref.listen(aiConfigurationProvider, (_, _) => catalog.cancelAll());
  ref.onDispose(keys.cancel);
  ref.onDispose(catalog.close);
  return catalog;
});
