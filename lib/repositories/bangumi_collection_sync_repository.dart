import 'dart:async';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/api.dart';
import 'package:kazumi/request/request.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/utils/logger.dart';
import 'package:kazumi/utils/storage.dart';

abstract class IBangumiCollectionSyncRepository {
  Future<bool> syncRemoteCollectionToLocal(BangumiItem bangumiItem);

  Future<void> syncLocalCollectionToRemote(BangumiItem bangumiItem, int localType);
}

class BangumiCollectionSyncRepository implements IBangumiCollectionSyncRepository {
  final _settingBox = GStorage.setting;
  final ICollectCrudRepository _collectCrudRepository;

  BangumiCollectionSyncRepository(this._collectCrudRepository);

  bool get _hasAccessToken {
    final token = _settingBox.get(
      SettingBoxKey.bangumiAccessToken,
      defaultValue: '',
    );
    return token is String && token.isNotEmpty;
  }

  @override
  Future<bool> syncRemoteCollectionToLocal(BangumiItem bangumiItem) async {
    if (!_hasAccessToken) {
      return false;
    }

    try {
      final username = await _ensureUsername();
      final remoteType = await _getRemoteCollectionType(
        username: username,
        bangumiId: bangumiItem.id,
      );
      final localType = _collectCrudRepository.getCollectType(bangumiItem.id);
      final mappedType = remoteType == null ? 0 : mapRemoteTypeToLocal(remoteType);
      if (mappedType == localType) {
        return false;
      }

      if (mappedType == 0) {
        await _collectCrudRepository.deleteCollectible(bangumiItem.id);
      } else {
        await _collectCrudRepository.addCollectible(bangumiItem, mappedType);
      }
      return true;
    } catch (e, stackTrace) {
      KazumiLogger().w(
        'Bangumi Collection Sync: sync remote collection to local failed. bangumi=${bangumiItem.name}',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  @override
  Future<void> syncLocalCollectionToRemote(BangumiItem bangumiItem, int localType) async {
    if (!_hasAccessToken || localType == 0) {
      return;
    }

    try {
      final remoteType = mapLocalTypeToRemote(localType);
      if (remoteType == null) {
        return;
      }
      await Request().post(
        Api.formatUrl(
          Api.bangumiAPIDomain + Api.bangumiCurrentUserCollection,
          [bangumiItem.id],
        ),
        data: {'type': remoteType},
        shouldRethrow: true,
      );
    } catch (e, stackTrace) {
      KazumiLogger().w(
        'Bangumi Collection Sync: sync local collection to remote failed. bangumi=${bangumiItem.name}, type=$localType',
        error: e,
        stackTrace: stackTrace,
      );
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

  Future<int?> _getRemoteCollectionType({
    required String username,
    required int bangumiId,
  }) async {
    try {
      final response = await Request().get(
        Api.formatUrl(
          Api.bangumiAPIDomain + Api.bangumiUserCollection,
          [username, bangumiId],
        ),
        shouldRethrow: true,
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      return _toInt(data['type']);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  static int mapRemoteTypeToLocal(int remoteType) {
    switch (remoteType) {
      case 1:
        return 2;
      case 2:
        return 4;
      case 3:
        return 1;
      case 4:
        return 3;
      case 5:
        return 5;
      default:
        return 0;
    }
  }

  static int? mapLocalTypeToRemote(int localType) {
    switch (localType) {
      case 1:
        return 3;
      case 2:
        return 1;
      case 3:
        return 4;
      case 4:
        return 2;
      case 5:
        return 5;
      default:
        return null;
    }
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
}
