import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/layout/responsive.dart';
import '../../../../core/routing/app_routes.dart';
import '../../../../l10n/app_localizations.dart';
import '../../data/auth_api_client.dart';
import '../providers/auth_provider.dart';

/// Single login screen with two tabs (email / phone). Both flows are OTP
/// — no password — so the UX is symmetric.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _tabs.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    final email = _tabs.index == 0 ? _emailController.text.trim() : null;
    final phone = _tabs.index == 1 ? _phoneController.text.trim() : null;
    if ((email == null || email.isEmpty) &&
        (phone == null || phone.isEmpty)) {
      setState(() => _error = AppLocalizations.of(context).loginErrorEmptyContact);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final repo = ref.read(authRepositoryProvider);
    final r = await repo.requestOtp(email: email, phone: phone);
    if (!mounted) return;
    r.fold(
      (_) {
        setState(() => _busy = false);
        context.pushNamed(
          AppRoutes.otp,
          extra: _OtpExtra(email: email, phone: phone),
        );
      },
      (failure) => setState(() {
        _busy = false;
        _error = failure.message;
      }),
    );
  }

  Future<void> _signOutAndStay() async {
    setState(() => _busy = true);
    try {
      await ref.read(authRepositoryProvider).signOut();
      // Reset whatever's typed in the inputs so the user starts fresh.
      _emailController.clear();
      _phoneController.clear();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).loginSignedOutNotice)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);
    // If a session is already loaded (cached from a previous run, or the
    // user navigated here from the home screen on purpose), show a small
    // "currently signed in as X — sign out" affordance at the top so they
    // aren't stuck. Without this, hitting /login while already signed in
    // is a dead-end UX-wise.
    final currentUser = ref.watch(authUserProvider).valueOrNull;

    return Scaffold(
      body: SafeArea(
        child: LandscapeFormBody(
          maxWidth: 520,
          child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              if (currentUser != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.account_circle, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l.loginAlreadySignedIn,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              currentUser.email ?? currentUser.phone ?? currentUser.id,
                              style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontSize: 12,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _busy ? null : _signOutAndStay,
                        icon: const Icon(Icons.logout, size: 18),
                        label: Text(l.actionSignOut),
                      ),
                      TextButton.icon(
                        onPressed: () => context.goNamed(AppRoutes.home),
                        icon: const Icon(Icons.home_outlined, size: 18),
                        label: Text(l.actionHome),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(l.loginWelcome,
                  style: Theme.of(context).textTheme.headlineSmall,),
              const SizedBox(height: 4),
              Text(
                l.loginWelcomeBlurb,
                style: TextStyle(color: cs.outline),
              ),
              const SizedBox(height: 32),
              TabBar(
                controller: _tabs,
                tabs: [
                  Tab(icon: const Icon(Icons.email_outlined), text: l.loginTabEmail),
                  Tab(icon: const Icon(Icons.phone_outlined), text: l.loginTabPhone),
                ],
              ),
              SizedBox(
                height: 120,
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: TextField(
                        controller: _emailController,
                        autofocus: true,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: InputDecoration(
                          labelText: l.loginEmailLabel,
                          prefixIcon: const Icon(Icons.email_outlined),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: TextField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[\d\s\+\-\(\)]'),),
                        ],
                        decoration: InputDecoration(
                          labelText: l.loginPhoneLabel,
                          hintText: l.loginPhoneHint,
                          prefixIcon: const Icon(Icons.phone_outlined),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: cs.error)),
                ),
              FilledButton.icon(
                onPressed: _busy ? null : _send,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),)
                    : const Icon(Icons.send),
                // Autofocus the Send button so TV D-pad has a focused
                // target after the email field receives an autocomplete /
                // paste from the remote keyboard. Email field gets the
                // initial focus via its own `autofocus: true` above.
                autofocus: false,
                label: Text(_busy ? l.actionSending : l.actionSendCode),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => context.goNamed(AppRoutes.home),
                child: Text(l.actionContinueWithoutAccount),
              ),
              const Spacer(),
              Text(
                l.loginTrialBlurb,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: cs.outline),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _OtpExtra {
  const _OtpExtra({this.email, this.phone});
  final String? email;
  final String? phone;
}

/// Used by the OTP screen — the route extra is this class so we don't
/// have to round-trip the contact through query params.
class OtpExtra {
  const OtpExtra({this.email, this.phone});
  final String? email;
  final String? phone;

  factory OtpExtra.from(Object? extra) {
    if (extra is _OtpExtra) {
      return OtpExtra(email: extra.email, phone: extra.phone);
    }
    if (extra is OtpExtra) return extra;
    return const OtpExtra();
  }
}
