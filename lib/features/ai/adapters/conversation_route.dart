import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Persist only the digest, never connection configuration or credential references.
String conversationRouteFingerprint(
  String routeSignature, {
  required int trustRevision,
  required int credentialRevision,
  required String securitySession,
}) => sha256
    .convert(
      utf8.encode(
        jsonEncode(['conversation-route-v1', routeSignature, trustRevision, credentialRevision, securitySession]),
      ),
    )
    .toString();
