import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/responsive.dart';
import '../../../../core/routing/app_routes.dart';
import '../../data/auth_api_client.dart';
import 'login_screen.dart' show OtpExtra;

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({required this.contact, super.key});
  final OtpExtra contact;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final _otpController = TextEditingController();
  bool _busy = false;
  String? _error;

  String get _displayContact =>
      widget.contact.email ?? widget.contact.phone ?? '';

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_busy) return;
    final otp = _otpController.text.trim();
    if (otp.length < 4) {
      setState(() => _error = 'Enter the code from your email / SMS');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(authRepositoryProvider);
    final r = await repo.verifyOtp(
      email: widget.contact.email,
      phone: widget.contact.phone,
      otp: otp,
    );
    if (!mounted) return;
    r.fold(
      (_) {
        setState(() => _busy = false);
        context.goNamed(AppRoutes.home);
      },
      (failure) => setState(() {
        _busy = false;
        _error = failure.message;
      }),
    );
  }

  Future<void> _resend() async {
    final repo = ref.read(authRepositoryProvider);
    final r = await repo.requestOtp(
      email: widget.contact.email,
      phone: widget.contact.phone,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    r.fold(
      (_) => messenger.showSnackBar(
        const SnackBar(content: Text('New code sent')),
      ),
      (failure) => messenger.showSnackBar(
        SnackBar(content: Text(failure.message)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: LandscapeFormBody(
          maxWidth: 520,
          child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Enter your code',
                  style: Theme.of(context).textTheme.headlineSmall,),
              const SizedBox(height: 4),
              Text(
                'We sent a 6-digit code to $_displayContact.',
                style: TextStyle(color: cs.outline),
              ),
              const SizedBox(height: 32),
              TextField(
                controller: _otpController,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(
                  fontSize: 28,
                  letterSpacing: 12,
                  fontWeight: FontWeight.w600,
                ),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                onSubmitted: (_) => _verify(),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: cs.error)),
                ),
              FilledButton.icon(
                onPressed: _busy ? null : _verify,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),)
                    : const Icon(Icons.check),
                label: Text(_busy ? 'Verifying…' : 'Verify and continue'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _resend,
                child: const Text('Resend code'),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
