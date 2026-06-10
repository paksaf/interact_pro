/// Store-side product identifiers. Configure these in App Store Connect /
/// Google Play Console with matching IDs.
///
/// IMPORTANT: These IDs are global — once shipped to the store, do not
/// rename them. Add new SKUs instead.
class IapProducts {
  IapProducts._();

  static const monthly = 'interact_pro_monthly';
  static const yearly = 'interact_pro_yearly';
  static const lifetime = 'interact_pro_lifetime';

  static const Set<String> all = {monthly, yearly, lifetime};
}
