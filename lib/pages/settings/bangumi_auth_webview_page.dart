import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/request/bangumi_oauth.dart';
import 'package:kazumi/utils/utils.dart';
import 'package:url_launcher/url_launcher.dart';

class BangumiAuthWebViewPage extends StatefulWidget {
  const BangumiAuthWebViewPage({super.key});

  @override
  State<BangumiAuthWebViewPage> createState() => _BangumiAuthWebViewPageState();
}

class _BangumiAuthWebViewPageState extends State<BangumiAuthWebViewPage> {
  final BangumiOAuthService authService = BangumiOAuthService();

  late final BangumiOAuthSession session;
  double progress = 0;
  bool pageLoading = true;
  bool isCompleting = false;
  String lastUrl = '';
  String errorText = '';

  Uri get redirectUri => Uri.parse(session.redirectUri);

  @override
  void initState() {
    super.initState();
    session = Modular.args.data as BangumiOAuthSession;
  }

  bool _isCallbackUri(Uri uri) {
    return uri.scheme == redirectUri.scheme &&
        uri.host == redirectUri.host &&
        uri.port == redirectUri.port &&
        uri.path == redirectUri.path;
  }

  Future<NavigationActionPolicy> _handleNavigation(String rawUrl) async {
    final Uri? uri = Uri.tryParse(rawUrl);
    if (uri == null || !_isCallbackUri(uri)) {
      return NavigationActionPolicy.ALLOW;
    }

    if (isCompleting) {
      return NavigationActionPolicy.CANCEL;
    }

    setState(() {
      isCompleting = true;
      errorText = '';
    });

    try {
      final result = await authService.completeAuthorizationCallback(
        session: session,
        callbackUri: uri,
      );
      if (!mounted) {
        return NavigationActionPolicy.CANCEL;
      }
      Navigator.pop(context, result);
    } catch (e) {
      if (!mounted) {
        return NavigationActionPolicy.CANCEL;
      }
      setState(() {
        errorText = '$e';
      });
      KazumiDialog.showToast(message: '$e');
      Navigator.pop(context);
    } finally {
      if (mounted) {
        setState(() {
          isCompleting = false;
        });
      }
    }
    return NavigationActionPolicy.CANCEL;
  }

  Future<void> _openExternalBrowser() async {
    final bool launched = await launchUrl(
      session.authorizeUri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      KazumiDialog.showToast(message: '无法拉起系统浏览器');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SysAppBar(title: Text('Bangumi 应用内授权')),
      body: Column(
        children: [
          if (pageLoading || isCompleting)
            LinearProgressIndicator(
              value: isCompleting ? null : progress,
              minHeight: 2,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '请在页面内完成 Bangumi 登录与授权。若页面打不开，可改用系统浏览器。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (errorText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    errorText,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        lastUrl.isEmpty ? session.authorizeUri.toString() : lastUrl,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: isCompleting ? null : _openExternalBrowser,
                      icon: const Icon(Icons.open_in_browser_rounded),
                      label: const Text('系统浏览器'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialSettings: InAppWebViewSettings(
                useShouldOverrideUrlLoading: true,
                javaScriptEnabled: true,
                cacheEnabled: true,
                userAgent: Utils.getRandomUA(),
                safeBrowsingEnabled: false,
                upgradeKnownHostsToHTTPS: false,
              ),
              initialUrlRequest: URLRequest(
                url: WebUri(session.authorizeUri.toString()),
              ),
              onLoadStart: (controller, url) {
                if (!mounted) return;
                setState(() {
                  pageLoading = true;
                  lastUrl = url?.toString() ?? '';
                });
              },
              onLoadStop: (controller, url) {
                if (!mounted) return;
                setState(() {
                  pageLoading = false;
                  progress = 1;
                  lastUrl = url?.toString() ?? '';
                });
              },
              onProgressChanged: (controller, value) {
                if (!mounted) return;
                setState(() {
                  progress = value / 100;
                  pageLoading = value < 100;
                });
              },
              onReceivedError: (controller, request, error) {
                final Uri? errorUri = Uri.tryParse(request.url?.toString() ?? '');
                if (!mounted) return;
                setState(() {
                  pageLoading = false;
                  if (errorUri == null || !_isCallbackUri(errorUri)) {
                    errorText = '页面加载失败：${error.description}';
                  }
                });
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                if (!navigationAction.isForMainFrame) {
                  return NavigationActionPolicy.ALLOW;
                }
                final String rawUrl =
                    navigationAction.request.url?.toString() ?? '';
                if (mounted) {
                  setState(() {
                    lastUrl = rawUrl;
                  });
                }
                return _handleNavigation(rawUrl);
              },
            ),
          ),
        ],
      ),
    );
  }
}
