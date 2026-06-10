import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/error/failures.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';
import '../domain/cast_entities.dart';
import '../domain/cast_service.dart';
import 'pdf_page_renderer.dart';

/// First-cut cast implementation. Deliberately doesn't depend on the
/// Google Cast SDK or any other paid / heavyweight native plugin — instead
/// it leans on what every modern OS already does well:
///
///   • iOS / iPadOS: tapping "Share" → "Mirror with AirPlay" sends the
///     page image to any Apple TV / AirPlay 2-compatible TV on the LAN.
///     Apple's own UI handles discovery, auth, and the receiver protocol.
///   • Android: tapping "Share" → "Cast" surfaces every Cast-capable target
///     installed on the device (Chrome's Cast, Google Home, NetBird, etc).
///   • macOS / Windows / Linux: falls back to a plain Save / Open dialog.
///
/// What we lose by going via the share sheet: live page-by-page mirroring
/// is one-shot per share. To upgrade to a true persistent cast session,
/// drop in `flutter_chrome_cast` (or similar) behind the same
/// [CastService] interface and switch the device picker to use it. The
/// LAN server's `/cast/page/{n}.png` endpoint is already in place to
/// serve images to a real Chromecast receiver pull-style.
final systemCastServiceProvider = Provider<CastService>((ref) {
  return SystemCastService(
    renderer: ref.watch(pdfPageRendererProvider),
  );
});

class SystemCastService implements CastService {
  SystemCastService({required PdfPageRenderer renderer}) : _renderer = renderer;

  final PdfPageRenderer _renderer;

  /// Native channel — used only on iOS to invoke the AirPlay route picker
  /// directly when the user taps the "Choose AirPlay device…" affordance
  /// in our sheet. The Swift side wraps `AVRoutePickerView` and presents it
  /// over the current view controller. If the channel returns an error we
  /// silently fall back to the share sheet.
  static const _airplayChannel = MethodChannel('interact_pro/airplay');

  final StreamController<CastSession> _sessionCtrl =
      StreamController<CastSession>.broadcast();
  CastSession _current = CastSession.idle;

  void _emit(CastSession next) {
    _current = next;
    _sessionCtrl.add(next);
  }

  /// On iOS we expose two synthetic devices: "AirPlay…" (drives our native
  /// route picker) and "Share…" (drives the OS share sheet). On Android we
  /// expose a single "Cast / Share…" entry that opens the share sheet,
  /// which surfaces every Cast-capable target the user has installed.
  @override
  Stream<List<CastDevice>> discover() async* {
    final devices = <CastDevice>[];
    if (Platform.isIOS || Platform.isMacOS) {
      devices.add(const CastDevice(
        id: 'system.airplay',
        name: 'AirPlay…',
        protocol: CastProtocol.airplay,
        model: 'Apple TV / AirPlay 2 receiver',
      ),);
    }
    devices.add(const CastDevice(
      id: 'system.share',
      name: 'Share / Cast…',
      protocol: CastProtocol.systemShare,
      model: 'OS share sheet',
    ),);
    yield devices;
  }

  @override
  Stream<CastSession> session() => _sessionCtrl.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Result<void>> startMirror({
    required CastDevice device,
    required CastContent content,
    required String pdfPath,
    required String documentTitle,
    required int currentPage,
    required int totalPages,
  }) async {
    _emit(_current.copyWith(
      status: CastSessionStatus.connecting,
      device: device,
      content: content,
      documentTitle: documentTitle,
      currentPage: currentPage,
      totalPages: totalPages,
      clearError: true,
    ),);

    switch (device.protocol) {
      case CastProtocol.airplay:
        return _mirrorViaAirplay(
          pdfPath: pdfPath,
          documentTitle: documentTitle,
          page: currentPage,
        );
      case CastProtocol.systemShare:
        return _mirrorViaShareSheet(
          pdfPath: pdfPath,
          documentTitle: documentTitle,
          page: currentPage,
          content: content,
        );
      case CastProtocol.chromecast:
      case CastProtocol.dlna:
      case CastProtocol.interactPro:
        // Architecture seam — these protocols live behind sibling
        // CastService implementations (LanCastService for interactPro,
        // a real Chromecast SDK service for chromecast/dlna). The
        // composite routes by protocol so we should never actually
        // land here at runtime; this branch only exists to keep the
        // switch exhaustive when new CastProtocol values are added.
        _emit(_current.copyWith(
          status: CastSessionStatus.failed,
          errorMessage:
              '${device.protocol.name} not handled by the system cast path.',
        ),);
        return Result.err(CastFailure(
          '${device.protocol.name} requires its own service implementation.',
        ),);
    }
  }

  Future<Result<void>> _mirrorViaAirplay({
    required String pdfPath,
    required String documentTitle,
    required int page,
  }) async {
    try {
      // Try the native AirPlay route picker first. If the platform
      // channel isn't registered yet (e.g. user hasn't pulled the latest
      // iOS Runner code), fall through to the share sheet.
      try {
        await _airplayChannel.invokeMethod<void>('presentRoutePicker');
      } on MissingPluginException {
        appLogger.i('AirPlay channel not registered — falling back to share sheet');
      } on PlatformException catch (e) {
        appLogger.w('AirPlay route picker failed: ${e.message}');
      }

      // Render the current page so once the user picks a route, AirPlay
      // mirrors something visible. For full mirroring (system-level
      // screen mirror) the user uses Control Center; this path is for
      // app-level "send this page".
      final pageResult = await _renderer.renderPage(
        pdfPath: pdfPath,
        pageNumber: page,
      );
      return await pageResult.foldAsync<Result<void>>(
        (file) async {
          await SharePlus.instance.share(ShareParams(
            files: [XFile(file.path, mimeType: 'image/png')],
            subject: '$documentTitle — page $page',
          ),);
          _emit(_current.copyWith(status: CastSessionStatus.mirroring));
          return const Result.ok(null);
        },
        (failure) async {
          _emit(_current.copyWith(
            status: CastSessionStatus.failed,
            errorMessage: failure.message,
          ),);
          return Result.err(failure);
        },
      );
    } catch (e, st) {
      appLogger.e('AirPlay mirror failed', error: e, stackTrace: st);
      _emit(_current.copyWith(
        status: CastSessionStatus.failed,
        errorMessage: 'AirPlay failed: $e',
      ),);
      return Result.err(CastFailure('AirPlay mirror failed', cause: e));
    }
  }

  Future<Result<void>> _mirrorViaShareSheet({
    required String pdfPath,
    required String documentTitle,
    required int page,
    required CastContent content,
  }) async {
    try {
      switch (content) {
        case CastContent.currentPage:
          final r = await _renderer.renderPage(
            pdfPath: pdfPath,
            pageNumber: page,
          );
          return await r.foldAsync<Result<void>>(
            (file) async {
              await SharePlus.instance.share(ShareParams(
                files: [XFile(file.path, mimeType: 'image/png')],
                subject: '$documentTitle — page $page',
                text:
                    'Cast / share this page: $documentTitle (page $page of ?)',
              ),);
              _emit(_current.copyWith(status: CastSessionStatus.mirroring));
              return const Result.ok(null);
            },
            (failure) async {
              _emit(_current.copyWith(
                status: CastSessionStatus.failed,
                errorMessage: failure.message,
              ),);
              return Result.err(failure);
            },
          );
        case CastContent.fullDocument:
          // Whole-doc share: hand over the actual PDF. AirPlay can't render
          // PDFs natively, but Files / Mail / AirDrop will, and Chromecast
          // targets that handle PDFs (Chrome tab cast) work too.
          await SharePlus.instance.share(ShareParams(
            files: [XFile(pdfPath, mimeType: 'application/pdf')],
            subject: documentTitle,
          ),);
          _emit(_current.copyWith(status: CastSessionStatus.mirroring));
          return const Result.ok(null);
      }
    } catch (e, st) {
      appLogger.e('Share-sheet mirror failed', error: e, stackTrace: st);
      _emit(_current.copyWith(
        status: CastSessionStatus.failed,
        errorMessage: 'Share failed: $e',
      ),);
      return Result.err(CastFailure('Share-sheet mirror failed', cause: e));
    }
  }

  @override
  Future<void> setActivePage(int page) async {
    // Share-sheet mirroring is one-shot — there's no live session to
    // update. We still record the page so a future call to startMirror
    // resumes from where the user actually is. A real Chromecast / DLNA
    // service overrides this to push a new media URL to the receiver.
    if (!_current.isActive) return;
    _emit(_current.copyWith(currentPage: page));
  }

  @override
  Future<void> stopMirror() async {
    _emit(_current.copyWith(
      status: CastSessionStatus.disconnected,
      clearError: true,
    ),);
  }

  void dispose() {
    _sessionCtrl.close();
  }
}

/// Convenience extension so `Result.foldAsync` reads cleanly above.
/// Result.fold is sync; we want to await inside the `ok` branch.
extension _ResultAsyncFold<T> on Result<T> {
  Future<R> foldAsync<R>(
    Future<R> Function(T value) onOk,
    Future<R> Function(Failure failure) onErr,
  ) {
    // fold<Future<R>> returns the inner Future verbatim — no extra .then
    // needed. The async/sync split lives entirely in the callers.
    return fold<Future<R>>(onOk, onErr);
  }
}
