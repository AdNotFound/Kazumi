import 'dart:async';

import 'package:dio/dio.dart';
import 'package:kazumi/request/api.dart';
import 'package:kazumi/request/bangumi_oauth.dart';
import 'package:kazumi/request/request.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/utils/storage.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:kazumi/utils/utils.dart';
import 'package:kazumi/utils/mortis.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/logger.dart';

class ApiInterceptor extends Interceptor {
  static Box setting = GStorage.setting;
  static const String _skipBangumiTokenRefreshKey = 'skipBangumiTokenRefresh';
  static const String _bangumiRetriedKey = 'bangumiRetried';
  static final BangumiOAuthService _bangumiOAuthService =
      BangumiOAuthService();
  static Future<void>? _refreshingFuture;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    // Github mirror
    if (options.path.contains('github')) {
      bool enableGitProxy =
          setting.get(SettingBoxKey.enableGitProxy, defaultValue: false);
      if (enableGitProxy) {
        options.path = Api.gitMirror + options.path;
      }
    }
    if (options.path.contains(Api.dandanAPIDomain)) {
      var timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      options.headers = {
        'user-agent': Utils.getRandomUA(),
        'referer': '',
        'X-Auth': 1,
        'X-AppId': mortis['id'],
        'X-Timestamp': timestamp,
        'X-Signature': Utils.generateDandanSignature(
            Uri.parse(options.path).path, timestamp),
      };
    }
    if (isBangumiRequest(options.path)) {
      await _maybeRefreshBangumiToken(options);
      final headers = Map<String, dynamic>.from(bangumiHTTPHeader);
      final String accessToken =
          setting.get(SettingBoxKey.bangumiAccessToken, defaultValue: '');
      if (accessToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $accessToken';
      }
      if (options.headers.isNotEmpty) {
        headers.addAll(options.headers);
      }
      options.headers = headers;
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (shouldRetryBangumiUnauthorized(
      requestOptions: err.requestOptions,
      statusCode: err.response?.statusCode,
    )) {
      try {
        await _refreshBangumiToken();
        final response = await _retryBangumiRequest(err.requestOptions);
        handler.resolve(response);
        return;
      } catch (error, stackTrace) {
        await _handleBangumiRefreshFailure(error, stackTrace);
      }
    }

    String url = err.requestOptions.uri.toString();
    if (!url.contains('heartBeat') &&
        err.requestOptions.extra['customError'] != '') {
      if (err.requestOptions.extra['customError'] == null) {
        KazumiDialog.showToast(
          message: await dioError(err),
        );
      } else {
        KazumiDialog.showToast(
          message: err.requestOptions.extra['customError'],
        );
      }
    }
    super.onError(err, handler);
  }

  static Future<String> dioError(DioException error) async {
    bool proxyEnable =
        await setting.get(SettingBoxKey.proxyEnable, defaultValue: false);
    if (proxyEnable) {
      return '代理连接异常，请检查代理设置';
    }
    switch (error.type) {
      case DioExceptionType.badCertificate:
        return '证书有误！';
      case DioExceptionType.badResponse:
        return '服务器异常，请稍后重试！';
      case DioExceptionType.cancel:
        return '请求已被取消，请重新请求';
      case DioExceptionType.connectionError:
        return '连接错误，请检查网络设置';
      case DioExceptionType.connectionTimeout:
        return '网络连接超时，请检查网络设置';
      case DioExceptionType.receiveTimeout:
        return '响应超时，请稍后重试！';
      case DioExceptionType.sendTimeout:
        return '发送请求超时，请检查网络设置';
      case DioExceptionType.unknown:
        final String res = await checkConnect();
        return '$res 网络异常';
    }
  }

  static Future<String> checkConnect() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.mobile)) {
      return '正在使用移动流量';
    }
    if (connectivityResult.contains(ConnectivityResult.wifi)) {
      return '正在使用wifi';
    }
    if (connectivityResult.contains(ConnectivityResult.ethernet)) {
      return '正在使用局域网';
    }
    if (connectivityResult.contains(ConnectivityResult.vpn)) {
      return '正在使用代理网络';
    }
    if (connectivityResult.contains(ConnectivityResult.other)) {
      return '正在使用其他网络';
    }
    if (connectivityResult.contains(ConnectivityResult.none)) {
      return '未连接到任何网络';
    }
    return '';
  }

  static bool isBangumiRequest(String url) {
    return url.contains(Api.bangumiAPIDomain) ||
        url.contains(Api.bangumiAPINextDomain);
  }

  static bool shouldRetryBangumiUnauthorized({
    required RequestOptions requestOptions,
    required int? statusCode,
  }) {
    return statusCode == 401 &&
        isBangumiRequest(requestOptions.path) &&
        requestOptions.extra[_skipBangumiTokenRefreshKey] != true &&
        requestOptions.extra[_bangumiRetriedKey] != true;
  }

  static Future<void> _maybeRefreshBangumiToken(RequestOptions options) async {
    if (options.extra[_skipBangumiTokenRefreshKey] == true) {
      return;
    }
    if (!_bangumiOAuthService.hasRefreshToken()) {
      return;
    }
    if (!_bangumiOAuthService.shouldRefreshToken()) {
      return;
    }
    try {
      await _refreshBangumiToken();
    } catch (error, stackTrace) {
      KazumiLogger().w(
        'Bangumi OAuth: pre-refresh failed, keep using current token',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static Future<void> _refreshBangumiToken() async {
    final refreshingFuture = _refreshingFuture;
    if (refreshingFuture != null) {
      return refreshingFuture;
    }
    final future = _bangumiOAuthService.refreshAccessToken();
    _refreshingFuture = future.then((_) {});
    try {
      await _refreshingFuture;
    } finally {
      _refreshingFuture = null;
    }
  }

  static Future<Response<dynamic>> _retryBangumiRequest(
    RequestOptions requestOptions,
  ) async {
    final headers = Map<String, dynamic>.from(requestOptions.headers);
    final extra = Map<String, dynamic>.from(requestOptions.extra);
    final String accessToken =
        setting.get(SettingBoxKey.bangumiAccessToken, defaultValue: '');
    if (accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    extra[_bangumiRetriedKey] = true;
    requestOptions.headers = headers;
    requestOptions.extra = extra;
    return Request.dio.fetch<dynamic>(requestOptions);
  }

  static Future<void> _handleBangumiRefreshFailure(
    Object error,
    StackTrace stackTrace,
  ) async {
    KazumiLogger().w(
      'Bangumi OAuth: refresh after unauthorized failed',
      error: error,
      stackTrace: stackTrace,
    );
    await _bangumiOAuthService.logout();
    KazumiDialog.showToast(message: 'Bangumi 登录已过期，请重新授权');
  }
}
