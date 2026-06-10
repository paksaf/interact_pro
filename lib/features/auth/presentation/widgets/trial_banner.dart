import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/routing/app_routes.dart';
import '../../data/auth_api_client.dart' show authRepositoryProvider;
import '../providers/auth_provider.dart';

/// Slim banner shown above the home content when the user is on a
/// trial. Three variants:
///   • Trial active, > 2 days left → friendly green
///   • Trial active, ≤ 2 days left → amber warning
///   • Trial elapsed → red, locks out cloud features until upgrade
///
/// Hidden entirely when the user is on Pro or has no trial info
/// (anonymous / not signed in).
class TrialBanner extends ConsumerWidget {
  const TrialBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authUserProvider).asData?.value;
    if (user == null) return const SizedBox.shrink();
    if (user.proActive) return const SizedBox.shrink();
    // Admin / owner accounts skip the trial banner entirely (#258 —
    // 2026-05-20). The dev/owner is running the same build as
    // customers and would otherwise see "Trial ended" on their own
    // TV. Server-side they remain admin; the banner is purely a UI
    // hint and admins don't need it.
    if (user.isAdmin) return const SizedBox.shrink();
    final days = ref.watch(trialDaysLeftProvider);
    if (days == null) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final ({Color bg, Color fg, IconData icon, String message}) variant;
    if (days < 0) {
      variant = (
        bg: cs.errorContainer,
        fg: cs.onErrorContainer,
        icon: Icons.lock_outline,
        message: 'Trial ended. Upgrade to keep cloud sync and AI features.',
      );
    } else if (days <= 2) {
      bg:
      variant = (
        bg: const Color(0xFFFFE9B6),
        fg: const Color(0xFF6B4500),
        icon: Icons.warning_amber_outlined,
        message: days == 0
            ? 'Trial ends today.'
            : '$days day${days == 1 ? '' : 's'} left in your trial.',
      );
    } else {
      variant = (
        bg: const Color(0xFFD8F3DC),
        fg: const Color(0xFF1B4332),
        icon: Icons.celebration_outlined,
        message: '$days days left in your free trial.',
      );
    }

    // Trial-expired variant gets a "Request renewal" action that
    // sends the admin a renewal request — the bridge between "trial
    // ran out" and "Play Store / App Store IAP is live". For active
    // trials we keep the original "Upgrade" CTA pointing at the
    // paywall.
    final isExpired = days < 0;

    return Container(
      width: double.infinity,
      color: variant.bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(variant.icon, color: variant.fg, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              variant.message,
              style: TextStyle(
                color: variant.fg,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (isExpired)
            TextButton(
              onPressed: () => _requestRenewal(context, ref),
              style: TextButton.styleFrom(foregroundColor: variant.fg),
              child: const Text('Ask admin'),
            ),
          TextButton(
            onPressed: () => context.pushNamed(AppRoutes.paywall),
            style: TextButton.styleFrom(foregroundColor: variant.fg),
            child: const Text('Upgrade'),
          ),
        ],
      ),
    );
  }

  /// Pop a small dialog asking for an optional note, then POST to
  /// `/api/auth/renewal/request`. Result is surfaced as a snackbar —
  /// success or the typed server message ("admin not enabled",
  /// "already pending", etc.).
  Future<void> _requestRenewal(BuildContext context, WidgetRef ref) async {
    final note = await showDialog<String?>(
      context: context,
      builder: (ctx) => const _RenewalRequestDialog(),
    );
    if (note == null) return; // cancelled
    if (!context.mounted) return;

    final res =
        await ref.read(authRepositoryProvider).requestRenewal(note: note);
    if (!context.mounted) return;
    res.fold(
      (_) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Renewal request sent. You\'ll get an email + push when '
              'the admin decides.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
      },
      (failure) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(failure.message),
            duration: const Duration(seconds: 6),
          ),
        );
      },
    );
  }
}

/// Renewal-request dialog as a stateful widget so we can own three
/// FocusNodes (text, cancel, send) and wire the D-pad arrows through
/// them.
///
/// The bug being fixed:
///   • On Android TV the multi-line TextField swallows arrowDown/Tab as
///     a "move cursor down" gesture even when the cursor is already on
///     the last line. The user is then trapped in the input — there's no
///     way to reach Cancel/Send with the remote.
///   • Standard TextButton/FilledButton don't render any focus
///     decoration of their own. On TV the user sees the focus halo flicker
///     for ~30 ms (the Material default) but nothing persistent — so even
///     when focus DID land on a button the user couldn't tell.
///
/// Fix: a `FocusNode` per actor + `onKeyEvent` on the TextField's node
/// that catches arrowDown/arrowRight/tab and forwards to `_sendBtnFocus`.
/// The buttons themselves are wrapped in `_FocusableActionButton` which
/// paints a cyan ring + 1.04× scale when focused — the same pattern the
/// Pro home tiles use so the visual language is consistent across the
/// app.
class _RenewalRequestDialog extends StatefulWidget {
  const _RenewalRequestDialog();
  @override
  State<_RenewalRequestDialog> createState() => _RenewalRequestDialogState();
}

class _RenewalRequestDialogState extends State<_RenewalRequestDialog> {
  final _controller = TextEditingController();
  late final FocusNode _inputFocus;
  late final FocusNode _cancelFocus;
  late final FocusNode _sendFocus;

  @override
  void initState() {
    super.initState();
    _inputFocus = FocusNode(
      debugLabel: 'renewal_input',
      onKeyEvent: _onInputKey,
    );
    _cancelFocus = FocusNode(debugLabel: 'renewal_cancel');
    _sendFocus = FocusNode(debugLabel: 'renewal_send');
  }

  @override
  void dispose() {
    _controller.dispose();
    _inputFocus.dispose();
    _cancelFocus.dispose();
    _sendFocus.dispose();
    super.dispose();
  }

  /// D-pad escape: arrowDown / arrowRight / Tab moves focus OUT of the
  /// multi-line TextField to the Send button. Without this the field
  /// eats those keys as caret motion and the user can't reach the action
  /// row.
  ///
  /// We deliberately do NOT intercept arrowUp / arrowLeft — they still
  /// move the caret inside the field, which is the right behaviour.
  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.tab) {
      _sendFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Request trial renewal'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'The admin will be notified and can extend your trial. '
            'Add a short note if you want (optional).',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            focusNode: _inputFocus,
            maxLines: 3,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _sendFocus.requestFocus(),
            decoration: const InputDecoration(
              hintText: 'e.g. "Need it for Q3 audit work"',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        _FocusableActionButton(
          focusNode: _cancelFocus,
          onTap: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        _FocusableActionButton(
          focusNode: _sendFocus,
          primary: true,
          // Auto-land on Send when the dialog first opens — gives the
          // TV remote a sensible target even before the user types
          // anything (the note is optional).
          autofocus: true,
          onTap: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Send request'),
        ),
      ],
    );
  }
}

/// Button with a cyan focus ring + scale-up so TV remote users can see
/// which action is selected. Mirrors the `_FocusableTile` pattern used
/// on the Pro home shortcut tiles — same visual vocabulary across the
/// app.
///
/// The `FocusableActionDetector` binds the standard D-pad OK keys
/// (select / enter / numpadEnter / space / gameButtonA) to
/// `ActivateIntent` → onTap, so Bravia / Fire TV / NVIDIA Shield
/// remotes all just work without per-platform key plumbing.
class _FocusableActionButton extends StatefulWidget {
  const _FocusableActionButton({
    required this.focusNode,
    required this.onTap,
    required this.child,
    this.primary = false,
    this.autofocus = false,
  });

  final FocusNode focusNode;
  final VoidCallback onTap;
  final Widget child;
  final bool primary;
  final bool autofocus;

  @override
  State<_FocusableActionButton> createState() =>
      _FocusableActionButtonState();
}

class _FocusableActionButtonState extends State<_FocusableActionButton> {
  bool _focused = false;

  static final _activateShortcuts = <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ringColor = _focused ? const Color(0xFF22D3EE) : Colors.transparent;
    final inner = widget.primary
        ? FilledButton(
            focusNode: widget.focusNode,
            onPressed: widget.onTap,
            child: widget.child,
          )
        : TextButton(
            focusNode: widget.focusNode,
            onPressed: widget.onTap,
            child: widget.child,
          );

    return FocusableActionDetector(
      autofocus: widget.autofocus,
      focusNode: null, // child button owns its own FocusNode
      onShowFocusHighlight: (v) {
        if (mounted) setState(() => _focused = v);
      },
      shortcuts: _activateShortcuts,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: AnimatedScale(
        scale: _focused ? 1.04 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ringColor, width: 2),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: ringColor.withValues(alpha: 0.5),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : const [],
          ),
          padding: const EdgeInsets.all(2),
          child: inner,
        ),
      ),
    );
  }
}
