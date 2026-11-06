import '../../../foundation/ids.dart';
import '../../hosts/api.dart';
import '../domain/prompts.dart';

/// Target first, outermost jump last. Resolve once before any asynchronous work.
List<Host> resolveRoute(Host host, Host? Function(HostId) byId) {
  final route = <Host>[];
  final seen = <HostId>{};
  var current = host;
  for (;;) {
    if (!seen.add(current.id)) throw const ConnectError(ConnectFailure.route, routeLoop);
    if (route.length == 8) throw const ConnectError(ConnectFailure.route, routeTooLong);
    route.add(current);
    final jump = current.jumpHostId;
    if (jump == null) return List.unmodifiable(route);
    final next = byId(jump);
    if (next == null) throw const ConnectError(ConnectFailure.route, routeMissing);
    current = next;
  }
}
