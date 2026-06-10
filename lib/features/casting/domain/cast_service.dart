import '../../../core/utils/result.dart';
import 'cast_entities.dart';

/// Protocol-agnostic facade. The viewer talks to this; the implementation
/// chooses between AirPlay, Chromecast, DLNA, or the OS share sheet.
///
/// Why an abstract interface instead of jumping straight to a Chromecast
/// SDK: the first-cut implementation is the OS share sheet, which works
/// today on every OS without any native plumbing or paid SDK enrolment.
/// A `ChromecastCastService` plugs into the same interface later when we
/// add the Google Cast SDK + a registered receiver app id.
abstract class CastService {
  /// Start scanning for receivers. Implementations that don't do explicit
  /// discovery (the OS-share path) emit a single synthetic [CastDevice]
  /// representing the OS dialog itself, so the UI can present a uniform
  /// "pick a device" sheet.
  Stream<List<CastDevice>> discover();

  /// Stream of session state — idle / connecting / mirroring / failed.
  /// The toolbar button binds to this for its badge.
  Stream<CastSession> session();

  /// Start mirroring [content] of [pdfPath] to [device].
  ///
  /// For [CastContent.currentPage] the implementation is responsible for
  /// rendering the page to a PNG and pushing / sharing it. For
  /// [CastContent.fullDocument] the implementation hands the receiver a
  /// URL pointing at the LAN server's `/cast/page/{n}.png` endpoint and
  /// mutates [setActivePage] as the user navigates.
  Future<Result<void>> startMirror({
    required CastDevice device,
    required CastContent content,
    required String pdfPath,
    required String documentTitle,
    required int currentPage,
    required int totalPages,
  });

  /// Push a page change to a live mirroring session. No-op for the OS
  /// share path (which is one-shot) — implemented properly by the
  /// Chromecast / DLNA paths.
  Future<void> setActivePage(int page);

  /// Tear down the current session. Safe to call when idle.
  Future<void> stopMirror();

  /// True if the underlying transport is reachable on this OS — e.g. the
  /// AirPlay path is iOS-only, DLNA needs a discovery socket, etc. Used
  /// to filter the device picker so users don't see protocols that
  /// can't possibly work on their device.
  Future<bool> isAvailable();
}
