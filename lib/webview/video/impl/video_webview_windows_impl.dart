import 'dart:async';
import 'package:webview_windows/webview_windows.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:kazumi/utils/storage.dart';
import 'package:kazumi/utils/proxy_utils.dart';
import 'package:kazumi/utils/logger.dart';

class VideoWebviewWindowsImpl
    extends VideoWebviewController<WebviewController> {
  final List<StreamSubscription> subscriptions = [];

  HeadlessWebview? headlessWebview;

  @override
  Future<void> init() async {
    await _setupProxy();
    await _ensureHeadlessWebviewReady();
    initEventController.add(true);
  }

  Future<void> _ensureHeadlessWebviewReady({bool forceRecreate = false}) async {
    if (forceRecreate) {
      await _disposeHeadlessWebview();
    }
    if (headlessWebview != null) {
      return;
    }

    final HeadlessWebview nextHeadlessWebview = HeadlessWebview();
    await nextHeadlessWebview.run();
    await nextHeadlessWebview
        .setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
    headlessWebview = nextHeadlessWebview;
  }

  Future<void> _disposeHeadlessWebview() async {
    final currentHeadlessWebview = headlessWebview;
    headlessWebview = null;
    if (currentHeadlessWebview == null) {
      return;
    }
    try {
      currentHeadlessWebview.dispose();
    } catch (_) {}
  }

  void _resetSourceSubscriptions() {
    for (final subscription in subscriptions) {
      try {
        subscription.cancel();
      } catch (_) {}
    }
    subscriptions.clear();
  }

  bool _isHeadlessWebviewNotRunningError(Object error) {
    return error.toString().contains('HeadlessWebview is not running');
  }

  void _attachSourceSubscriptions() {
    final currentHeadlessWebview = headlessWebview;
    if (currentHeadlessWebview == null) {
      return;
    }

    subscriptions.add(currentHeadlessWebview.onM3USourceLoaded.listen((data) {
      if (headlessWebview == null) return;
      String url = data['url'] ?? '';
      if (url.isEmpty) {
        return;
      }
      unloadPage();
      isIframeLoaded = true;
      isVideoSourceLoaded = true;
      videoLoadingEventController.add(false);
      logEventController.add('Loading m3u8 source: $url');
      videoParserEventController.add((url, offset));
    }));
    subscriptions.add(currentHeadlessWebview.onVideoSourceLoaded.listen((data) {
      if (headlessWebview == null) return;
      String url = data['url'] ?? '';
      if (url.isEmpty) {
        return;
      }
      unloadPage();
      isIframeLoaded = true;
      isVideoSourceLoaded = true;
      videoLoadingEventController.add(false);
      logEventController.add('Loading video source: $url');
      videoParserEventController.add((url, offset));
    }));
  }

  Future<void> _setupProxy() async {
    final setting = GStorage.setting;
    final bool proxyEnable =
        setting.get(SettingBoxKey.proxyEnable, defaultValue: false);
    if (!proxyEnable) {
      return;
    }

    final String proxyUrl =
        setting.get(SettingBoxKey.proxyUrl, defaultValue: '');
    final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
    if (formattedProxy == null) {
      return;
    }

    try {
      await WebviewController.initializeEnvironment(
        additionalArguments: '--proxy-server=$formattedProxy',
      );
      KazumiLogger().i('WebView: 代理设置成功 $formattedProxy');
    } catch (e) {
      KazumiLogger().e('WebView: 设置代理失败 $e');
    }
  }

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    count = 0;
    this.offset = offset;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;
    videoLoadingEventController.add(true);
    await _ensureHeadlessWebviewReady();
    _resetSourceSubscriptions();
    _attachSourceSubscriptions();
    try {
      await headlessWebview!.loadUrl(url);
    } catch (e) {
      if (!_isHeadlessWebviewNotRunningError(e)) {
        rethrow;
      }
      KazumiLogger().w(
        'WebView: headless webview was not running, recreating instance',
        error: e,
      );
      await _ensureHeadlessWebviewReady(forceRecreate: true);
      _resetSourceSubscriptions();
      _attachSourceSubscriptions();
      await headlessWebview!.loadUrl(url);
    }
  }

  @override
  Future<void> unloadPage() async {
    _resetSourceSubscriptions();
    await redirect2Blank();
  }

  @override
  void dispose() {
    _resetSourceSubscriptions();
    unawaited(_disposeHeadlessWebview());
  }

  // The webview_windows package does not have a method to unload the current page.
  // The loadUrl method opens a new tab, which can lead to memory leaks.
  // Directly disposing of the webview controller would require reinitialization when switching episodes, which is costly.
  // Therefore, this method is used to redirect to a blank page instead.
  Future<void> redirect2Blank() async {
    if (headlessWebview == null) return;
    try {
      await headlessWebview!.executeScript('''
        window.location.href = 'about:blank';
      ''');
    } catch (e) {
      if (_isHeadlessWebviewNotRunningError(e)) {
        await _disposeHeadlessWebview();
      }
      KazumiLogger().d('WebView: redirect2Blank skipped (likely disposed): $e');
    }
  }
}
