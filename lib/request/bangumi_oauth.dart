import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:kazumi/request/request.dart';
import 'package:kazumi/utils/logger.dart';
import 'package:kazumi/utils/storage.dart';
import 'package:url_launcher/url_launcher.dart';

class BangumiOAuthSession {
  final String clientId;
  final String clientSecret;
  final String redirectUri;
  final String state;
  final Uri authorizeUri;

  const BangumiOAuthSession({
    required this.clientId,
    required this.clientSecret,
    required this.redirectUri,
    required this.state,
    required this.authorizeUri,
  });
}

class BangumiOAuthResult {
  final String accessToken;
  final String refreshToken;
  final String tokenType;
  final int expiresIn;
  final String username;
  final String nickname;

  const BangumiOAuthResult({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.expiresIn,
    required this.username,
    required this.nickname,
  });
}

class BangumiOAuthService {
  static const int defaultLoopbackPort = 32547;
  static const String defaultRedirectUri =
      'http://127.0.0.1:$defaultLoopbackPort/callback';
  static const Duration refreshThreshold = Duration(minutes: 30);

  static bool shouldRefreshTokenByExpiresAt({
    required int expiresAt,
    required int now,
    Duration threshold = refreshThreshold,
  }) {
    if (expiresAt <= 0) {
      return false;
    }
    return expiresAt - now <= threshold.inMilliseconds;
  }

  final _setting = GStorage.setting;

  Uri buildAuthorizeUri({
    required String clientId,
    required String redirectUri,
    required String state,
  }) {
    return Uri.parse('https://bgm.tv/oauth/authorize').replace(
      queryParameters: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'state': state,
      },
    );
  }

  Future<BangumiOAuthSession> createAuthorizationSession() async {
    final String clientId =
        _setting.get(SettingBoxKey.bangumiOauthClientId, defaultValue: '');
    final String clientSecret = _setting.get(
      SettingBoxKey.bangumiOauthClientSecret,
      defaultValue: '',
    );
    final String redirectUri = _setting.get(
      SettingBoxKey.bangumiOauthRedirectUri,
      defaultValue: defaultRedirectUri,
    );

    if (clientId.isEmpty || clientSecret.isEmpty) {
      throw const BangumiOAuthException('请先填写 Client ID 和 Client Secret');
    }

    final Uri redirect = Uri.parse(redirectUri);
    if (!_isLoopbackRedirectUri(redirect)) {
      throw const BangumiOAuthException(
        '当前仅支持 localhost / 127.0.0.1 回调地址，例如 http://127.0.0.1:32547/callback',
      );
    }

    final String state = _buildState();
    return BangumiOAuthSession(
      clientId: clientId,
      clientSecret: clientSecret,
      redirectUri: redirectUri,
      state: state,
      authorizeUri: buildAuthorizeUri(
        clientId: clientId,
        redirectUri: redirectUri,
        state: state,
      ),
    );
  }

  Future<BangumiOAuthResult> authorizeInBrowser({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final session = await createAuthorizationSession();
    final Uri redirect = Uri.parse(session.redirectUri);
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      redirect.port,
      shared: false,
    );

    try {
      final bool launched = await launchUrl(
        session.authorizeUri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw const BangumiOAuthException('无法拉起浏览器，请检查系统浏览器配置');
      }

      final HttpRequest request =
          await server.first.timeout(timeout, onTimeout: () {
        throw const BangumiOAuthException('浏览器授权超时，请重试');
      });

      final Uri callbackUri = request.uri;
      final String? error = callbackUri.queryParameters['error'];
      final String? code = callbackUri.queryParameters['code'];
      request.response.headers.contentType = ContentType.html;
      request.response.write(_buildCallbackHtml(error == null && code != null));
      await request.response.close();

      return completeAuthorizationCallback(
        session: session,
        callbackUri: callbackUri,
      );
    } finally {
      await server.close(force: true);
    }
  }

  Future<BangumiOAuthResult> completeAuthorizationCallback({
    required BangumiOAuthSession session,
    required Uri callbackUri,
  }) async {
    final String? error = callbackUri.queryParameters['error'];
    final String? code = callbackUri.queryParameters['code'];
    final String? returnedState = callbackUri.queryParameters['state'];

    if (error != null && error.isNotEmpty) {
      throw BangumiOAuthException('Bangumi 授权失败：$error');
    }
    if (code == null || code.isEmpty) {
      throw const BangumiOAuthException('未收到授权码，请确认已完成授权');
    }
    if (returnedState != session.state) {
      throw const BangumiOAuthException('授权状态校验失败，请重试');
    }

    final tokenData = await _exchangeCode(
      clientId: session.clientId,
      clientSecret: session.clientSecret,
      code: code,
      redirectUri: session.redirectUri,
    );
    final meData = await _getCurrentUser(tokenData['access_token'] ?? '');

    final result = BangumiOAuthResult(
      accessToken: tokenData['access_token'] ?? '',
      refreshToken: tokenData['refresh_token'] ?? '',
      tokenType: tokenData['token_type'] ?? 'Bearer',
      expiresIn: tokenData['expires_in'] is int
          ? tokenData['expires_in'] as int
          : int.tryParse('${tokenData['expires_in'] ?? 0}') ?? 0,
      username: meData['username'] ?? '',
      nickname: meData['nickname'] ?? '',
    );
    await saveAuthResult(result);
    return result;
  }

  Future<BangumiOAuthResult> verifyCurrentLogin() async {
    final String accessToken =
        _setting.get(SettingBoxKey.bangumiAccessToken, defaultValue: '');
    if (accessToken.isEmpty) {
      throw const BangumiOAuthException('当前未登录 Bangumi');
    }

    final meData = await _getCurrentUser(accessToken);
    final expiresAt = _setting.get(
      SettingBoxKey.bangumiTokenExpiresAt,
      defaultValue: 0,
    );
    final int expiresIn = expiresAt is int
        ? max(0, ((expiresAt - DateTime.now().millisecondsSinceEpoch) / 1000)
            .floor())
        : 0;

    final result = BangumiOAuthResult(
      accessToken: accessToken,
      refreshToken:
          _setting.get(SettingBoxKey.bangumiRefreshToken, defaultValue: ''),
      tokenType:
          _setting.get(SettingBoxKey.bangumiTokenType, defaultValue: 'Bearer'),
      expiresIn: expiresIn,
      username: meData['username'] ?? '',
      nickname: meData['nickname'] ?? '',
    );
    await saveAuthResult(result, overwriteTokenFields: false);
    return result;
  }

  Future<void> saveAuthResult(
    BangumiOAuthResult result, {
    bool overwriteTokenFields = true,
  }) async {
    final int expiresAt =
        DateTime.now().millisecondsSinceEpoch + result.expiresIn * 1000;
    if (overwriteTokenFields) {
      await _setting.put(SettingBoxKey.bangumiAccessToken, result.accessToken);
      await _setting.put(SettingBoxKey.bangumiRefreshToken, result.refreshToken);
      await _setting.put(SettingBoxKey.bangumiTokenType, result.tokenType);
      await _setting.put(SettingBoxKey.bangumiTokenExpiresAt, expiresAt);
    }
    await _setting.put(SettingBoxKey.bangumiUsername, result.username);
    await _setting.put(SettingBoxKey.bangumiNickname, result.nickname);
  }

  Future<void> logout() async {
    await _setting.put(SettingBoxKey.bangumiAccessToken, '');
    await _setting.put(SettingBoxKey.bangumiRefreshToken, '');
    await _setting.put(SettingBoxKey.bangumiTokenType, '');
    await _setting.put(SettingBoxKey.bangumiTokenExpiresAt, 0);
    await _setting.put(SettingBoxKey.bangumiUsername, '');
    await _setting.put(SettingBoxKey.bangumiNickname, '');
  }

  bool hasRefreshToken() {
    final String refreshToken =
        _setting.get(SettingBoxKey.bangumiRefreshToken, defaultValue: '');
    return refreshToken.isNotEmpty;
  }

  bool shouldRefreshToken({
    Duration threshold = refreshThreshold,
  }) {
    final expiresAt = _setting.get(
      SettingBoxKey.bangumiTokenExpiresAt,
      defaultValue: 0,
    );
    if (expiresAt is! int || expiresAt <= 0) {
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return shouldRefreshTokenByExpiresAt(
      expiresAt: expiresAt,
      now: now,
      threshold: threshold,
    );
  }

  Future<BangumiOAuthResult> refreshAccessToken() async {
    final String clientId =
        _setting.get(SettingBoxKey.bangumiOauthClientId, defaultValue: '');
    final String clientSecret = _setting.get(
      SettingBoxKey.bangumiOauthClientSecret,
      defaultValue: '',
    );
    final String refreshToken =
        _setting.get(SettingBoxKey.bangumiRefreshToken, defaultValue: '');
    final String redirectUri = _setting.get(
      SettingBoxKey.bangumiOauthRedirectUri,
      defaultValue: defaultRedirectUri,
    );

    if (clientId.isEmpty || clientSecret.isEmpty) {
      throw const BangumiOAuthException('请先填写 Client ID 和 Client Secret');
    }
    if (refreshToken.isEmpty) {
      throw const BangumiOAuthException('当前缺少 Refresh Token，请重新授权');
    }

    try {
      final Response response = await Request().post(
        'https://bgm.tv/oauth/access_token',
        data: {
          'grant_type': 'refresh_token',
          'client_id': clientId,
          'client_secret': clientSecret,
          'refresh_token': refreshToken,
          'redirect_uri': redirectUri,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            'accept': 'application/json',
          },
          extra: {
            'skipBangumiTokenRefresh': true,
          },
        ),
        shouldRethrow: true,
      );
      final tokenData = Map<String, dynamic>.from(response.data as Map);
      final String nextAccessToken = tokenData['access_token'] ?? '';
      final Map<String, dynamic> meData =
          await _getCurrentUser(nextAccessToken, skipTokenRefresh: true);
      final result = BangumiOAuthResult(
        accessToken: nextAccessToken,
        refreshToken: tokenData['refresh_token'] ?? refreshToken,
        tokenType: tokenData['token_type'] ?? 'Bearer',
        expiresIn: tokenData['expires_in'] is int
            ? tokenData['expires_in'] as int
            : int.tryParse('${tokenData['expires_in'] ?? 0}') ?? 0,
        username: meData['username'] ?? '',
        nickname: meData['nickname'] ?? '',
      );
      await saveAuthResult(result);
      return result;
    } on DioException catch (e) {
      KazumiLogger().e('Bangumi OAuth: refresh token failed', error: e);
      final responseData = e.response?.data;
      if (responseData is Map && responseData['error_description'] != null) {
        throw BangumiOAuthException('${responseData['error_description']}');
      }
      throw const BangumiOAuthException('刷新 Bangumi Access Token 失败');
    }
  }

  Future<Map<String, dynamic>> _exchangeCode({
    required String clientId,
    required String clientSecret,
    required String code,
    required String redirectUri,
  }) async {
    try {
      final Response response = await Request().post(
        'https://bgm.tv/oauth/access_token',
        data: {
          'grant_type': 'authorization_code',
          'client_id': clientId,
          'client_secret': clientSecret,
          'code': code,
          'redirect_uri': redirectUri,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            'accept': 'application/json',
          },
        ),
        shouldRethrow: true,
      );
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      KazumiLogger().e('Bangumi OAuth: exchange code failed', error: e);
      final responseData = e.response?.data;
      if (responseData is Map && responseData['error_description'] != null) {
        throw BangumiOAuthException('${responseData['error_description']}');
      }
      throw const BangumiOAuthException('授权码换取 Access Token 失败');
    }
  }

  Future<Map<String, dynamic>> _getCurrentUser(
    String accessToken, {
    bool skipTokenRefresh = false,
  }) async {
    if (accessToken.isEmpty) {
      throw const BangumiOAuthException('Access Token 为空');
    }
    try {
      final Response response = await Request().get(
        'https://api.bgm.tv/v0/me',
        options: Options(
          headers: {
            'Authorization': 'Bearer $accessToken',
          },
          extra: {
            'skipBangumiTokenRefresh': skipTokenRefresh,
          },
        ),
        shouldRethrow: true,
      );
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (e) {
      KazumiLogger().e('Bangumi OAuth: fetch current user failed', error: e);
      final responseData = e.response?.data;
      if (responseData is Map && responseData['description'] != null) {
        throw BangumiOAuthException('${responseData['description']}');
      }
      throw const BangumiOAuthException('验证 Bangumi 登录状态失败');
    }
  }

  bool _isLoopbackRedirectUri(Uri uri) {
    final bool isHttp = uri.scheme == 'http';
    final bool isLoopbackHost =
        uri.host == '127.0.0.1' || uri.host == 'localhost';
    return isHttp && isLoopbackHost && uri.hasPort;
  }

  String _buildState() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _buildCallbackHtml(bool success) {
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Bangumi 授权</title>
</head>
<body style="font-family: sans-serif; padding: 24px; line-height: 1.6;">
  <h2>${success ? '授权成功' : '授权失败'}</h2>
  <p>${success ? 'Kazumi 已收到授权结果，你现在可以返回应用继续。' : 'Kazumi 未能完成授权，请返回应用查看错误信息。'}</p>
</body>
</html>
''';
  }
}

class BangumiOAuthException implements Exception {
  final String message;

  const BangumiOAuthException(this.message);

  @override
  String toString() => message;
}
