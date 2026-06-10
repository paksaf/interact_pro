import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/logger.dart';
import '../../auth/data/auth_api_client.dart';
import '../domain/iap_products.dart';
import '../domain/pro_entitlement.dart';

final proRepositoryProvider = Provider<ProRepository>((Ref ref) {
  final repo = ProRepositoryImpl(
    InAppPurchase.instance,
    ref.watch(authApiClientProvider),
  );
  ref.onDispose(repo.dispose);
  return repo;
});

abstract class ProRepository {
  Future<ProSubscription> currentSubscription();

  /// Stream of subscription updates fired when purchases / restores complete
  /// or when a trial starts / expires.
  Stream<ProSubscription> watchSubscription();

  Future<List<ProductDetails>> loadProducts();

  Future<bool> purchase(String productId);

  Future<void> restore();

  /// Starts the one-time free trial. Returns the resulting subscription
  /// state, or the existing one if the user already used / is in their
  /// trial. Trial length is fixed at [ProRepositoryImpl.trialDuration].
  Future<ProSubscription> startTrial();

  /// True iff the trial has been used (regardless of whether it's still
  /// active). Used to hide the "Start trial" CTA after consumption.
  Future<bool> hasTrialBeenUsed();
}

class ProRepositoryImpl implements ProRepository {
  ProRepositoryImpl(this._iap, this._auth, {http.Client? httpClient})
      : _http = httpClient ?? http.Client() {
    _sub = _iap.purchaseStream.listen(
      _onPurchaseUpdates,
      onDone: () => _sub?.cancel(),
      onError: (Object e) => appLogger.w('IAP stream error: $e'),
    );
  }

  /// One-time free trial length. Tweak from a single place.
  static const Duration trialDuration = Duration(days: 7);

  static const _kSubKey = 'pro.subscription_state';
  static const _kProductIdKey = 'pro.product_id';
  static const _kTrialStartKey = 'pro.trial_started_at';
  static const _kTrialUsedKey = 'pro.trial_used';

  final InAppPurchase _iap;
  final AuthApiClient _auth;
  final http.Client _http;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final _ctrl = StreamController<ProSubscription>.broadcast();

  @override
  Future<ProSubscription> currentSubscription() async {
    final prefs = await SharedPreferences.getInstance();

    // Paid takes priority over trial.
    final paid = prefs.getBool(_kSubKey) ?? false;
    if (paid) {
      return ProSubscription.paid(
        productId: prefs.getString(_kProductIdKey) ?? 'unknown',
      );
    }

    // Active trial?
    final trialStartIso = prefs.getString(_kTrialStartKey);
    if (trialStartIso != null) {
      final start = DateTime.tryParse(trialStartIso);
      if (start != null) {
        final endsAt = start.add(trialDuration);
        if (endsAt.isAfter(DateTime.now())) {
          return ProSubscription.trial(endsAt);
        }
        // Trial expired — mark used and fall through to free.
        await prefs.setBool(_kTrialUsedKey, true);
      }
    }

    return ProSubscription.free;
  }

  @override
  Stream<ProSubscription> watchSubscription() => _ctrl.stream;

  @override
  Future<List<ProductDetails>> loadProducts() async {
    if (!await _iap.isAvailable()) return const [];
    final response = await _iap.queryProductDetails(IapProducts.all);
    if (response.error != null) {
      appLogger.w('queryProductDetails error: ${response.error}');
    }
    return response.productDetails;
  }

  @override
  Future<bool> purchase(String productId) async {
    final response = await _iap.queryProductDetails({productId});
    if (response.productDetails.isEmpty) return false;
    final product = response.productDetails.first;
    final param = PurchaseParam(productDetails: product);
    return _iap.buyNonConsumable(purchaseParam: param);
  }

  @override
  Future<void> restore() => _iap.restorePurchases();

  @override
  Future<bool> hasTrialBeenUsed() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kTrialUsedKey) ?? false) return true;
    // Treat any past trial start as "used" even if the flag wasn't written.
    return prefs.getString(_kTrialStartKey) != null;
  }

  @override
  Future<ProSubscription> startTrial() async {
    final current = await currentSubscription();
    if (current.isPaid || current.isTrial) return current;

    if (await hasTrialBeenUsed()) {
      appLogger.i('startTrial: trial already consumed');
      return current;
    }

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    await prefs.setString(_kTrialStartKey, now.toIso8601String());
    await prefs.setBool(_kTrialUsedKey, true);

    final sub = ProSubscription.trial(now.add(trialDuration));
    _ctrl.add(sub);
    appLogger.i('Trial started — ends ${sub.trialEndsAt}');
    return sub;
  }

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // SERVER VERIFY FIRST. The previous code path granted Pro
          // on `PurchaseStatus.purchased` alone — fully bypassable by
          // anyone stubbing the IAP plugin. We now ship the receipt
          // to /api/iap/verify, which validates against Apple/Google
          // and only on success do we flip the local Pro flag.
          final verified = await _verifyServerSide(p);
          if (verified) {
            await _grant(p.productID);
          } else {
            appLogger.w(
              'IAP server-verify rejected purchase ${p.purchaseID} '
              '(${p.productID}) — not granting Pro',
            );
          }
          // completePurchase must run regardless of verification —
          // not calling it leaves the transaction permanently
          // hanging in the store queue.
          if (p.pendingCompletePurchase) {
            await _iap.completePurchase(p);
          }
        case PurchaseStatus.error:
          appLogger.w('Purchase error: ${p.error}');
        case PurchaseStatus.canceled:
        case PurchaseStatus.pending:
          break;
      }
    }
  }

  /// POSTs the receipt to /api/iap/verify and returns true iff the
  /// server confirms the purchase is valid. Network failures fail
  /// closed (returns false) — better to make the user re-tap "Restore
  /// purchases" than to grant Pro on a 5xx.
  Future<bool> _verifyServerSide(PurchaseDetails p) async {
    final token = await _auth.bearerToken();
    if (token == null) {
      appLogger.w('IAP verify: no auth token — user must sign in first');
      return false;
    }
    final platform = p.verificationData.source == 'app_store' ? 'ios' : 'android';
    try {
      final resp = await _http
          .post(
            Uri.parse('${_auth.baseUrl}/api/iap/verify'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'platform': platform,
              'productId': p.productID,
              'transactionId': p.purchaseID ?? '',
              'serverVerificationData': p.verificationData.serverVerificationData,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        appLogger.w('IAP verify HTTP ${resp.statusCode}: ${resp.body}');
        return false;
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return body['ok'] == true && body['pro'] == true;
    } catch (e) {
      appLogger.w('IAP verify network failure: $e');
      return false;
    }
  }

  Future<void> _grant(String productId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSubKey, true);
    await prefs.setString(_kProductIdKey, productId);
    _ctrl.add(ProSubscription.paid(productId: productId));
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _ctrl.close();
  }
}
