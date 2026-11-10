import 'dart:math';

/// Distinct ID types so a host ID cannot be passed where a session ID is expected (docs/CONTRACTS.md §1).
extension type const HostId(String value) {}

extension type const SessionId(String value) {}

extension type const TransportId(String value) {}

extension type const PaneId(String value) {}

extension type const TabId(String value) {}

extension type const OperationId(String value) {}

extension type const TransferId(String value) {}

final _random = Random.secure();

/// 12 random base-36 characters.
String newId() => List.generate(12, (_) => _random.nextInt(36).toRadixString(36)).join();
