import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interact_pro/features/translation/data/translation_cache.dart';
import 'package:interact_pro/features/translation/domain/translation_entities.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late TranslationCache cache;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    cache = container.read(translationCacheProvider);
  });

  tearDown(() => container.dispose());

  group('TranslationCache', () {
    test('returns null on miss', () async {
      final hit = await cache.get(const TranslationRequest(
        text: 'hello',
        targetLanguage: 'ur',
      ),);
      expect(hit, isNull);
    });

    test('round-trips a stored translation', () async {
      const req = TranslationRequest(text: 'hello', targetLanguage: 'ur');
      const res = TranslationResult(
        translatedText: 'ہیلو',
        detectedSourceLanguage: 'en',
        targetLanguage: 'ur',
      );
      await cache.put(req, res);

      final hit = await cache.get(req);
      expect(hit, isNotNull);
      expect(hit!.translatedText, 'ہیلو');
      expect(hit.targetLanguage, 'ur');
    });

    test('different target language yields different cache slot', () async {
      const en = TranslationRequest(text: 'hola', targetLanguage: 'en');
      const ur = TranslationRequest(text: 'hola', targetLanguage: 'ur');

      await cache.put(
        en,
        const TranslationResult(
          translatedText: 'hello',
          detectedSourceLanguage: 'es',
          targetLanguage: 'en',
        ),
      );

      expect(await cache.get(ur), isNull);
      expect((await cache.get(en))!.translatedText, 'hello');
    });

    test('clear empties cache (memory + disk)', () async {
      const req = TranslationRequest(text: 'x', targetLanguage: 'ur');
      await cache.put(
        req,
        const TranslationResult(
          translatedText: 'y',
          detectedSourceLanguage: 'en',
          targetLanguage: 'ur',
        ),
      );

      await cache.clear();

      expect(await cache.get(req), isNull);
      // And nothing left on disk under our prefix.
      final prefs = await SharedPreferences.getInstance();
      final ours = prefs.getKeys().where((k) => k.startsWith('translation_cache.'));
      expect(ours, isEmpty);
    });
  });
}
