import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/failures.dart';
import '../../../core/utils/result.dart';
import '../domain/cast_entities.dart';
import '../domain/cast_service.dart';

/// **STUB.** The real `flutter_chrome_cast` SDK binding is currently
/// disabled in `pubspec.yaml` because its 0.0.x API surface varies
/// between point releases and we couldn't pin to one we'd verified
/// without a real device test.
///
/// All Chromecast-protocol traffic is therefore routed through
/// [SystemCastService] (the OS share sheet — which on Android still
/// surfaces every installed Cast target, and on iOS surfaces AirPlay).
/// The composite cast service in
/// `lib/features/casting/presentation/providers/cast_provider.dart`
/// no longer registers this stub, so it's effectively dormant code
/// kept here only as a re-enable starting point.
///
/// To re-enable:
///   1. Uncomment `flutter_chrome_cast` in pubspec.yaml + `flutter pub get`.
///   2. Replace the stub methods below with calls to the real SDK
///      symbols (verify their names by inspecting
///      `~/.pub-cache/hosted/pub.dev/flutter_chrome_cast-<version>/lib/`).
///   3. Add `CastProtocol.chromecast` back to the composite in
///      cast_provider.dart.
final chromecastCastServiceProvider = Provider<CastService>((ref) {
  return _ChromecastDisabled();
});

class _ChromecastDisabled implements CastService {
  @override
  Stream<List<CastDevice>> discover() async* {
    yield const [];
  }

  @override
  Stream<CastSession> session() async* {
    yield CastSession.idle;
  }

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<Result<void>> startMirror({
    required CastDevice device,
    required CastContent content,
    required String pdfPath,
    required String documentTitle,
    required int currentPage,
    required int totalPages,
  }) async {
    return const Result.err(CastFailure(
        'Chromecast SDK is disabled in this build. Use AirPlay or the Share menu.',),);
  }

  @override
  Future<void> setActivePage(int page) async {}

  @override
  Future<void> stopMirror() async {}
}
