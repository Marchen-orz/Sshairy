import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../storage.dart';

/// Local, independently drawn client marks; the tile provides the accessible client name.
class McpClientIcon extends StatelessWidget {
  const McpClientIcon(this.client, {super.key});

  final McpClient client;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.asset('assets/mcp_clients/${client.name}.svg', width: 24, height: 24, excludeFromSemantics: true);
}
