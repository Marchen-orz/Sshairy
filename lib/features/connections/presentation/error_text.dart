import '../../../l10n/app_localizations.dart';
import '../domain/prompts.dart';

String connectErrorText(AppLocalizations l, ConnectError? e) => switch (e?.kind) {
  ConnectFailure.auth => e!.detail == proxyAuthDetail ? l.errProxyAuth : l.errAuth,
  ConnectFailure.hostKeyRejected => l.errHostKeyRejected,
  ConnectFailure.keyFile => l.errKeyFile(e!.detail),
  ConnectFailure.cancelled => l.errCancelled,
  ConnectFailure.route => switch (e!.detail) {
    routeLoop => l.errRouteLoop,
    routeMissing => l.errRouteMissing,
    routeTooLong => l.errRouteTooLong,
    _ => l.errRouteInvalid,
  },
  _ => l.errConnect(e?.detail ?? ''),
};
