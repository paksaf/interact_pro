import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/logger.dart';
import '../../data/datasources/google_device_flow.dart';

/// TV-friendly Drive sign-in screen using OAuth 2.0 Device Flow.
///
/// Phone path: standard `google_sign_in` (Account Picker → granted).
/// TV path: this screen — shows a short user_code and a verification
/// URL. User opens the URL on their phone, types the code, grants
/// access. We poll Google's token endpoint until the grant completes.
///
/// Why a separate screen: the phone flow opens a Google-controlled
/// activity which can't run on a sideloaded Android TV app post April
/// 2024 security tightening. Device Flow sidesteps that entirely — no
/// in-app browser, no Custom Tabs, no Google Play Services dependency
/// on the receiving end.
class DriveDeviceFlowScreen extends ConsumerStatefulWidget {
  const DriveDeviceFlowScreen({super.key});

  @override
  ConsumerState<DriveDeviceFlowScreen> createState() =>
      _DriveDeviceFlowScreenState();
}

class _DriveDeviceFlowScreenState
    extends ConsumerState<DriveDeviceFlowScreen> {
  late final GoogleDeviceFlowAuth _auth;
  DeviceCodeResponse? _code;
  String? _error;
  bool _polling = false;
  bool _completed = false;
  Timer? _expiryTicker;
  int _secondsLeft = 0;

  @override
  void initState() {
    super.initState();
    _auth = GoogleDeviceFlowAuth(
      clientId: AppConstants.driveTvClientId,
      clientSecret: AppConstants.driveTvClientSecret,
      scopes: AppConstants.driveScopes,
    );
    // Auto-start the flow on screen entry so the user sees a code
    // immediately rather than having to tap a button first.
    if (AppConstants.driveTvConfigured) {
      _begin();
    }
  }

  @override
  void dispose() {
    _expiryTicker?.cancel();
    super.dispose();
  }

  Future<void> _begin() async {
    setState(() {
      _error = null;
      _code = null;
      _polling = false;
    });
    try {
      final code = await _auth.requestDeviceCode();
      if (!mounted) return;
      setState(() {
        _code = code;
        _polling = true;
        _secondsLeft = code.expiresIn;
      });
      _startExpiryCountdown(code.expiresIn);
      // Background poll. UI keeps spinning until either:
      //   - pollForToken returns → _completed = true → caller pops screen
      //   - pollForToken throws → _error set
      unawaited(_pollLoop(code));
    } on DeviceFlowException catch (e) {
      if (mounted) {
        setState(() => _error = _friendly(e));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error =
            'Could not start Drive sign-in: $e. Check your internet connection.');
      }
    }
  }

  Future<void> _pollLoop(DeviceCodeResponse code) async {
    try {
      await _auth.pollForToken(code);
      if (!mounted) return;
      setState(() {
        _completed = true;
        _polling = false;
      });
      appLogger.i('Drive Device Flow: completed, popping screen');
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) Navigator.of(context).pop(true);
    } on DeviceFlowException catch (e) {
      if (mounted) {
        setState(() {
          _error = _friendly(e);
          _polling = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Sign-in failed: $e';
          _polling = false;
        });
      }
    }
  }

  void _startExpiryCountdown(int seconds) {
    _expiryTicker?.cancel();
    _secondsLeft = seconds;
    _expiryTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        _secondsLeft = (_secondsLeft - 1).clamp(0, 1 << 30);
      });
      if (_secondsLeft <= 0) {
        t.cancel();
      }
    });
  }

  String _friendly(DeviceFlowException e) {
    switch (e.code) {
      case 'access_denied':
        return 'You declined to grant access. Tap "Try again" to start over.';
      case 'expired_token':
        return 'The sign-in code expired. Tap "Try again" to get a new one.';
      case 'device_code_request_failed':
        return 'Could not get a sign-in code. Check the TV is online '
            'and try again. If it keeps failing, the Drive OAuth setup '
            'may need attention from the admin.';
      default:
        return e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppConstants.driveTvConfigured) {
      return _UnconfiguredScreen();
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in to Google Drive')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: _body(context),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_error != null) {
      return _ErrorState(message: _error!, onRetry: _begin);
    }
    if (_completed) {
      return const _CompletedState();
    }
    final code = _code;
    if (code == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _CodeState(
      code: code,
      secondsLeft: _secondsLeft,
      polling: _polling,
    );
  }
}

class _CodeState extends StatelessWidget {
  const _CodeState({
    required this.code,
    required this.secondsLeft,
    required this.polling,
  });
  final DeviceCodeResponse code;
  final int secondsLeft;
  final bool polling;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'On your phone or laptop, visit',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 8),
        SelectableText(
          code.verificationUrl,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        Text(
          'and enter this code',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 12),
        // The code itself — big enough to read from a sofa.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: SelectableText(
            code.userCode,
            style: TextStyle(
              fontSize: 56,
              fontWeight: FontWeight.w800,
              letterSpacing: 8,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: cs.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copy code'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: code.userCode));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Code copied to clipboard'),
                duration: Duration(seconds: 1),
              ),
            );
          },
        ),
        const SizedBox(height: 36),
        if (polling) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(
                'Waiting for you to confirm on your phone…',
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Code expires in ${_fmtCountdown(secondsLeft)}',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ],
    );
  }

  static String _fmtCountdown(int seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _CompletedState extends StatelessWidget {
  const _CompletedState();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.check_circle, color: cs.primary, size: 80),
        const SizedBox(height: 20),
        Text(
          'Drive is connected',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 6),
        Text(
          'You can now upload and download PDFs to Google Drive.',
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(Icons.error_outline, color: cs.error, size: 64),
        const SizedBox(height: 16),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, height: 1.4),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
          onPressed: onRetry,
          autofocus: true,
        ),
      ],
    );
  }
}

class _UnconfiguredScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in to Google Drive')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.settings_outlined, color: cs.primary, size: 64),
                const SizedBox(height: 20),
                Text(
                  'TV Drive sign-in needs setup',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Text(
                  'Google Drive on TV requires a one-time setup by the admin '
                  '(adding a "TVs and Limited Input devices" OAuth client). '
                  'Once configured, you\'ll be able to sign in here without '
                  'leaving the TV.\n\n'
                  'For now, sign in to Drive on your phone — files uploaded '
                  'there will sync back to this TV automatically.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
