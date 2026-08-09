import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:chopper/chopper.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/util/localization_helper.dart';

const Map<String, Set<String>> regionalLanguageAliases = {
  'pt-br': {'pt-br', 'pob'},
  'pt-pt': {'pt-pt', 'pop'},
  'zh-tw': {'zh-tw'},
  'zh-hk': {'zh-hk'},
  'fr-ca': {'fr-ca', 'frc'},
  'es-mx': {'es-mx', 'es-419'},
};

extension JellyApiExtension on JellyfinOpenApi {
  Future<Response<dynamic>?> itemIdImagesImageTypePost(
    ImageType type,
    String itemId,
    Uint8List data,
  ) async {
    final client = this.client;
    final uri = Uri.parse('/Items/$itemId/Images/${type.value}');
    final response = await client.send(
      Request(
        'POST',
        uri,
        this.client.baseUrl,
        body: base64Encode(data),
        headers: {
          'Content-Type': 'image/*',
        },
      ),
    );
    return response;
  }
}

extension SyncPlayUserAccessTypeExtension on SyncPlayUserAccessType? {
  String? label(BuildContext context) {
    return switch (this) {
      SyncPlayUserAccessType.createandjoingroups => context.localized.syncplayAccessCreateAndJoinGroups,
      SyncPlayUserAccessType.joingroups => context.localized.syncplayAccessJoinGroups,
      SyncPlayUserAccessType.none => context.localized.syncplayAccessNone,
      _ => context.localized.unknown,
    };
  }
}

extension SubtitlePlaybackModeExtension on SubtitlePlaybackMode? {
  String label(BuildContext context) {
    return switch (this) {
      SubtitlePlaybackMode.$default => context.localized.subtitlePlaybackModeDefault,
      SubtitlePlaybackMode.always => context.localized.subtitlePlaybackModeAlways,
      SubtitlePlaybackMode.onlyforced => context.localized.subtitlePlaybackModeOnlyForced,
      SubtitlePlaybackMode.none => context.localized.subtitlePlaybackModeNone,
      SubtitlePlaybackMode.smart => context.localized.subtitlePlaybackModeSmart,
      _ => context.localized.unknown,
    };
  }
}

extension CultureDtoExtension on CultureDto {
  Set<String> get isoLanguageCodes => {
        normalizeLanguageCode(twoLetterISOLanguageName),
        normalizeLanguageCode(threeLetterISOLanguageName),
        ...?threeLetterISOLanguageNames?.map(normalizeLanguageCode),
      }.where((code) => code.isNotEmpty).toSet();

  String? get regionalLanguageCode {
    final code = normalizeLanguageCode(twoLetterISOLanguageName);
    return code.contains('-') ? code : null;
  }

  String? get preferredSubtitleLanguageCode =>
      regionalLanguageCode ??
      normalizeLanguageCode(threeLetterISOLanguageName).nullIfEmpty ??
      normalizeLanguageCode(twoLetterISOLanguageName).nullIfEmpty;

  bool matchesLanguageCode(String? languageCode) {
    final code = normalizeLanguageCode(languageCode);
    if (code.isEmpty) return false;
    final region = regionalLanguageCode;
    if (region != null && resolveRegionalLanguageCode(code) == resolveRegionalLanguageCode(region)) return true;
    if (isoLanguageCodes.contains(code)) return true;
    return code == normalizeLanguageCode(name) || code == normalizeLanguageCode(displayName);
  }
}

String normalizeLanguageCode(String? languageCode) => languageCode?.trim().toLowerCase().replaceAll('_', '-') ?? '';

String? resolveRegionalLanguageCode(String? languageCode) {
  final code = normalizeLanguageCode(languageCode);
  if (code.isEmpty) return null;

  for (final entry in regionalLanguageAliases.entries) {
    if (entry.value.contains(code)) return entry.key;
  }
  return null;
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
