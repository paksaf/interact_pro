// SPDX-License-Identifier: AGPL-3.0
//
// IncomingCastBootstrap — mount once near the router root. Listens on
// `incomingCastsProvider` (fed by LanServer's POST /cast/start handler)
// and pushes a `CastReceiverScreen` whenever another Interact Pro
// instance starts casting TO us.
//
// Parallel to `IncomingFileBootstrap` (which handles SEND-style file
// drops). Kept separate so:
//   • the file flow remains tightly scoped to disk-write + viewer
//     routing (kind=pdf/image/video/text);
//   • cast events bypass the file system entirely — they're transient
//     "show this page right now" signals, not durable share targets.
//
// Re-entrancy: we guard against a second /cast/start firing while a
// receiver screen is already mounted from the same sender. The second
// event is treated as an update to the existing session rather than
// pushing a new route. Different senders DO get a fresh push (last-one-
// wins — the new sender pre-empts the previous receiver screen).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/routing/app_routes.dart';
import '../../../../core/utils/logger.dart';
import '../../../lan/data/lan_repository.dart' show incomingCastsProvider;
import '../../../lan/domain/entities.dart' show IncomingCast;

class IncomingCastBootstrap extends ConsumerStatefulWidget {
  const IncomingCastBootstrap({
    required this.router,
    required this.child,
    super.key,
  });

  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<IncomingCastBootstrap> createState() =>
      _IncomingCastBootstrapState();
}

class _IncomingCastBootstrapState
    extends ConsumerState<IncomingCastBootstrap> {
  ProviderSubscription<AsyncValue<IncomingCast>>? _sub;

  /// senderDeviceId of the currently-displayed cast, if any. Used to
  /// dedupe re-fired /cast/start events from the same sender.
  String? _activeSenderId;

  @override
  void initState() {
    super.initState();
    _sub = ref.listenManual<AsyncValue<IncomingCast>>(
      incomingCastsProvider,
      (prev, next) {
        next.whenData(_onIncomingCast);
      },
    );
  }

  void _onIncomingCast(IncomingCast cast) {
    appLogger.i(
      'IncomingCast: ${cast.senderName} → us — '
      'doc="${cast.documentTitle}", page ${cast.currentPage} of '
      '${cast.totalPages}, sender ${cast.senderHost}:${cast.senderPort}',
    );

    // Dedupe: same sender re-fired (e.g. they tapped Cast again without
    // stopping the previous session). Ignore — the existing screen
    // listens for /cast/page-changed and will catch up on its own.
    if (cast.senderDeviceId == _activeSenderId) {
      appLogger.i('IncomingCast: duplicate from same sender — ignoring');
      return;
    }

    // Different sender: pop any existing receiver screen and push fresh.
    // We rely on the fact that the CastReceiverScreen route's name is
    // unique so router.routerDelegate.currentConfiguration matches it.
    _activeSenderId = cast.senderDeviceId;
    widget.router.pushNamed(
      AppRoutes.castReceiver,
      extra: cast,
    );
  }

  @override
  void dispose() {
    _sub?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
