import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/repositories/bangumi_sync_repository.dart';

void main() {
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
