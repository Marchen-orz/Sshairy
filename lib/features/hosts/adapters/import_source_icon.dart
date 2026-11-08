import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../domain/host_import.dart';

/// Local, independently drawn source marks; the tile provides the accessible software name.
class ImportSourceIcon extends StatelessWidget {
  const ImportSourceIcon(this.format, {super.key});

  final ImportFormat format;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.asset('assets/import_sources/${format.name}.svg', width: 28, height: 28, excludeFromSemantics: true);
}
