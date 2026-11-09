import '../../../foundation/cancellation.dart';
import '../domain/known_keys.dart';
import '../domain/prompts.dart';

/// Prompts belong to one dial, even when the client's authentication callbacks outlive it.
class AttemptPrompts implements ConnectPrompts {
  AttemptPrompts(this._inner, this._cancel);

  ConnectPrompts? _inner;
  final CancellationToken _cancel;
  (String, String, String)? _acceptedOnce;

  void detach() => _inner = null;

  (String, String, String) _key(HostKeyPrompt prompt) => (prompt.endpoint, prompt.type, prompt.fingerprint);

  @override
  Future<TrustChoice> hostKey(HostKeyPrompt prompt) async {
    if (_cancel.isCancelled) return TrustChoice.reject;
    final inner = _inner;
    if (inner == null) {
      return prompt.check is KeyUnknown && _acceptedOnce == _key(prompt) ? TrustChoice.once : TrustChoice.reject;
    }
    final choice = await Future.any([inner.hostKey(prompt), _cancel.whenCancelled.then((_) => TrustChoice.reject)])
        .timeout(const Duration(seconds: 120), onTimeout: () => TrustChoice.reject);
    if (_cancel.isCancelled || !identical(_inner, inner)) return TrustChoice.reject;
    if (choice == TrustChoice.once && prompt.check is KeyUnknown) _acceptedOnce = _key(prompt);
    return choice;
  }

  @override
  Future<SecretAnswer?> secret(SecretRequest request) async {
    final inner = _inner;
    if (_cancel.isCancelled || inner == null) return null;
    final answer = await Future.any([inner.secret(request), _cancel.whenCancelled.then<SecretAnswer?>((_) => null)])
        .timeout(const Duration(seconds: 120), onTimeout: () => null);
    return _cancel.isCancelled || !identical(_inner, inner) ? null : answer;
  }
}
