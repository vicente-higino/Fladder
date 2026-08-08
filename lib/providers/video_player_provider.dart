import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:fladder/models/item_base_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/models/playback/media_segment_refresh_controller.dart';
import 'package:fladder/models/playback/playback_model.dart';
import 'package:fladder/models/playback/playback_queue_state.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/settings/client_settings_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/wrappers/media_control_wrapper.dart';

final mediaPlaybackProvider = StateProvider<MediaPlaybackModel>((ref) => MediaPlaybackModel());

final playBackModel = StateProvider<PlaybackModel?>((ref) => null);

final videoPlayerProvider =
    StateNotifierProvider<VideoPlayerNotifier, MediaControlsWrapper>((ref) {
  final videoPlayer = VideoPlayerNotifier(ref);
  ref.listen(
    mediaPlaybackProvider.select((value) => value.state),
    (_, state) {
      if (state == VideoPlayerState.disposed) {
        videoPlayer.cancelMediaSegmentRefresh();
      }
    },
  );
  if (defaultTargetPlatform != TargetPlatform.windows) {
    unawaited(videoPlayer.init());
  }
  return videoPlayer;
});

typedef VideoPlayerInitializer = Future<void> Function();

class VideoPlayerNotifier extends StateNotifier<MediaControlsWrapper> {
  VideoPlayerNotifier(
    this.ref, {
    VideoPlayerInitializer? initializeOverride,
  })  : _initializeOverride = initializeOverride,
        super(MediaControlsWrapper(ref: ref));

  final Ref ref;
  final VideoPlayerInitializer? _initializeOverride;

  List<StreamSubscription> subscriptions = [];
  Future<void>? _initialization;
  bool _hasCompletedInitialization = false;

  late final MediaSegmentRefreshController _mediaSegmentRefreshController = MediaSegmentRefreshController(
    fetch: (itemId) async {
      final response = await ref.read(jellyApiProvider).mediaSegmentsGet(id: itemId);
      return response?.isSuccessful == true ? response?.body : null;
    },
    readActivePlayback: () => ref.read(playBackModel),
    writeActivePlayback: (model) => ref.read(playBackModel.notifier).state = model,
    isPlaybackActive: () => ref.read(mediaPlaybackProvider).state != VideoPlayerState.disposed,
  );

  late final mediaState = ref.read(mediaPlaybackProvider.notifier);

  MediaPlaybackModel get playbackState => ref.read(mediaPlaybackProvider);
  bool get initializationInProgress => _initialization != null;
  bool get hasCompletedInitialization => _hasCompletedInitialization;

  Future<void> init() {
    final activeInitialization = _initialization;
    if (activeInitialization != null) return activeInitialization;

    late final Future<void> operation;
    operation = _runInitialization().whenComplete(() {
      if (identical(_initialization, operation)) {
        _initialization = null;
      }
    });
    _initialization = operation;
    return operation;
  }

  Future<void> _runInitialization() async {
    final initializeOverride = _initializeOverride;
    if (initializeOverride != null) {
      await initializeOverride();
    } else {
      await _initializePlayer();
    }
    _hasCompletedInitialization = true;
  }

  Future<void> _initializePlayer() async {
    await state.stop();
    await state.dispose();
    await state.init();

    for (final s in subscriptions) {
      await s.cancel();
    }
    subscriptions.clear();

    final subscription = state.stateStream.listen((value) {
      updateBuffering(value.buffering);
      updateBuffer(value.buffer);
      updatePlaying(value.playing);
      updatePosition(value.position);
      updateDuration(value.duration);
    });

    subscriptions.add(subscription);
  }

  Future<void> updateBuffering(bool event) async =>
      mediaState.update((state) => state.buffering == event ? state : state.copyWith(buffering: event));

  Future<void> updateBuffer(Duration buffer) async {
    mediaState.update(
      (state) => (state.buffer - buffer).inSeconds.abs() < 1
          ? state
          : state.copyWith(
              buffer: buffer,
            ),
    );
  }

  Future<void> updateDuration(Duration duration) async {
    mediaState.update((state) {
      return (state.duration - duration).inSeconds.abs() < 1
          ? state
          : state.copyWith(
              duration: duration,
            );
    });
  }

  Future<void> updatePlaying(bool event) async {
    final currentState = playbackState;
    if (!state.hasPlayer || currentState.playing == event) return;
    if (currentState.state == VideoPlayerState.disposed) return;
    mediaState.update(
      (state) => state.copyWith(playing: event),
    );
    ref.read(playBackModel)?.updatePlaybackPosition(currentState.position, event, ref);
  }

  Future<void> updatePosition(Duration event) async {
    if (!state.hasPlayer) return;
    if (playbackState.playing == false) return;
    final currentState = playbackState;
    if (currentState.state == VideoPlayerState.disposed) return;
    final currentPosition = currentState.position;

    if ((currentPosition - event).inSeconds.abs() < 1) return;

    final position = event;

    final lastPosition = currentState.lastPosition;
    final diff = (position.inMilliseconds - lastPosition.inMilliseconds).abs();

    if (diff > const Duration(seconds: 10).inMilliseconds) {
      mediaState.update((value) => value.copyWith(
            position: event,
            lastPosition: position,
          ));
      ref.read(playBackModel)?.updatePlaybackPosition(position, playbackState.playing, ref);
    } else {
      mediaState.update((value) => value.copyWith(
            position: event,
          ));
    }
  }

  Future<bool> loadPlaybackItem(PlaybackModel model, Duration startPosition) async {
    _mediaSegmentRefreshController.cancel();
    ref.read(playBackModel)?.dispose();
    await state.stop();
    final playbackSettings = ref.read(videoPlayerSettingsProvider);
    final initialPlaybackRate = playbackSettings.effectivePlaybackRate;
    ref.read(playbackRateProvider.notifier).state = initialPlaybackRate;

    final useMinimizedPlayer =
        model.item.type == FladderItemType.audio || model.mediaStreams?.videoStreams.isEmpty == true;

    mediaState.update((state) => state.copyWith(
          state: useMinimizedPlayer ? VideoPlayerState.minimized : VideoPlayerState.fullScreen,
          fullScreen: !useMinimizedPlayer,
          buffering: true,
          errorPlaying: false,
          skippedSegments: {},
        ));

    final media = model.media;
    PlaybackModel? newPlaybackModel = model;
    final effectiveStartPosition = await model.resolvedStartPosition(startPosition);

    if (media != null) {
      ref.read(playBackModel.notifier).update((state) => newPlaybackModel);
      _mediaSegmentRefreshController.schedule(model);
      await state.loadVideo(model, effectiveStartPosition, true);
      await state.setVolume(ref.read(videoPlayerSettingsProvider).volume);
      if (playbackSettings.rememberPlaybackRate) {
        await state.applyPlaybackRate(initialPlaybackRate);
      }

      await state.setAudioTrack(null, model);
      await state.setSubtitleTrack(null, model);

      ref.read(mediaPlaybackProvider.notifier).update((state) => state.copyWith(
            state: useMinimizedPlayer ? VideoPlayerState.minimized : VideoPlayerState.fullScreen,
            buffering: true,
            errorPlaying: false,
            skippedSegments: {},
          ));

      await state.play();
      return true;
    }

    mediaState.update((state) => state.copyWith(errorPlaying: true));
    return false;
  }

  Future<bool> loadAudioPlaybackItem(
    PlaybackModel model,
    List<ItemBaseModel> queue,
    int currentIndex,
    Duration startPosition,
  ) async {
    _mediaSegmentRefreshController.cancel();
    final currentPlayerState = ref.read(mediaPlaybackProvider).state;
    final keepFullScreenLayout = currentPlayerState == VideoPlayerState.fullScreen;
    final playbackSettings = ref.read(mediaPlaybackProvider);

    final initializedQueueState = PlaybackQueueState.fromQueue(
      queue,
      initialItemId: queue[currentIndex.clamp(0, queue.length - 1)].id,
      shuffleEnabled: playbackSettings.shuffleEnabled,
      repeatMode: playbackSettings.repeatMode,
    );
    final queuedModel = model.updatePlaybackQueue(initializedQueueState);
    final effectiveStartPosition = await queuedModel.resolvedStartPosition(startPosition);

    ref.read(playBackModel.notifier).update((state) => queuedModel);
    final videoSettings = ref.read(videoPlayerSettingsProvider);
    final initialPlaybackRate = videoSettings.effectivePlaybackRate;
    ref.read(playbackRateProvider.notifier).state = initialPlaybackRate;

    mediaState.update((state) => state.copyWith(
          state: keepFullScreenLayout ? VideoPlayerState.fullScreen : VideoPlayerState.minimized,
          fullScreen: keepFullScreenLayout,
          buffering: true,
          errorPlaying: false,
          skippedSegments: {},
          duration: queuedModel.item.overview.runTime ?? Duration.zero,
        ));

    await state.loadAudioQueue(queue, currentIndex, effectiveStartPosition, true);
    await state.setVolume(ref.read(videoPlayerSettingsProvider).volume);
    if (videoSettings.rememberPlaybackRate) {
      await state.applyPlaybackRate(initialPlaybackRate);
    }

    mediaState.update((state) => state.copyWith(
          buffering: false,
          playing: true,
          position: effectiveStartPosition,
          duration: queuedModel.item.overview.runTime ?? Duration.zero,
        ));
    return true;
  }

  Future<void> reorderAudioQueueSection(
    AudioQueueSection section,
    int oldIndex,
    int newIndex,
  ) async {
    await state.reorderAudioQueueSection(section, oldIndex, newIndex);
  }

  Future<void> addToTemporaryQueue(List<ItemBaseModel> items) async {
    await state.addToTemporaryQueue(items);
  }

  Future<void> clearTemporaryQueue() async {
    state.clearTemporaryQueue();
  }

  Future<void> removeAudioQueueItem(ItemBaseModel item) async {
    await state.removeAudioQueueItem(item.id);
  }

  Future<void> removeAudioQueueSectionItem(
    AudioQueueSection section,
    int sectionIndex,
  ) async {
    await state.removeAudioQueueSectionItem(section, sectionIndex);
  }

  Future<void> playAudioQueueItem(ItemBaseModel item) async {
    if (ref.read(playBackModel) == null) return;
    await state.jumpToQueueItem(item);
  }

  Future<void> openPlayer(BuildContext context) async => state.openPlayer(context);

  void cancelMediaSegmentRefresh() => _mediaSegmentRefreshController.cancel();

  Future<bool> takeScreenshot() async {
    final syncPath = ref.read(clientSettingsProvider).syncPath;
    // Early return here if we don't have a set/valid path. Skips actually taking the screenshot
    // which would be discarded.
    if (syncPath == null) {
      return false;
    }

    final screenshotsPath = p.join(syncPath, "Screenshots");
    final screenshotBuf = await state.takeScreenshot();

    if (screenshotBuf != null) {
      final savePathDirectory = Directory(screenshotsPath);

      // Should we try to create the directory instead?
      if (!await savePathDirectory.exists()) {
        return false;
      }

      final fileExtension = "png";
      final paddingAmount = 3;

      int maxNumber = 0;

      await for (var file in savePathDirectory.list()) {
        final finalSegment = file.uri.pathSegments.last;

        if (file is File && p.extension(finalSegment) == ".$fileExtension") {
          final match = RegExp(r'(\d+)').firstMatch(finalSegment);

          if (match != null) {
            final fileNumber = int.parse(match.group(0)!);

            if (fileNumber > maxNumber) {
              maxNumber = fileNumber;
            }
          }
        }
      }

      maxNumber += 1;

      final maxNumberStr = maxNumber.toString().padLeft(paddingAmount, '0');
      final screenshotName = '$maxNumberStr.$fileExtension';
      final screenshotPath = p.join(screenshotsPath, screenshotName);

      final screenshotFile = File(screenshotPath);
      await screenshotFile.writeAsBytes(screenshotBuf);

      return true;
    }

    return false;
  }

  @override
  void dispose() {
    _mediaSegmentRefreshController.dispose();
    super.dispose();
  }
}
