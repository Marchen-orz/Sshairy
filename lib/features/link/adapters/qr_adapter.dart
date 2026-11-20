import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../design/theme.dart';

/// Renders a crisp pairing QR code on Desktop (Rule 3: isolates qr_flutter inside adapters/).
class LinkQrCodeView extends StatelessWidget {
  const LinkQrCodeView({super.key, required this.data, this.size = 164});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .4)),
      ),
      child: QrImageView(
        data: data,
        version: QrVersions.auto,
        size: size,
        gapless: true,
        eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF0B1220)),
        dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF0B1220)),
      ),
    );
  }
}

/// Full-screen camera QR scanner for pairing Mobile with Desktop (Rule 3: isolates mobile_scanner inside adapters/).
/// Requests CAMERA permission strictly when opened; callers fall back gracefully if user cancels or denies.
class LinkQrScannerPage extends StatefulWidget {
  const LinkQrScannerPage({super.key, required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  State<LinkQrScannerPage> createState() => _LinkQrScannerPageState();
}

class _LinkQrScannerPageState extends State<LinkQrScannerPage> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    formats: const [BarcodeFormat.qrCode],
  );
  var _handled = false;
  var _torch = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim();
      if (raw != null && raw.startsWith('sshairy-link://')) {
        _handled = true;
        Navigator.of(context).pop<String>(raw);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: .45),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: () async {
              await _controller.toggleTorch();
              if (mounted) setState(() => _torch = !_torch);
            },
            icon: Icon(_torch ? Icons.flash_on : Icons.flash_off),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 248,
                height: 248,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: scheme.primary, width: 3),
                ),
              ),
            ),
          ),
          Positioned(
            left: Space.xl,
            right: Space.xl,
            bottom: 48,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .62),
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Text(
                  widget.hint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
