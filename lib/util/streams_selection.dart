import 'package:fladder/models/items/media_streams_model.dart';
import 'package:fladder/util/jellyfin_extension.dart';

const Map<String, Set<String>> _regionalLanguageFamilyCodes = {
  'pt-br': {'pt-br', 'pob', 'pt', 'por'},
  'pt-pt': {'pt-pt', 'pop', 'pt', 'por'},
  'zh-tw': {'zh-tw', 'zh', 'chi', 'zho', 'ze'},
  'zh-hk': {'zh-hk', 'zh', 'chi', 'zho', 'ze'},
  'fr-ca': {'fr-ca', 'frc', 'fr', 'fre', 'fra'},
  'es-mx': {'es-mx', 'es-419', 'es', 'spa'},
};

const Map<String, List<String>> _regionalSubtitleTitleAliases = {
  'pt-br': [
    'brazil',
    'brasil',
    'brazilian',
    'brasileiro',
    'brasileira',
    'português brasileiro',
    'portugues brasileiro',
  ],
  'pt-pt': [
    'portugal',
    'european portuguese',
    'português europeu',
    'portugues europeu',
  ],
  'zh-tw': [
    'traditional chinese',
    'traditional',
    'taiwan',
    '台灣',
    '台湾',
    '繁體',
    '繁体',
    '正體',
    '正体',
  ],
  'zh-hk': ['hong kong', 'hongkong', '香港'],
  'fr-ca': ['canada', 'canadian', 'canadien', 'canadienne', 'québec', 'quebec'],
  'es-mx': [
    'mexico',
    'méxico',
    'mexican',
    'mexicano',
    'mexicana',
    'latin america',
    'latinoamérica',
    'latinoamerica',
    'latam',
    'español latino',
    'espanol latino',
  ],
};

int? selectAudioStream(
  bool rememberAudioSelection,
  AudioAndSubStreamModel? previousStream,
  List<AudioAndSubStreamModel>? currentStream,
  int? defaultStream,
) {
  if (!rememberAudioSelection) {
    return defaultStream;
  }
  return _selectStream(previousStream, currentStream, defaultStream);
}

int? selectSubStream(
  bool rememberSubSelection,
  AudioAndSubStreamModel? previousStream,
  List<AudioAndSubStreamModel>? currentStream,
  int? defaultStream,
) {
  if (!rememberSubSelection) {
    return defaultStream;
  }
  if (previousStream is! SubStreamModel || currentStream == null) {
    return _selectStream(previousStream, currentStream, defaultStream);
  }
  if (previousStream.index == -1) return -1;

  return _selectSubtitleStream(
    previousStream,
    currentStream.whereType<SubStreamModel>().toList(),
    defaultStream,
  );
}

/// Enables the best regional subtitle only when Jellyfin's Always mode
/// produced no selection, preferring full subtitles before forced subtitles.
/// A remembered Off is represented by `-1` and is intentionally preserved.
int? selectRegionalSubtitleForAlways({
  required bool alwaysPlaySubtitles,
  required String? preferredLanguage,
  required List<SubStreamModel>? streams,
  required int? defaultStreamIndex,
}) {
  if (!alwaysPlaySubtitles || defaultStreamIndex != null || streams == null || streams.isEmpty) {
    return defaultStreamIndex;
  }

  final regionalCode = resolveRegionalLanguageCode(preferredLanguage);
  if (regionalCode == null) return defaultStreamIndex;

  final familyCodes = _regionalLanguageFamilyCodes[regionalCode]!;
  final fullSubtitle = _bestRegionalCandidate(
    streams.where((stream) => !stream.isForced),
    regionalCode,
    familyCodes,
  );
  final forcedSubtitle = _bestRegionalCandidate(
    streams.where((stream) => stream.isForced),
    regionalCode,
    familyCodes,
  );

  return fullSubtitle?.index ?? forcedSubtitle?.index ?? defaultStreamIndex;
}

SubStreamModel? _bestRegionalCandidate(
  Iterable<SubStreamModel> streams,
  String regionalCode,
  Set<String> familyCodes,
) {
  SubStreamModel? bestStream;
  var bestRank = 0;

  for (final stream in streams) {
    if (!familyCodes.contains(normalizeLanguageCode(stream.language))) continue;
    final identifiedRegion = _identifiedRegion(stream);
    if (identifiedRegion != null && identifiedRegion != regionalCode) continue;

    final rank = _regionalMatchRank(stream, regionalCode, familyCodes);
    if (rank > bestRank) {
      bestRank = rank;
      bestStream = stream;
    }
  }

  return bestStream;
}

/// Refines an already-enabled Jellyfin subtitle selection when the preferred
/// culture is regional but the media uses a generic language code.
///
/// This never enables subtitles or crosses language/forced-subtitle
/// boundaries. An unscored, region-identified selection is preserved; an
/// unlabelled generic selection can still be refined by stronger metadata.
int? refineRegionalSubtitleSelection({
  required String? preferredLanguage,
  required List<SubStreamModel>? streams,
  required int? defaultStreamIndex,
}) {
  if (defaultStreamIndex == null || defaultStreamIndex == -1 || streams == null || streams.isEmpty) {
    return defaultStreamIndex;
  }

  SubStreamModel? selectedStream;
  for (final stream in streams) {
    if (stream.index == defaultStreamIndex) {
      selectedStream = stream;
      break;
    }
  }
  if (selectedStream == null) return defaultStreamIndex;

  final regionalCode = resolveRegionalLanguageCode(preferredLanguage);
  if (regionalCode == null) return defaultStreamIndex;

  final familyCodes = _regionalLanguageFamilyCodes[regionalCode]!;
  if (!familyCodes.contains(normalizeLanguageCode(selectedStream.language))) {
    return defaultStreamIndex;
  }

  var bestStream = selectedStream;
  var bestRank = _regionalMatchRank(selectedStream, regionalCode, familyCodes);

  for (final stream in streams) {
    if (stream.isForced != selectedStream.isForced) continue;
    if (!familyCodes.contains(normalizeLanguageCode(stream.language))) continue;

    final rank = _regionalMatchRank(stream, regionalCode, familyCodes);
    if (rank > bestRank) {
      bestRank = rank;
      bestStream = stream;
    }
  }

  // Jellyfin omits scores for remembered choices, but item metadata can also
  // omit every score before playback starts. Preserve an unscored selection
  // only when its own metadata identifies a region; a generic track remains
  // eligible for disambiguation by a better same-family title/code.
  if (streams.every((stream) => stream.score == null) &&
      bestStream.index != selectedStream.index &&
      _identifiedRegion(selectedStream) != null) {
    return defaultStreamIndex;
  }

  return bestStream.index;
}

int _regionalMatchRank(
  SubStreamModel stream,
  String regionalCode,
  Set<String> familyCodes,
) {
  final language = normalizeLanguageCode(stream.language);
  if (regionalLanguageAliases[regionalCode]!.contains(language)) return 3;
  if (_titleMatchesRegion(stream, regionalCode)) return 2;
  return familyCodes.contains(language) ? 1 : 0;
}

bool _titleMatchesRegion(SubStreamModel stream, String regionalCode) {
  final aliases = _regionalSubtitleTitleAliases[regionalCode];
  if (aliases == null || aliases.isEmpty) return false;

  final title = _normalizeSubtitleTitle('${stream.title} ${stream.displayTitle}');
  return aliases.any((alias) => title.contains(_normalizeSubtitleTitle(alias)));
}

String? _identifiedRegion(SubStreamModel stream) {
  final languageRegion = resolveRegionalLanguageCode(stream.language);
  if (languageRegion != null) return languageRegion;

  for (final regionalCode in _regionalSubtitleTitleAliases.keys) {
    if (_titleMatchesRegion(stream, regionalCode)) return regionalCode;
  }
  return null;
}

String _normalizeSubtitleTitle(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[_\-()\[\]{}.;,:/\\]+'), ' ').replaceAll(RegExp(r'\s+'), ' ');

int? _selectSubtitleStream(
  SubStreamModel previousStream,
  List<SubStreamModel> currentStreams,
  int? defaultStream,
) {
  if (currentStreams.isEmpty) return defaultStream;

  final previousRelativeIndex = currentStreams.indexWhere((stream) => stream.index == previousStream.index);
  var bestScore = 0;
  int? bestStreamIndex;

  for (var relativeIndex = 0; relativeIndex < currentStreams.length; relativeIndex++) {
    final stream = currentStreams[relativeIndex];
    if (stream.isForced != previousStream.isForced) continue;

    var score = 0;
    if (stream.index == previousStream.index) score += 4;
    if (previousStream.title.isNotEmpty && stream.title == previousStream.title) score += 4;
    if (previousStream.displayTitle.isNotEmpty && stream.displayTitle == previousStream.displayTitle) score += 2;
    if (previousStream.language != 'und' && previousStream.language == stream.language) score += 2;
    if (previousStream.codec == stream.codec) score += 1;
    if (previousRelativeIndex >= 0 && previousRelativeIndex == relativeIndex) score += 1;

    if (score > bestScore && score >= 3) {
      bestScore = score;
      bestStreamIndex = stream.index;
    }
  }

  return bestStreamIndex ?? defaultStream;
}

int? _selectStream(
  AudioAndSubStreamModel? previousStream,
  List<AudioAndSubStreamModel>? currentStream,
  int? defaultStream,
) {
  if (currentStream == null || previousStream == null) {
    return defaultStream;
  }

  int? bestStreamIndex;
  int bestStreamScore = 0;

  // Find the relative index of the previous stream
  int prevRelIndex = 0;
  for (var stream in currentStream) {
    if (stream.index == previousStream.index) break;
    prevRelIndex += 1;
  }

  int newRelIndex = 0;
  for (var stream in currentStream) {
    int score = 0;

    if (previousStream.codec == stream.codec) score += 1;
    if (prevRelIndex == newRelIndex) score += 1;
    if (previousStream.displayTitle == stream.displayTitle) {
      score += 2;
    }
    if (previousStream.language != 'und' && previousStream.language == stream.language) {
      score += 2;
    }

    if (score > bestStreamScore && score >= 3) {
      bestStreamScore = score;
      bestStreamIndex = stream.index;
    }

    newRelIndex += 1;
  }
  return bestStreamIndex ?? defaultStream;
}
