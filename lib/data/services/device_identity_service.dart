import 'dart:convert';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'sensitive_store.dart';

/// What this installation calls itself when it registers a session.
///
/// [deviceId] is the only field the server trusts for identity. Everything else
/// is a label shown back to the user in "Where you're logged in", so a wrong or
/// missing value degrades the copy and nothing else.
@immutable
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    this.deviceName,
    this.deviceType = 'unknown',
    this.osName,
    this.osVersion,
    this.appVersion,
  });

  final String deviceId;
  final String? deviceName;
  final String deviceType;
  final String? osName;
  final String? osVersion;
  final String? appVersion;
}

/// Gives this installation a stable identity that survives app restarts.
///
/// The id is random and generated on device. It is deliberately not derived
/// from a hardware identifier: those are either unavailable (iOS), resettable
/// (Android ad id), or a privacy problem in an app whose whole premise is
/// anonymity. A random value in the keystore identifies the *installation*,
/// which is the only thing session management actually needs.
///
/// It lives in [SensitiveStore] rather than shared preferences so that it is
/// not readable by a backup extractor, and so uninstalling genuinely retires
/// the device instead of resurrecting it on reinstall.
class DeviceIdentityService {
  DeviceIdentityService({
    SensitiveStore? store,
    DeviceInfoPlugin? deviceInfo,
    Random? random,
  }) : _store = store ?? DeviceSensitiveStore(),
       _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
       _random = random ?? Random.secure();

  static const String _storageKey = 'venttly.device_id.v1';

  final SensitiveStore _store;
  final DeviceInfoPlugin _deviceInfo;
  final Random _random;

  DeviceIdentity? _cached;

  /// Read once per process; the keystore round-trip is not free and the answer
  /// cannot change while the app is running.
  Future<DeviceIdentity> read() async {
    final cached = _cached;
    if (cached != null) return cached;

    final identity = DeviceIdentity(
      deviceId: await _readOrCreateId(),
      deviceName: await _describeDevice(),
      deviceType: _deviceType(),
      osName: _osName(),
      osVersion: await _osVersion(),
      appVersion: await _appVersion(),
    );
    _cached = identity;
    return identity;
  }

  Future<String> _readOrCreateId() async {
    try {
      final existing = await _store.read(_storageKey);
      if (existing != null && existing.length >= 8) return existing;
    } catch (_) {
      // A keystore that cannot be read yields an ephemeral id below. The user
      // sees an extra device rather than a failed sign-in.
    }

    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    final id = base64Url.encode(bytes).replaceAll('=', '');

    try {
      await _store.write(_storageKey, id);
    } catch (_) {
      // Unwritable keystore: this session still registers, it just will not be
      // recognised as the same device next launch.
    }
    return id;
  }

  String _deviceType() {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => 'phone',
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => 'desktop',
      _ => 'unknown',
    };
  }

  String? _osName() {
    if (kIsWeb) return 'Web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.linux => 'Linux',
      _ => null,
    };
  }

  /// The model name, because a list of three rows all reading "Android device"
  /// tells the user nothing about which one to revoke.
  Future<String?> _describeDevice() async {
    try {
      if (kIsWeb) {
        final info = await _deviceInfo.webBrowserInfo;
        return info.browserName.name;
      }
      return switch (defaultTargetPlatform) {
        TargetPlatform.android => (await _deviceInfo.androidInfo).model,
        TargetPlatform.iOS => (await _deviceInfo.iosInfo).utsname.machine,
        TargetPlatform.macOS => (await _deviceInfo.macOsInfo).model,
        TargetPlatform.windows => (await _deviceInfo.windowsInfo).computerName,
        TargetPlatform.linux => (await _deviceInfo.linuxInfo).prettyName,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Future<String?> _osVersion() async {
    try {
      if (kIsWeb) return null;
      return switch (defaultTargetPlatform) {
        TargetPlatform.android =>
          (await _deviceInfo.androidInfo).version.release,
        TargetPlatform.iOS => (await _deviceInfo.iosInfo).systemVersion,
        TargetPlatform.macOS => (await _deviceInfo.macOsInfo).osRelease,
        TargetPlatform.windows =>
          (await _deviceInfo.windowsInfo).displayVersion,
        TargetPlatform.linux => (await _deviceInfo.linuxInfo).version,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Future<String?> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  void resetCache() => _cached = null;
}
