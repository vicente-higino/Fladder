import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart' show PlaybackInfoResponse;
import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/items/item_shared_models.dart';
import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/models/items/overview_model.dart';
import 'package:fladder/models/playback/direct_playback_model.dart';
import 'package:fladder/models/playback/media_segment_refresh_controller.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/transcode_playback_model.dart';

void main() {
  MediaSegmentsModel populatedSegments() => MediaSegmentsModel(
        segments: [
          MediaSegment(
            type: MediaSegmentType.intro,
            start: Duration.zero,
            end: const Duration(seconds: 30),
          ),
        ],
      );

  final emptySegments = MediaSegmentsModel();
  const delays = [
    Duration(milliseconds: 5),
    Duration(milliseconds: 15),
    Duration(milliseconds: 30),
  ];

  group('MediaSegmentRefreshController', () {
    test('does not fetch when the initial model is already populated', () async {
      var fetchCount = 0;
      var current = _TestPlaybackModel(
        item: _item('item-a'),
        mediaSegments: populatedSegments(),
        shouldRefreshMediaSegments: true,
      );
      final controller = MediaSegmentRefreshController(
        fetch: (_) async {
          fetchCount++;
          return populatedSegments();
        },
        readActivePlayback: () => current,
        writeActivePlayback: (model) => current = model as _TestPlaybackModel,
        isPlaybackActive: () => true,
        retryDelays: delays,
      );
      addTearDown(controller.dispose);

      controller.schedule(current);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fetchCount, 0);
    });

    test('publishes the first populated retry exactly once', () async {
      var fetchCount = 0;
      var writeCount = 0;
      var current = _TestPlaybackModel(item: _item('item-b'), marker: 'latest-settings');
      final controller = MediaSegmentRefreshController(
        fetch: (_) async {
          fetchCount++;
          return populatedSegments();
        },
        readActivePlayback: () => current,
        writeActivePlayback: (model) {
          writeCount++;
          current = model as _TestPlaybackModel;
        },
        isPlaybackActive: () => true,
        retryDelays: delays,
      );
      addTearDown(controller.dispose);

      controller.schedule(current);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fetchCount, 1);
      expect(writeCount, 1);
      expect(current.mediaSegments?.segments, hasLength(1));
      expect(current.shouldRefreshMediaSegments, isFalse);
      expect(current.marker, 'latest-settings');
    });

    test('keeps retrying empty results until a later attempt is populated', () async {
      var fetchCount = 0;
      var current = _TestPlaybackModel(item: _item('item-c'));
      final controller = MediaSegmentRefreshController(
        fetch: (_) async {
          fetchCount++;
          return fetchCount == 1 ? emptySegments : populatedSegments();
        },
        readActivePlayback: () => current,
        writeActivePlayback: (model) => current = model as _TestPlaybackModel,
        isPlaybackActive: () => true,
        retryDelays: delays,
      );
      addTearDown(controller.dispose);

      controller.schedule(current);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fetchCount, 2);
      expect(current.mediaSegments?.segments, hasLength(1));
    });

    test('bounds empty and failed attempts without changing the model', () async {
      var fetchCount = 0;
      var writeCount = 0;
      final initial = _TestPlaybackModel(item: _item('item-d'));
      var current = initial;
      final controller = MediaSegmentRefreshController(
        fetch: (_) async {
          fetchCount++;
          if (fetchCount == 1) throw StateError('temporary failure');
          return fetchCount == 2 ? null : emptySegments;
        },
        readActivePlayback: () => current,
        writeActivePlayback: (model) {
          writeCount++;
          current = model as _TestPlaybackModel;
        },
        isPlaybackActive: () => true,
        retryDelays: delays,
      );
      addTearDown(controller.dispose);

      controller.schedule(current);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(fetchCount, 3);
      expect(writeCount, 0);
      expect(identical(current, initial), isTrue);
    });

    test('allows only one retry request to be in flight', () async {
      final response = Completer<MediaSegmentsModel?>();
      var fetchCount = 0;
      final current = _TestPlaybackModel(item: _item('item-in-flight'));
      final controller = MediaSegmentRefreshController(
        fetch: (_) {
          fetchCount++;
          return response.future;
        },
        readActivePlayback: () => current,
        writeActivePlayback: (_) {},
        isPlaybackActive: () => true,
        retryDelays: delays,
      );
      addTearDown(controller.dispose);

      controller.schedule(current);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fetchCount, 1);
      response.complete(emptySegments);
      await response.future;
    });

    test('cancels before fetching when playback closes', () async {
      var fetchCount = 0;
      var active = true;
      final current = _TestPlaybackModel(item: _item('item-e'));
      final controller = MediaSegmentRefreshController(
        fetch: (_) async {
          fetchCount++;
          return populatedSegments();
        },
        readActivePlayback: () => current,
        writeActivePlayback: (_) {},
        isPlaybackActive: () => active,
        retryDelays: delays,
      );
      addTearDown(controller.dispose);

      controller.schedule(current);
      active = false;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(fetchCount, 0);
    });

    test('ignores an old in-flight response after another item loads', () async {
      final oldResponse = Completer<MediaSegmentsModel?>();
      var writeCount = 0;
      var current = _TestPlaybackModel(item: _item('item-f'));
      final controller = MediaSegmentRefreshController(
        fetch: (itemId) => itemId == 'item-f' ? oldResponse.future : Future.value(populatedSegments()),
        readActivePlayback: () => current,
        writeActivePlayback: (model) {
          writeCount++;
          current = model as _TestPlaybackModel;
        },
        isPlaybackActive: () => true,
        retryDelays: delays,
      );
      addTearDown(controller.dispose);

      controller.schedule(current);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      current = _TestPlaybackModel(item: _item('item-g'));
      controller.schedule(current);
      oldResponse.complete(populatedSegments());
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(current.item.id, 'item-g');
      expect(current.mediaSegments?.segments, hasLength(1));
      expect(writeCount, 1);
    });

    test('applies segments to the latest copy of the active model', () async {
      var current = _TestPlaybackModel(item: _item('item-h'), marker: 'initial');
      final controller = MediaSegmentRefreshController(
        fetch: (_) async => populatedSegments(),
        readActivePlayback: () => current,
        writeActivePlayback: (model) => current = model as _TestPlaybackModel,
        isPlaybackActive: () => true,
        retryDelays: delays,
      );
      addTearDown(controller.dispose);

      controller.schedule(current);
      current = current.copyWithMarker('changed-during-playback');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(current.marker, 'changed-during-playback');
      expect(current.mediaSegments?.segments, hasLength(1));
    });
  });

  test('direct and transcoded models replace only media-segment state', () {
    final item = _item('item-i');
    final direct = DirectPlaybackModel(
      item: item,
      media: const Media(url: 'direct'),
      mediaSegments: emptySegments,
      shouldRefreshMediaSegments: true,
    );
    final transcode = TranscodePlaybackModel(
      item: item,
      media: const Media(url: 'transcode'),
      playbackInfo: const PlaybackInfoResponse(playSessionId: 'session-i'),
      mediaSegments: emptySegments,
      shouldRefreshMediaSegments: true,
    );

    final updatedDirect = direct.withMediaSegments(populatedSegments());
    final updatedTranscode = transcode.withMediaSegments(populatedSegments());

    expect(updatedDirect.media?.url, 'direct');
    expect(updatedDirect.item, same(item));
    expect(updatedDirect.mediaSegments?.segments, hasLength(1));
    expect(updatedDirect.shouldRefreshMediaSegments, isFalse);
    expect(updatedTranscode.media?.url, 'transcode');
    expect(updatedTranscode.playbackInfo?.playSessionId, 'session-i');
    expect(updatedTranscode.mediaSegments?.segments, hasLength(1));
    expect(updatedTranscode.shouldRefreshMediaSegments, isFalse);
  });
}

ItemBaseModel _item(String id) => ItemBaseModel(
      name: id,
      id: id,
      overview: const OverviewModel(),
      parentId: null,
      playlistId: null,
      images: null,
      childCount: null,
      primaryRatio: null,
      userData: const UserData(),
      canDownload: null,
      canDelete: null,
      jellyType: null,
    );

class _TestPlaybackModel extends PlaybackModel {
  _TestPlaybackModel({
    required super.item,
    MediaSegmentsModel? mediaSegments,
    super.shouldRefreshMediaSegments = true,
    this.marker = 'unchanged',
  }) : super(
          playbackInfo: null,
          media: const Media(url: 'test'),
          mediaSegments: mediaSegments ?? MediaSegmentsModel(),
        );

  final String marker;

  @override
  bool get supportsMediaSegmentRefresh => true;

  @override
  _TestPlaybackModel withMediaSegments(MediaSegmentsModel mediaSegments) => _TestPlaybackModel(
        item: item,
        mediaSegments: mediaSegments,
        shouldRefreshMediaSegments: false,
        marker: marker,
      );

  _TestPlaybackModel copyWithMarker(String marker) => _TestPlaybackModel(
        item: item,
        mediaSegments: mediaSegments,
        shouldRefreshMediaSegments: shouldRefreshMediaSegments,
        marker: marker,
      );
}
