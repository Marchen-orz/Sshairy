/// Keeps a password or passphrase out of logs and string interpolation; only [reveal] returns the value.
class Secret {
  const Secret(this._value);

  final String _value;

  String reveal() => _value;

  @override
  String toString() => 'Secret(***)';
}
