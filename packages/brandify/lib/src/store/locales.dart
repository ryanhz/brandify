import '../process.dart';
import 'slots.dart';

/// Google Play listing languages, as fastlane `supply` names its folders
/// (fastlane `supply/lib/supply/languages.rb`, from Play Console).
const playLocales = {
  'af', 'am', 'ar', 'az-AZ', 'be', 'bg', 'bn-BD', 'ca', 'cs-CZ', 'da-DK', 'de-DE', 'el-GR', //
  'en-AU', 'en-CA', 'en-GB', 'en-IN', 'en-SG', 'en-US', 'en-ZA', 'es-419', 'es-ES', 'es-US',
  'et', 'eu-ES', 'fa', 'fi-FI', 'fil', 'fr-CA', 'fr-FR', 'gl-ES', 'hi-IN', 'hr', 'hu-HU',
  'hy-AM', 'id', 'is-IS', 'it-IT', 'iw-IL', 'ja-JP', 'ka-GE', 'km-KH', 'kn-IN', 'ko-KR',
  'ky-KG', 'lo-LA', 'lt', 'lv', 'mk-MK', 'ml-IN', 'mn-MN', 'mr-IN', 'ms', 'ms-MY', 'my-MM',
  'ne-NP', 'nl-NL', 'no-NO', 'pl-PL', 'pt-BR', 'pt-PT', 'rm', 'ro', 'ru-RU', 'si-LK', 'sk',
  'sl', 'sr', 'sv-SE', 'sw', 'ta-IN', 'te-IN', 'th', 'tr-TR', 'uk', 'vi', 'zh-CN', 'zh-HK',
  'zh-TW', 'zu',
};

/// App Store Connect localizations, as fastlane `deliver` names its folders
/// (fastlane `fastlane_core/lib/fastlane_core/languages.rb`).
const appStoreLocales = {
  'ar-SA', 'bn-BD', 'ca', 'cs', 'da', 'de-DE', 'el', 'en-AU', 'en-CA', 'en-GB', 'en-US', //
  'es-ES', 'es-MX', 'fi', 'fr-CA', 'fr-FR', 'gu-IN', 'he', 'hi', 'hr', 'hu', 'id', 'it', 'ja',
  'kn-IN', 'ko', 'ml-IN', 'mr-IN', 'ms', 'nl-NL', 'no', 'or-IN', 'pa-IN', 'pl', 'pt-BR',
  'pt-PT', 'ro', 'ru', 'sk', 'sl-SI', 'sv', 'ta-IN', 'te-IN', 'th', 'tr', 'uk', 'ur-PK', 'vi',
  'zh-Hans', 'zh-Hant',
};

Set<String> localesOf(Store store) => store == Store.play ? playLocales : appStoreLocales;

// Spanish for Latin America is one Play listing, `es-419`.
const _latinAmerica = {
  'AR', 'BO', 'CL', 'CO', 'CR', 'CU', 'DO', 'EC', 'GT', 'HN', 'MX', 'NI', 'PA', 'PE', 'PR', //
  'PY', 'SV', 'UY', 'VE', '419',
};

/// The store's folder name for a `brandify.yaml` locale (BCP 47), or throws
/// with what to write in `export.locales` instead.
///
/// In order: the tag itself; Chinese by script or region (`zh-Hans`/`zh-CN`
/// -> Play `zh-CN`, App Store `zh-Hans`); the stores' legacy and alias codes
/// (Hebrew is `iw-IL` on Play, Norwegian Bokmål `no`); Latin American Spanish
/// -> Play `es-419`; a regional tag the store only has as a language
/// (`ja-JP` -> App Store `ja`); a bare language the store has in exactly one
/// region (`de` -> Play `de-DE`). Anything else is ambiguous or missing and
/// is an error, never a guess.
String storeLocale(Store store, String tag) {
  final known = localesOf(store);
  if (known.contains(tag)) return tag;

  final parts = tag.split('-');
  final lang = parts.first;
  String? script, region;
  for (final s in parts.skip(1)) {
    if (s.length == 4) {
      script = s;
    } else {
      region = s;
    }
  }

  String? pick(String? code) => code != null && known.contains(code) ? code : null;

  String? mapped;
  switch (lang) {
    case 'zh':
      final traditional = script == 'Hant' || (script == null && const {'TW', 'HK', 'MO'}.contains(region));
      final simplified = script == 'Hans' || (script == null && const {'CN', 'SG'}.contains(region));
      if (store == Store.appStore) {
        mapped = traditional ? 'zh-Hant' : (simplified ? 'zh-Hans' : null);
      } else if (simplified) {
        mapped = 'zh-CN';
      } else if (traditional) {
        mapped = region == 'HK' ? 'zh-HK' : 'zh-TW';
      }
    case 'he' || 'iw':
      mapped = store == Store.play ? 'iw-IL' : 'he';
    case 'nb' || 'no':
      mapped = store == Store.play ? 'no-NO' : 'no';
    case 'es' when store == Store.play && region != null && _latinAmerica.contains(region):
      mapped = 'es-419';
    case 'tl':
      mapped = pick('fil');
  }
  mapped ??= script == null && region != null ? pick(lang) : null;
  if (mapped == null && script == null && region == null) {
    final regional = known.where((c) => c.startsWith('$lang-')).toList();
    if (regional.length == 1) mapped = regional.single;
  }
  if (mapped != null && known.contains(mapped)) return mapped;

  final candidates = known.where((c) => c == lang || c.startsWith('$lang-')).toList()..sort();
  final key = store == Store.play ? 'play' : 'app_store';
  throw BrandifyException('${store.label} has no listing language for "$tag"'
      '${candidates.isEmpty ? '' : ' (closest: ${candidates.join(', ')})'}. '
      'Set it in brandify.yaml: export: {locales: {$tag: {$key: <code>}}}'
      '${candidates.isEmpty ? ', or `$key: none` to leave it out of ${store.label}' : ''}.');
}
