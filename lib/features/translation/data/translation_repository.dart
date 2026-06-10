import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/result.dart';
import '../domain/translation_entities.dart';
import 'deepseek_client.dart';

final translationRepositoryProvider = Provider<TranslationRepository>((Ref ref) {
  return TranslationRepositoryImpl(ref.watch(deepSeekClientProvider));
});

abstract class TranslationRepository {
  Future<Result<TranslationResult>> translate(TranslationRequest req);
  Future<Result<TranslationResult>> translatePageText(
    String text, {
    required String targetLanguage,
  });
}

class TranslationRepositoryImpl implements TranslationRepository {
  TranslationRepositoryImpl(this._client);
  final DeepSeekClient _client;

  @override
  Future<Result<TranslationResult>> translate(TranslationRequest req) =>
      _client.translate(req);

  @override
  Future<Result<TranslationResult>> translatePageText(
    String text, {
    required String targetLanguage,
  }) =>
      _client.translate(TranslationRequest(
        text: text,
        targetLanguage: targetLanguage,
      ),);
}
