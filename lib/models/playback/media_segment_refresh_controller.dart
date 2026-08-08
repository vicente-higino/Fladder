import 'dart:async';

import 'package:fladder/models/items/media_segments_model.dart';
import 'package:fladder/models/playback/playback_model.dart';

typedef MediaSegmentFetcher = Future<MediaSegmentsModel?> Function(String itemId);
typedef ActivePlaybackReader = PlaybackModel? Function();
typedef ActivePlaybackWriter = void Function(PlaybackModel model);
typedef PlaybackActiveReader = bool Function();

class MediaSegmentRefreshController {
  MediaSegmentRefreshController({
    required MediaSegmentFetcher fetch,
    required ActivePlaybackReader readActivePlayback,
    required ActivePlaybackWriter writeActivePlayback,
    required PlaybackActiveReader isPlaybackActive,
    List<Duration>? retryDelays,
  })  : _fetch = fetch,
        _readActivePlayback = readActivePlayback,
        _writeActivePlayback = writeActivePlayback,
        _isPlaybackActive = isPlaybackActive,
        retryDelays = retryDelays ??
            const [
              Duration(seconds: 1),
              Duration(seconds: 2),
              Duration(seconds: 5),
            ];

  final MediaSegmentFetcher _fetch;
  final ActivePlaybackReader _readActivePlayback;
  final ActivePlaybackWriter _writeActivePlayback;
  final PlaybackActiveReader _isPlaybackActive;
  final List<Duration> retryDelays;

  final List<Timer> _timers = [];
  int _generation = 0;
  bool _requestInFlight = false;
  bool _disposed = false;

  void schedule(PlaybackModel model) {
    cancel();
    if (_disposed ||
        !model.supportsMediaSegmentRefresh ||
        !model.shouldRefreshMediaSegments ||
        model.mediaSegments?.segments.isNotEmpty == true) {
      return;
    }

    final generation = _generation;
    for (final delay in retryDelays) {
      late final Timer timer;
      timer = Timer(delay, () {
        _timers.remove(timer);
        unawaited(_probe(generation, model.item.id));
      });
      _timers.add(timer);
    }
  }

  void cancel() {
    _generation++;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  Future<void> _probe(int generation, String itemId) async {
    if (!_isCurrentGeneration(generation) || _requestInFlight) return;

    final current = _matchingActivePlayback(generation, itemId);
    if (current == null) {
      if (_isCurrentGeneration(generation)) cancel();
      return;
    }
    if (current.mediaSegments?.segments.isNotEmpty == true) {
      cancel();
      return;
    }

    _requestInFlight = true;
    try {
      final mediaSegments = await _fetch(itemId);
      if (!_isCurrentGeneration(generation) || mediaSegments == null || mediaSegments.segments.isEmpty) {
        return;
      }

      final latest = _matchingActivePlayback(generation, itemId);
      if (latest == null) return;
      if (latest.mediaSegments?.segments.isNotEmpty == true) {
        cancel();
        return;
      }

      final updated = latest.withMediaSegments(mediaSegments);
      if (identical(updated, latest)) {
        cancel();
        return;
      }
      _writeActivePlayback(updated);
      cancel();
    } catch (_) {
      // A later bounded retry may still succeed.
    } finally {
      _requestInFlight = false;
    }
  }

  PlaybackModel? _matchingActivePlayback(int generation, String itemId) {
    if (!_isCurrentGeneration(generation) || !_isPlaybackActive()) return null;
    final current = _readActivePlayback();
    if (current == null ||
        current.item.id != itemId ||
        !current.supportsMediaSegmentRefresh ||
        !current.shouldRefreshMediaSegments) {
      return null;
    }
    return current;
  }

  bool _isCurrentGeneration(int generation) => !_disposed && generation == _generation;

  void dispose() {
    if (_disposed) return;
    cancel();
    _disposed = true;
  }
}
