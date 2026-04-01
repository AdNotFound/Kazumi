import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/repositories/bangumi_collection_sync_repository.dart';
import 'package:kazumi/repositories/bangumi_sync_repository.dart';

void main() {
  group('BangumiCollectionSyncRepository status mapping', () {
    test('远端收藏状态映射到本地状态', () {
      expect(BangumiCollectionSyncRepository.mapRemoteTypeToLocal(1), 2);
      expect(BangumiCollectionSyncRepository.mapRemoteTypeToLocal(2), 4);
      expect(BangumiCollectionSyncRepository.mapRemoteTypeToLocal(3), 1);
      expect(BangumiCollectionSyncRepository.mapRemoteTypeToLocal(4), 3);
      expect(BangumiCollectionSyncRepository.mapRemoteTypeToLocal(5), 5);
      expect(BangumiCollectionSyncRepository.mapRemoteTypeToLocal(999), 0);
    });

    test('本地收藏状态映射到远端状态', () {
      expect(BangumiCollectionSyncRepository.mapLocalTypeToRemote(1), 3);
      expect(BangumiCollectionSyncRepository.mapLocalTypeToRemote(2), 1);
      expect(BangumiCollectionSyncRepository.mapLocalTypeToRemote(3), 4);
      expect(BangumiCollectionSyncRepository.mapLocalTypeToRemote(4), 2);
      expect(BangumiCollectionSyncRepository.mapLocalTypeToRemote(5), 5);
      expect(BangumiCollectionSyncRepository.mapLocalTypeToRemote(0), isNull);
    });
  });

  group('BangumiSyncRepository.findEpisodeIdForProgress', () {
    test('优先根据本篇 ep 字段精确匹配', () {
      final id = BangumiSyncRepository.findEpisodeIdForProgress([
        {'id': 21, 'type': 1, 'sort': 1},
        {'id': 12, 'type': 0, 'sort': 2, 'ep': 2},
        {'id': 11, 'type': 0, 'sort': 1, 'ep': 1},
        {'id': 13, 'type': 0, 'sort': 3, 'ep': 3},
      ], 2);

      expect(id, 12);
    });

    test('缺少 ep 字段时回退到 sort 匹配', () {
      final id = BangumiSyncRepository.findEpisodeIdForProgress([
        {'id': 12, 'type': 0, 'sort': 2},
        {'id': 11, 'type': 0, 'sort': 1},
      ], 1);

      expect(id, 11);
    });

    test('找不到对应本篇时返回空', () {
      final id = BangumiSyncRepository.findEpisodeIdForProgress([
        {'id': 21, 'type': 1, 'sort': 1},
      ], 1);

      expect(id, isNull);
    });
  });

  group('BangumiSyncRepository.mapWatchedEpisodeIdsToEpisodeNumbers', () {
    test('将远端章节已看 ID 映射为本地集号', () {
      final watchedEpisodes = BangumiSyncRepository.mapWatchedEpisodeIdsToEpisodeNumbers(
        [
          {'id': 10, 'type': 0, 'sort': 1, 'ep': 1},
          {'id': 11, 'type': 0, 'sort': 2, 'ep': 2},
          {'id': 12, 'type': 1, 'sort': 1},
          {'id': 13, 'type': 0, 'sort': 3, 'ep': 3},
        ],
        {10, 13},
      );

      expect(watchedEpisodes, {1, 3});
    });

    test('缺少 ep 时回退到 sort 或顺序号', () {
      final watchedEpisodes = BangumiSyncRepository.mapWatchedEpisodeIdsToEpisodeNumbers(
        [
          {'id': 21, 'type': 0, 'sort': 1},
          {'id': 22, 'type': 0, 'sort': 0},
        ],
        {21, 22},
      );

      expect(watchedEpisodes, {1, 2});
    });
  });

  group('BangumiSyncRepository.shouldAutoSync', () {
    test('达到 80% 观看进度才允许自动同步', () {
      expect(
        BangumiSyncRepository.shouldAutoSync(
          episode: 1,
          progress: const Duration(minutes: 15, seconds: 59),
          duration: const Duration(minutes: 20),
        ),
        isFalse,
      );
      expect(
        BangumiSyncRepository.shouldAutoSync(
          episode: 1,
          progress: const Duration(minutes: 16),
          duration: const Duration(minutes: 20),
        ),
        isTrue,
      );
      expect(
        BangumiSyncRepository.shouldAutoSync(
          episode: 1,
          progress: const Duration(minutes: 16),
          duration: Duration.zero,
        ),
        isFalse,
      );
    });
  });
}
