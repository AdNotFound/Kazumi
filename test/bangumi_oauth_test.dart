import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/bangumi_oauth.dart';
import 'package:kazumi/request/interceptor.dart';

void main() {
  group('BangumiOAuthService.shouldRefreshTokenByExpiresAt', () {
    test('剩余时间大于 30 分钟时不刷新', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final shouldRefresh = BangumiOAuthService.shouldRefreshTokenByExpiresAt(
        expiresAt: now + const Duration(minutes: 31).inMilliseconds,
        now: now,
      );

      expect(shouldRefresh, isFalse);
    });

    test('剩余时间等于或小于 30 分钟时刷新', () {
      final now = DateTime.now().millisecondsSinceEpoch;

      expect(
        BangumiOAuthService.shouldRefreshTokenByExpiresAt(
          expiresAt: now + const Duration(minutes: 30).inMilliseconds,
          now: now,
        ),
        isTrue,
      );
      expect(
        BangumiOAuthService.shouldRefreshTokenByExpiresAt(
          expiresAt: now - 1,
          now: now,
        ),
        isTrue,
      );
    });

    test('无效过期时间不刷新', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final shouldRefresh = BangumiOAuthService.shouldRefreshTokenByExpiresAt(
        expiresAt: 0,
        now: now,
      );

      expect(shouldRefresh, isFalse);
    });
  });

  group('ApiInterceptor.shouldRetryBangumiUnauthorized', () {
    test('Bangumi 401 且未跳过时允许重试', () {
      final requestOptions = RequestOptions(
        path: 'https://api.bgm.tv/v0/me',
        extra: <String, dynamic>{},
      );

      final shouldRetry = ApiInterceptor.shouldRetryBangumiUnauthorized(
        requestOptions: requestOptions,
        statusCode: 401,
      );

      expect(shouldRetry, isTrue);
    });

    test('已重试或显式跳过时不再重试', () {
      final skippedRequest = RequestOptions(
        path: 'https://api.bgm.tv/v0/me',
        extra: <String, dynamic>{'skipBangumiTokenRefresh': true},
      );
      final retriedRequest = RequestOptions(
        path: 'https://api.bgm.tv/v0/me',
        extra: <String, dynamic>{'bangumiRetried': true},
      );

      expect(
        ApiInterceptor.shouldRetryBangumiUnauthorized(
          requestOptions: skippedRequest,
          statusCode: 401,
        ),
        isFalse,
      );
      expect(
        ApiInterceptor.shouldRetryBangumiUnauthorized(
          requestOptions: retriedRequest,
          statusCode: 401,
        ),
        isFalse,
      );
    });

    test('非 Bangumi 请求或非 401 不重试', () {
      final requestOptions = RequestOptions(
        path: 'https://example.com/api',
        extra: <String, dynamic>{},
      );

      expect(
        ApiInterceptor.shouldRetryBangumiUnauthorized(
          requestOptions: requestOptions,
          statusCode: 401,
        ),
        isFalse,
      );
      expect(
        ApiInterceptor.shouldRetryBangumiUnauthorized(
          requestOptions: requestOptions,
          statusCode: 500,
        ),
        isFalse,
      );
    });
  });
}
