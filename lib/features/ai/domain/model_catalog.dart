import '../../../foundation/cancellation.dart';
import '../../../foundation/secret.dart';
import 'model_profile.dart';

/// A user-requested directory of model IDs, without conversation data or model permissions.
abstract interface class ModelCatalog {
  Future<List<String>> list({
    required ModelProtocol protocol,
    required String endpoint,
    required CancellationToken cancel,
    String? credentialIdentity,
    Secret? draftKey,
  });

  void cancelAll();
  void close();
}
