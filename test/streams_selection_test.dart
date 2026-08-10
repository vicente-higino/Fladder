import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/util/jellyfin_extension.dart';
import 'package:fladder/util/streams_selection.dart';

void main() {
  group('Always subtitle selection', () {
    test('enables the best regional candidate when Jellyfin returned null', () {
      final streams = [
        sub(31, language: 'por', title: ''),
        sub(32, language: 'por', title: 'Brazilian'),
      ];

      expect(
        selectRegionalSubtitleForAlways(
          alwaysPlaySubtitles: true,
          preferredLanguage: 'pt-br',
          streams: streams,
          defaultStreamIndex: null,
        ),
        32,
      );
    });

    test('preserves remembered Off and non-Always modes', () {
      final streams = [sub(32, language: 'por', title: 'Brazilian')];

      expect(
        selectRegionalSubtitleForAlways(
          alwaysPlaySubtitles: true,
          preferredLanguage: 'pt-br',
          streams: streams,
          defaultStreamIndex: -1,
        ),
        -1,
      );
      expect(
        selectRegionalSubtitleForAlways(
          alwaysPlaySubtitles: false,
          preferredLanguage: 'pt-br',
          streams: streams,
          defaultStreamIndex: null,
        ),
        isNull,
      );
    });

    test('does not enable unrelated candidates and uses a forced fallback', () {
      final unrelated = [sub(1, language: 'eng', title: 'English')];
      final forced = [sub(2, language: 'por', title: 'Brazilian', isForced: true)];

      expect(
        selectRegionalSubtitleForAlways(
          alwaysPlaySubtitles: true,
          preferredLanguage: 'pt-br',
          streams: unrelated,
          defaultStreamIndex: null,
        ),
        isNull,
      );
      expect(
        selectRegionalSubtitleForAlways(
          alwaysPlaySubtitles: true,
          preferredLanguage: 'pt-br',
          streams: forced,
          defaultStreamIndex: null,
        ),
        2,
      );
    });

    test('does not enable a candidate identified as another region', () {
      final streams = [sub(30, language: 'por', title: 'Português (Portugal)')];

      expect(
        selectRegionalSubtitleForAlways(
          alwaysPlaySubtitles: true,
          preferredLanguage: 'pt-br',
          streams: streams,
          defaultStreamIndex: null,
        ),
        isNull,
      );
    });
  });

  group('regional subtitle selection', () {
    test('selects Brazilian Portuguese by title when both tracks use por', () {
      final streams = [
        sub(29, language: 'por', title: 'Português (Brasil)'),
        sub(30, language: 'por', title: 'Português (Portugal)'),
      ];

      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'pt-BR',
          streams: streams,
          defaultStreamIndex: 30,
        ),
        29,
      );
      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'pob',
          streams: streams,
          defaultStreamIndex: 30,
        ),
        29,
      );
    });

    test('selects Portugal Portuguese by title when both tracks use por', () {
      final streams = [
        sub(29, language: 'POR', title: 'Português (Brasil)'),
        sub(30, language: 'por', title: 'Português (Portugal)'),
      ];

      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'PT_pt',
          streams: streams,
          defaultStreamIndex: 29,
        ),
        30,
      );
      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'pop',
          streams: streams,
          defaultStreamIndex: 29,
        ),
        30,
      );
    });

    test('exact regional metadata outranks a title fallback', () {
      final streams = [
        sub(1, language: 'por', title: 'Português (Brasil)'),
        sub(2, language: 'pob', title: 'Portuguese'),
      ];

      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'pt-br',
          streams: streams,
          defaultStreamIndex: 1,
        ),
        2,
      );
    });

    test('supports the common regional title registry', () {
      final scenarios = <({String preference, String language, String title})>[
        (preference: 'zh-tw', language: 'zho', title: '繁體中文'),
        (preference: 'zh-hk', language: 'chi', title: '中文 (香港)'),
        (preference: 'fr-ca', language: 'fra', title: 'Français (Québec)'),
        (preference: 'es-mx', language: 'spa', title: 'Español Latinoamérica'),
      ];

      for (final scenario in scenarios) {
        final streams = [
          sub(1, language: scenario.language, title: 'Generic'),
          sub(2, language: scenario.language, title: scenario.title),
        ];
        expect(
          refineRegionalSubtitleSelection(
            preferredLanguage: scenario.preference,
            streams: streams,
            defaultStreamIndex: 1,
          ),
          2,
          reason: scenario.preference,
        );
      }
    });

    test('recognizes Jellyfin Latin Spanish regional metadata', () {
      final streams = [
        sub(1, language: 'spa', title: 'Spanish'),
        sub(2, language: 'ES_419', title: 'Spanish'),
      ];

      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'es-mx',
          streams: streams,
          defaultStreamIndex: 1,
        ),
        2,
      );
    });

    test('never enables a disabled subtitle selection', () {
      final streams = [sub(1, language: 'por', title: 'Português (Brasil)')];

      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'pt-br',
          streams: streams,
          defaultStreamIndex: null,
        ),
        isNull,
      );
      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'pt-br',
          streams: streams,
          defaultStreamIndex: -1,
        ),
        -1,
      );
    });

    test('preserves remembered and unrelated-language selections', () {
      final remembered = [
        sub(1, language: 'por', title: 'Português (Portugal)', score: null),
        sub(2, language: 'por', title: 'Português (Brasil)', score: null),
      ];
      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'pt-br',
          streams: remembered,
          defaultStreamIndex: 1,
        ),
        1,
      );

      final unrelated = [
        sub(1, language: 'eng', title: 'English'),
        sub(2, language: 'por', title: 'Português (Brasil)'),
      ];
      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'pt-br',
          streams: unrelated,
          defaultStreamIndex: 1,
        ),
        1,
      );
    });

    test('disambiguates unscored generic metadata by Brazilian title', () {
      final streams = [
        sub(31, language: 'por', title: '', score: null),
        sub(32, language: 'por', title: 'Brazilian', score: null),
      ];

      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'pt-br',
          streams: streams,
          defaultStreamIndex: 31,
        ),
        32,
      );
    });

    test('preserves forced category and Jellyfin selection on a tie', () {
      final forcedBoundary = [
        sub(1, language: 'por', title: 'Português (Portugal)', isForced: true),
        sub(2, language: 'por', title: 'Português (Brasil)'),
      ];
      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'pt-br',
          streams: forcedBoundary,
          defaultStreamIndex: 1,
        ),
        1,
      );

      final tie = [
        sub(1, language: 'por', title: 'Portuguese A'),
        sub(2, language: 'por', title: 'Portuguese B'),
      ];
      expect(
        refineRegionalSubtitleSelection(
          preferredLanguage: 'pt-br',
          streams: tie,
          defaultStreamIndex: 2,
        ),
        2,
      );
    });
  });

  group('remembered subtitle selection', () {
    test('prefers the manually selected embedded index for ambiguous tracks', () {
      final previous = sub(32, language: 'por', title: 'Brazilian');
      final current = [
        sub(31, language: 'por', title: ''),
        sub(32, language: 'por', title: ''),
      ];

      expect(selectSubStream(true, previous, current, 31), 32);
    });

    test('uses the raw title when the embedded index changes', () {
      final previous = sub(32, language: 'por', title: 'Brazilian');
      final current = [
        sub(31, language: 'por', title: ''),
        sub(33, language: 'por', title: 'Brazilian'),
      ];

      expect(selectSubStream(true, previous, current, 31), 33);
    });

    test('preserves forced category and Off', () {
      final previousForced = sub(32, language: 'por', title: 'Brazilian', isForced: true);
      final current = [
        sub(31, language: 'por', title: 'Brazilian'),
        sub(33, language: 'por', title: 'Brazilian', isForced: true),
      ];

      expect(selectSubStream(true, previousForced, current, 31), 33);
      expect(selectSubStream(true, SubStreamModel.no(), current, 31), -1);
    });
  });

  group('culture language codes', () {
    test('stores regional tags while retaining Jellyfin aliases', () {
      const culture = CultureDto(
        name: 'Portuguese (Brazil)',
        displayName: 'Portuguese (Brazil)',
        twoLetterISOLanguageName: 'pt-br',
        threeLetterISOLanguageName: 'pob',
        threeLetterISOLanguageNames: ['pob'],
      );

      expect(culture.preferredSubtitleLanguageCode, 'pt-br');
      expect(culture.matchesLanguageCode('PT_BR'), isTrue);
      expect(culture.matchesLanguageCode('pob'), isTrue);
      expect(culture.matchesLanguageCode('Portuguese (Brazil)'), isTrue);
    });

    test('maps legacy aliases onto Jellyfin regional cultures', () {
      const brazil = CultureDto(
        name: 'pt-br',
        displayName: 'Portuguese (Brazil)',
        twoLetterISOLanguageName: 'pt-br',
        threeLetterISOLanguageName: 'por',
        threeLetterISOLanguageNames: ['por'],
      );
      const portugal = CultureDto(
        name: 'pt-pt',
        displayName: 'Portuguese (Portugal)',
        twoLetterISOLanguageName: 'pt-pt',
        threeLetterISOLanguageName: 'por',
        threeLetterISOLanguageNames: ['por'],
      );

      expect(brazil.matchesLanguageCode('POB'), isTrue);
      expect(brazil.matchesLanguageCode('pop'), isFalse);
      expect(portugal.matchesLanguageCode('pop'), isTrue);
      expect(resolveRegionalLanguageCode('es_419'), 'es-mx');
    });

    test('continues storing canonical three-letter generic codes', () {
      const culture = CultureDto(
        name: 'English',
        displayName: 'English',
        twoLetterISOLanguageName: 'en',
        threeLetterISOLanguageName: 'eng',
        threeLetterISOLanguageNames: ['eng'],
      );

      expect(culture.preferredSubtitleLanguageCode, 'eng');
      expect(culture.matchesLanguageCode('en'), isTrue);
    });
  });

  test('subtitle serialization remains backward compatible', () {
    final original = sub(4, language: 'por', title: 'Português', isForced: true, score: 123);
    final decoded = SubStreamModel.fromJson(original.toJson());
    final legacy = SubStreamModel.fromMap({
      'id': 'legacy',
      'index': 5,
      'language': 'eng',
    });

    expect(decoded.isForced, isTrue);
    expect(decoded.score, 123);
    expect(legacy.isForced, isFalse);
    expect(legacy.score, isNull);
  });
}

SubStreamModel sub(
  int index, {
  required String language,
  required String title,
  bool isForced = false,
  int? score = 1,
}) =>
    SubStreamModel(
      name: title,
      id: '$index',
      title: title,
      displayTitle: title,
      language: language,
      codec: 'srt',
      isDefault: false,
      isExternal: false,
      index: index,
      isForced: isForced,
      score: score,
    );
