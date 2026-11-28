import 'package:flutter/services.dart';

import 'device_form_factor.dart';

enum MobileUpdateInstallResult { opened, permission, failed }

/// Platform channel for mobile-only capabilities: keep-screen-on, Android background keep-alive foreground service,
/// on-demand notification permission, and biometric unlock (docs/MOBILE.md §2).
abstract final class MobilePlatform {
  static const _channel = MethodChannel('dev.sshairy.sshairy/mobile_platform');

  static Future<List<String>> updateAbis() async {
    if (!isAndroidPlatform) return const [];
    try {
      return await _channel.invokeListMethod<String>('updateAbis') ?? const [];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  static Future<MobileUpdateInstallResult> installUpdate(String path, String version) async {
    if (!isAndroidPlatform) return MobileUpdateInstallResult.failed;
    try {
      final result = await _channel.invokeMethod<String>('installUpdate', {'path': path, 'version': version});
      return MobileUpdateInstallResult.values.asNameMap()[result] ?? MobileUpdateInstallResult.failed;
    } on PlatformException {
      return MobileUpdateInstallResult.failed;
    } on MissingPluginException {
      return MobileUpdateInstallResult.failed;
    }
  }

  static Future<void> setKeepScreenOn(bool on) async {
    if (!isMobilePlatform) return;
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', {'on': on});
    } on PlatformException {
      // Safe no-op when channel is unavailable (tests or unsupported host).
    } on MissingPluginException {
      // Safe no-op in widget tests.
    }
  }

  static Future<bool> startKeepAlive({required String title, required String subtitle}) async {
    if (!isMobilePlatform) return false;
    try {
      return await _channel.invokeMethod<bool>('startKeepAlive', {'title': title, 'subtitle': subtitle}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> stopKeepAlive() async {
    if (!isMobilePlatform) return;
    try {
      await _channel.invokeMethod<void>('stopKeepAlive');
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }

  static Future<bool> requestNotificationPermission() async {
    if (!isMobilePlatform) return false;
    try {
      return await _channel.invokeMethod<bool>('requestNotificationPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> canAuthenticateBiometric() async {
    if (!isMobilePlatform) return false;
    try {
      return await _channel.invokeMethod<bool>('canAuthenticateBiometric') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> authenticateBiometric({required String title, String subtitle = ''}) async {
    if (!isMobilePlatform) return true;
    try {
      return await _channel.invokeMethod<bool>('authenticateBiometric', {'title': title, 'subtitle': subtitle}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Android's primary shared storage, when the user has granted access.
  static Future<String?> sharedStoragePath() async {
    if (!isAndroidPlatform) return null;
    try {
      return await _channel.invokeMethod<String>('sharedStoragePath');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> openUrl(String url) async {
    if (!isAndroidPlatform) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('openUrl', {'url': uri.toString()}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the Android system "All files access" toggle (API 30+) or requests legacy storage permission.
  static Future<bool> requestAllFilesAccess() async {
    if (!isAndroidPlatform) return true;
    try {
      return await _channel.invokeMethod<bool>('requestAllFilesAccess') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
