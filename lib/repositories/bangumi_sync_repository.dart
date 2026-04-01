import 'dart:async';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/request/api.dart';
import 'package:kazumi/request/request.dart';
import 'package:kazumi/utils/logger.dart';
import 'package:kazumi/utils/storage.dart';

abstract class IBangumiSyncRepository {
  Future<void> scheduleAutoSync(History history, Duration duration);
}

class BangumiSyncRepository implements IBangumiSyncRepository {
  static const double minimumWatchRatio = 0.8;
  static const Duration minimumSyncInterval = Duration(minutes: 2);
  static const int _mainEpisodeType = 0;
  static const int _episodeWatchedType = 2;
  static const int _collectionWishType = 1;
  static const int _collectionWatchingType = 3;

  final _settingBox = GStorage.setting;
  final _collectiblesBox = GStorage.collectibles;
  final Map<String, DateTime> _lastSyncedAt = <String, DateTime>{};
  final Set<String> _syncingKeys = <String>{};

  bool get _hasAccessToken {
    final token = _settingBox.get(
      SettingBoxKey.bangumiAccessToken,
      defaultValue: '',
    );
    return token is String && token.isNotEmpty;
  }

  @override
  Future<void> scheduleAutoSync(History history, Duration duration) async {
    if (!_hasAccessToken) {
      return;
    }

    final episode = history.lastWatchEpisode;
    final progress = history.progresses[episode]?.progress;
    if (!shouldAutoSync(
      episode: episode,
      progress: progress,
      duration: duration,
    )) {
      return;
    }

    final syncKey = _buildSyncKey(history.bangumiItem.id, episode);
    final now = DateTime.now();
    final lastSyncedAt = _lastSyncedAt[syncKey];
    if (_syncingKeys.contains(syncKey)) {
      return;
    }
    if (lastSyncedAt != null &&
        now.difference(lastSyncedAt) < minimumSyncInterval) {
      return;
    }

    _lastSyncedAt[syncKey] = now;
    unawaited(
      _syncEpisode(history).catchError((Object error, StackTrace stackTrace) {
        KazumiLogger().w(
          'Bangumi Sync: episode sync failed. bangumi=${history.bangumiItem.name}, episode=${history.lastWatchEpisode}',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  Future<void> _syncEpisode(History history) async {
    final bangumiId = history.bangumiItem.id;
    final watchedEpisode = history.lastWatchEpisode;
    final syncKey = _buildSyncKey(bangumiId, watchedEpisode);
    if (_syncingKeys.contains(syncKey)) {
      return;
    }
    _syncingKeys.add(syncKey);

    try {
      final username = await _ensureUsername();
      final remoteCollection = await _getSubjectCollection(
        username: username,
        subjectId: bangumiId,
      );
      await _ensureSubjectCollection(bangumiId, remoteCollection);

      final episodes = await _fetchEpisodes(
        subjectId: bangumiId,
        requiredMainEpisodeCount: watchedEpisode,
      );
      final targetEpisodeId = findEpisodeIdForProgress(episodes, watchedEpisode);
      if (targetEpisodeId == null) {
        return;
      }

      final watchedEpisodeIds = await _fetchWatchedEpisodeIds(bangumiId);
      if (watchedEpisodeIds.contains(targetEpisodeId)) {
        return;
      }

      await Request().patch(
        Api.formatUrl(
          Api.bangumiAPIDomain + Api.bangumiCurrentUserEpisodeCollection,
          [bangumiId],
        ),
        data: {
          'episode_id': [targetEpisodeId],
          'type': _episodeWatchedType,
        },
        shouldRethrow: true,
      );
    } finally {
      _syncingKeys.remove(syncKey);
    }
  }

  Future<String> _ensureUsername() async {
    final savedUsername = _settingBox.get(
      SettingBoxKey.bangumiUsername,
      defaultValue: '',
    );
    if (savedUsername is String && savedUsername.isNotEmpty) {
      return savedUsername;
    }

    final response = await Request().get(
      Api.bangumiAPIDomain + Api.bangumiCurrentUser,
      shouldRethrow: true,
    );
    final data = Map<String, dynamic>.from(response.data as Map);
    final username = (data['username'] ?? '').toString();
    if (username.isEmpty) {
      throw Exception('Bangumi 登录状态无效，请重新授权');
    }

    await _settingBox.put(SettingBoxKey.bangumiUsername, username);
    await _settingBox.put(
      SettingBoxKey.bangumiNickname,
      (data['nickname'] ?? '').toString(),
    );
    return username;
  }

  Future<Map<String, dynamic>?> _getSubjectCollection({
    required String username,
    required int subjectId,
  }) async {
    try {
      final response = await Request().get(
        Api.formatUrl(
          Api.bangumiAPIDomain + Api.bangumiUserCollection,
          [username, subjectId],
        ),
        shouldRethrow: true,
      );
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> _ensureSubjectCollection(
    int bangumiId,
    Map<String, dynamic>? remoteCollection,
  ) async {
    if (remoteCollection == null) {
      await Request().post(
        Api.formatUrl(
          Api.bangumiAPIDomain + Api.bangumiCurrentUserCollection,
          [bangumiId],
        ),
        data: {'type': _preferredCollectionType(bangumiId)},
        shouldRethrow: true,
      );
      return;
    }

    if (remoteCollection['type'] == _collectionWishType) {
      await Request().patch(
        Api.formatUrl(
          Api.bangumiAPIDomain + Api.bangumiCurrentUserCollection,
          [bangumiId],
        ),
        data: {'type': _collectionWatchingType},
        shouldRethrow: true,
      );
    }
  }

  int _preferredCollectionType(int bangumiId) {
    final localCollection = _collectiblesBox.get(bangumiId);
    if (localCollection == null) {
      return _collectionWatchingType;
    }

    switch (localCollection.type) {
      case 2:
        return 1;
      case 3:
        return 4;
      case 5:
        return 5;
      default:
        return _collectionWatchingType;
    }
  }

  Future<List<Map<String, dynamic>>> _fetchEpisodes({
    required int subjectId,
    required int requiredMainEpisodeCount,
  }) async {
    final List<Map<String, dynamic>> episodes = <Map<String, dynamic>>[];
    int offset = 0;

    while (true) {
      final response = await Request().get(
        Api.bangumiAPIDomain + Api.bangumiEpisodeByID,
        data: {
          'subject_id': subjectId,
          'offset': offset,
          'limit': 100,
        },
        shouldRethrow: true,
      );
      final data = _extractList(response.data);
      if (data.isEmpty) {
        break;
      }
      episodes.addAll(data);

      final mainEpisodeCount = episodes
          .where((episode) => _toInt(episode['type']) == _mainEpisodeType)
          .length;
      if (mainEpisodeCount >= requiredMainEpisodeCount || data.length < 100) {
        break;
      }
      offset += data.length;
    }

    return episodes;
  }

  Future<Set<int>> _fetchWatchedEpisodeIds(int subjectId) async {
    final Set<int> watchedEpisodeIds = <int>{};
    int offset = 0;

    while (true) {
      final response = await Request().get(
        Api.formatUrl(
          Api.bangumiAPIDomain + Api.bangumiCurrentUserEpisodeCollection,
          [subjectId],
        ),
        data: {
          'offset': offset,
          'limit': 100,
          'episode_type': _mainEpisodeType,
        },
        shouldRethrow: true,
      );
      final data = _extractList(response.data);
      if (data.isEmpty) {
        break;
      }

      for (final collection in data) {
        if (_toInt(collection['type']) != _episodeWatchedType) {
          continue;
        }
        final episode = collection['episode'];
        if (episode is Map) {
          watchedEpisodeIds.add(_toInt(episode['id']));
        }
      }

      if (data.length < 100) {
        break;
      }
      offset += data.length;
    }

    return watchedEpisodeIds;
  }

  static bool shouldAutoSync({
    required int episode,
    required Duration? progress,
    required Duration duration,
  }) {
    if (episode <= 0 || progress == null || duration <= Duration.zero) {
      return false;
    }
    return progress.inMilliseconds >=
        (duration.inMilliseconds * minimumWatchRatio).round();
  }

  static int? findEpisodeIdForProgress(
    List<Map<String, dynamic>> episodes,
    int watchedEpisode,
  ) {
    if (watchedEpisode <= 0 || episodes.isEmpty) {
      return null;
    }

    List<Map<String, dynamic>> sortEpisodes(List<Map<String, dynamic>> list) {
      final copied = List<Map<String, dynamic>>.from(list);
      copied.sort((a, b) {
        final sortCompare = _toNum(a['sort']).compareTo(_toNum(b['sort']));
        if (sortCompare != 0) {
          return sortCompare;
        }
        return _toInt(a['id']).compareTo(_toInt(b['id']));
      });
      return copied;
    }

    final mainEpisodes = sortEpisodes(
      episodes
          .where((episode) => _toInt(episode['type']) == _mainEpisodeType)
          .toList(),
    );

    for (final episode in mainEpisodes) {
      if (_toNum(episode['ep']).round() == watchedEpisode) {
        return _toInt(episode['id']);
      }
    }
    for (final episode in mainEpisodes) {
      if (_toNum(episode['sort']).round() == watchedEpisode) {
        return _toInt(episode['id']);
      }
    }
    if (mainEpisodes.length >= watchedEpisode) {
      return _toInt(mainEpisodes[watchedEpisode - 1]['id']);
    }
    return null;
  }

  static List<Map<String, dynamic>> _extractList(dynamic responseData) {
    final rawData = (responseData as Map<String, dynamic>)['data'];
    if (rawData is! List) {
      return <Map<String, dynamic>>[];
    }

    return rawData
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  static String _buildSyncKey(int bangumiId, int episode) {
    return '$bangumiId:$episode';
  }

  static int _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static num _toNum(dynamic value) {
    if (value is num) {
      return value;
    }
    return num.tryParse(value?.toString() ?? '') ?? 0;
  }
}
