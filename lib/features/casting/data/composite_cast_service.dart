import 'dart:async';

import '../../../core/error/failures.dart';
import '../../../core/utils/result.dart';
import '../domain/cast_entities.dart';
import '../domain/cast_service.dart';

/// Wraps two or more concrete services and routes by [CastProtocol].
///
/// The viewer talks only to this — it doesn't care whether the user picked
/// AirPlay (via [SystemCastService]) or Chromecast (via
/// [ChromecastCastService]). The composite's [discover] merges device
/// streams from every backend, [startMirror] dispatches based on the
/// chosen device's protocol, and [session] / [setActivePage] /
/// [stopMirror] forward to whichever backend currently owns the active
/// session.
class CompositeCastService implements CastService {
  CompositeCastService({required Map<CastService, Set<CastProtocol>> backends})
      : _protocolMap = Map.unmodifiable(backends),
        backends = List.unmodifiable(backends.keys),
        assert(backends.isNotEmpty,
            'CompositeCastService needs at least one backend',);

  /// Iteration order is the order [CompositeCastService] was constructed
  /// with. First match wins for the rare case two backends both claim a
  /// protocol — practically there's no overlap today.
  final List<CastService> backends;
  final Map<CastService, Set<CastProtocol>> _protocolMap;

  CastService? _activeBackend;
  StreamSubscription<CastSession>? _activeSessionSub;
  final StreamController<CastSession> _sessionCtrl =
      StreamController<CastSession>.broadcast();

  // ── Discovery ─────────────────────────────────────────────────────
  // Merge all backends' device streams into one. Each backend emits its
  // current set on every update; we union them by `id` so the receiver
  // list is always coherent.

  @override
  Stream<List<CastDevice>> discover() {
    final controller = StreamController<List<CastDevice>>.broadcast();
    final latest = <int, List<CastDevice>>{};
    final subs = <StreamSubscription<dynamic>>[];

    for (var i = 0; i < backends.length; i++) {
      final idx = i;
      final sub = backends[idx].discover().listen(
            (devices) {
              latest[idx] = devices;
              controller.add(_mergeAll(latest));
            },
            onError: controller.addError,
          );
      subs.add(sub);
    }

    controller.onCancel = () async {
      for (final s in subs) {
        await s.cancel();
      }
      await controller.close();
    };
    return controller.stream;
  }

  List<CastDevice> _mergeAll(Map<int, List<CastDevice>> latest) {
    final byId = <String, CastDevice>{};
    final indices = latest.keys.toList()..sort();
    for (final i in indices) {
      for (final d in latest[i]!) {
        byId.putIfAbsent(d.id, () => d);
      }
    }
    return byId.values.toList();
  }

  // ── Session ──────────────────────────────────────────────────────

  @override
  Stream<CastSession> session() => _sessionCtrl.stream;

  // ── Routing ──────────────────────────────────────────────────────

  @override
  Future<Result<void>> startMirror({
    required CastDevice device,
    required CastContent content,
    required String pdfPath,
    required String documentTitle,
    required int currentPage,
    required int totalPages,
  }) async {
    final backend = _backendForProtocol(device.protocol);
    if (backend == null) {
      return Result.err(
          CastFailure('No backend handles ${device.protocol.name}'),);
    }

    // If a different backend was running, stop it first — only one
    // session is live at a time.
    if (_activeBackend != null && !identical(_activeBackend, backend)) {
      await _activeBackend!.stopMirror();
      await _activeSessionSub?.cancel();
      _activeSessionSub = null;
    }

    _activeBackend = backend;
    _activeSessionSub ??= backend.session().listen(_sessionCtrl.add);

    return backend.startMirror(
      device: device,
      content: content,
      pdfPath: pdfPath,
      documentTitle: documentTitle,
      currentPage: currentPage,
      totalPages: totalPages,
    );
  }

  @override
  Future<void> setActivePage(int page) async {
    final backend = _activeBackend;
    if (backend == null) return;
    await backend.setActivePage(page);
  }

  @override
  Future<void> stopMirror() async {
    final backend = _activeBackend;
    if (backend == null) return;
    await backend.stopMirror();
    await _activeSessionSub?.cancel();
    _activeSessionSub = null;
    _activeBackend = null;
  }

  @override
  Future<bool> isAvailable() async {
    for (final b in backends) {
      if (await b.isAvailable()) return true;
    }
    return false;
  }

  CastService? _backendForProtocol(CastProtocol protocol) {
    for (final b in backends) {
      if (_protocolMap[b]?.contains(protocol) ?? false) return b;
    }
    return null;
  }

  Future<void> dispose() async {
    await _activeSessionSub?.cancel();
    await _sessionCtrl.close();
  }
}
