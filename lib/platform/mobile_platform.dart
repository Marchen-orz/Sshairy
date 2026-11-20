import 'package:flutter/services.dart';

import 'device_form_factor.dart';

/// Platform channel for mobile-only capabilities: keep-screen-on, Android background keep-alive foreground service,
/// on-demand notification permission, and biometric unlock (docs/MOBILE.md §2).
abstract final class MobilePlatform {
  static const _channel = MethodChannel('dev.sshairy.sshairy/mobile_platform');

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
}
