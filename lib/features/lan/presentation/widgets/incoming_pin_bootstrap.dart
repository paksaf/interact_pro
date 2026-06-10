// SPDX-License-Identifier: AGPL-3.0
//
// IncomingPinBootstrap — mount once near the router root. Listens on
// `incomingPinChallengesProvider` (fed by LanServer's POST /pair/init
// handler) and pops a PIN dialog whenever another Pro instance starts a
// pair handshake against us.
//
// IMPORTANT: this widget renders the dialog INLINE via a Stack overlay
// rather than calling showDialog(). showDialog() depends on a Navigator
// ancestor, and our mount point is INSIDE MaterialApp.router's `builder`
// callback — which is OUTSIDE the GoRouter Navigator. A showDialog call
// from this context can't find a Navigator and silently no-ops.
// Stacking the dialog directly in the widget tree avoids that whole
// class of problem and renders above any route content.
//
// Lifecycle: a challenge enters state when a stream event arrives,
// stays visible until either (a) the user dismisses with the Done
// button, or (b) 60s elapses and the server-side _pendingPairs entry is
// evicted (we mirror the same expiry via the per-challenge timer).
//
// Parallel to `IncomingCastBootstrap` for cast events. The two
// listeners are independent — pair handshakes can occur during an
// active cast.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/logger.dart';
import '../../data/lan_repository.dart'
    show IncomingPinChallenge, incomingPinChallengesProvider;

class IncomingPinBootstrap extends ConsumerStatefulWidget {
  const IncomingPinBootstrap({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<IncomingPinBootstrap> createState() =>
      _IncomingPinBootstrapState();
}

class _IncomingPinBootstrapState extends ConsumerState<IncomingPinBootstrap> {
  ProviderSubscription<AsyncValue<IncomingPinChallenge>>? _sub;
  IncomingPinChallenge? _current;
  Timer? _expiryWatchdog;

  @override
  void initState() {
    super.initState();
    appLogger.i('IncomingPinBootstrap: mounted, listening for PIN challenges');
    _sub = ref.listenManual<AsyncValue<IncomingPinChallenge>>(
      incomingPinChallengesProvider,
      (prev, next) {
        next.whenData(_onChallenge);
      },
      // fireImmediately: subscribe even if no value yet, so the
      // underlying broadcast stream gets its listener as soon as we
      // mount.
      fireImmediately: true,
    );
  }

  void _onChallenge(IncomingPinChallenge c) {
    appLogger.i(
      'IncomingPin: ${c.fromDeviceName} (${c.fromPlatform}) — PIN ${c.pin}, '
      '${c.remaining.inSeconds}s remaining',
    );
    if (!mounted) return;
    setState(() => _current = c);
    _expiryWatchdog?.cancel();
    _expiryWatchdog = Timer(c.remaining, () {
      if (!mounted) return;
      if (_current?.pin == c.pin) {
        setState(() => _current = null);
      }
    });
  }

  void _dismiss() {
    _expiryWatchdog?.cancel();
    if (mounted) setState(() => _current = null);
  }

  @override
  void dispose() {
    _expiryWatchdog?.cancel();
    _sub?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _current;
    // No active challenge — just pass the child through, zero overhead.
    if (c == null) return widget.child;
    // Active challenge — overlay the dialog on top of the routed
    // content. Material wrapper provides the ink/material lookup the
    // inner Text/Button widgets need.
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: Material(
            color: Colors.black.withValues(alpha: 0.65),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: _PinPanel(
                  challenge: c,
                  onClose: _dismiss,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The visible PIN card. Stateful so the countdown ticks every second
/// and the panel rebuilds with the new remaining-time label.
class _PinPanel extends StatefulWidget {
  const _PinPanel({required this.challenge, required this.onClose});
  final IncomingPinChallenge challenge;
  final VoidCallback onClose;

  @override
  State<_PinPanel> createState() => _PinPanelState();
}

class _PinPanelState extends State<_PinPanel> {
  Timer? _tick;
  late Duration _remaining;

  @override
  void initState() {
    super.initState();
    _remaining = widget.challenge.remaining;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remaining = widget.challenge.remaining);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = widget.challenge;
    return Card(
      margin: const EdgeInsets.all(24),
      elevation: 24,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 40, color: cs.primary),
            const SizedBox(height: 8),
            Text(
              'Pair request',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
            Text(
              '${c.fromDeviceName} is asking to pair with this device.\n'
              'Type this PIN on ${c.fromDeviceName}:',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            // Big readable PIN. 56pt + 12 letter-spacing so the digits
            // don't crowd — important on TV where the user is 6+ feet
            // away from the panel.
            Text(
              c.pin,
              style: TextStyle(
                fontSize: 56,
                fontWeight: FontWeight.w800,
                letterSpacing: 12,
                fontFamily: 'monospace',
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Expires in ${_remaining.inSeconds}s',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            // FocusableActionDetector binds D-pad OK / Enter / Numpad-Enter
            // / Space / GameButtonA → ActivateIntent → onClose, so any TV
            // remote can dismiss the panel. Without these explicit
            // shortcuts the FilledButton only respects taps (touch
            // only), not the remote's central button.
            SizedBox(
              width: double.infinity,
              child: FocusableActionDetector(
                autofocus: true,
                shortcuts: const <ShortcutActivator, Intent>{
                  SingleActivator(LogicalKeyboardKey.select):
                      ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.numpadEnter):
                      ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.gameButtonA):
                      ActivateIntent(),
                },
                actions: <Type, Action<Intent>>{
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      widget.onClose();
                      return null;
                    },
                  ),
                },
                child: FilledButton(
                  onPressed: widget.onClose,
                  child: const Text('Done'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
