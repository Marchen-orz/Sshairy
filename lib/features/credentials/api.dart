import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'adapters/secure_store.dart';

export 'adapters/secure_store.dart' show SecretStore;

final secretStoreProvider = Provider<SecretStore>((_) => const SecretStore());
