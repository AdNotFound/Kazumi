import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/request/bangumi_oauth.dart';
import 'package:kazumi/utils/storage.dart';

class BangumiAuthSettingsPage extends StatefulWidget {
  const BangumiAuthSettingsPage({super.key});

  @override
  State<BangumiAuthSettingsPage> createState() => _BangumiAuthSettingsPageState();
}

class _BangumiAuthSettingsPageState extends State<BangumiAuthSettingsPage> {
  final Box setting = GStorage.setting;
  final BangumiOAuthService authService = BangumiOAuthService();
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController clientIdController;
  late final TextEditingController clientSecretController;
  late final TextEditingController redirectUriController;

  bool isLoading = false;
  bool passwordVisible = false;
  String username = '';
  String nickname = '';
  int expiresAt = 0;

  bool get _supportsInAppAuth =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    clientIdController = TextEditingController(
      text: setting.get(SettingBoxKey.bangumiOauthClientId, defaultValue: ''),
    );
    clientSecretController = TextEditingController(
      text: setting.get(
        SettingBoxKey.bangumiOauthClientSecret,
        defaultValue: '',
      ),
    );
    redirectUriController = TextEditingController(
      text: setting.get(
        SettingBoxKey.bangumiOauthRedirectUri,
        defaultValue: BangumiOAuthService.defaultRedirectUri,
      ),
    );
    _loadStatus();
  }

  @override
  void dispose() {
    clientIdController.dispose();
    clientSecretController.dispose();
    redirectUriController.dispose();
    super.dispose();
  }

  void _loadStatus() {
    username = setting.get(SettingBoxKey.bangumiUsername, defaultValue: '');
    nickname = setting.get(SettingBoxKey.bangumiNickname, defaultValue: '');
    expiresAt = setting.get(SettingBoxKey.bangumiTokenExpiresAt, defaultValue: 0);
    if (mounted) {
      setState(() {});
    }
  }

  Future<bool> _saveBasicConfig() async {
    if (!_formKey.currentState!.validate()) {
      return false;
    }
    await setting.put(
      SettingBoxKey.bangumiOauthClientId,
      clientIdController.text.trim(),
    );
    await setting.put(
      SettingBoxKey.bangumiOauthClientSecret,
      clientSecretController.text.trim(),
    );
    await setting.put(
      SettingBoxKey.bangumiOauthRedirectUri,
      redirectUriController.text.trim(),
    );
    return true;
  }

  Future<void> _startInAppAuth() async {
    if (!_supportsInAppAuth) {
      await _startBrowserAuth();
      return;
    }
    if (isLoading) return;
    try {
      setState(() {
        isLoading = true;
      });
      final saved = await _saveBasicConfig();
      if (!saved) {
        return;
      }
      final session = await authService.createAuthorizationSession();
      if (!mounted) return;
      final result = await Modular.to.pushNamed(
        '/settings/bangumi-auth/webview',
        arguments: session,
      );
      _loadStatus();
      if (!mounted || result is! BangumiOAuthResult) return;
      KazumiDialog.showToast(
        message: 'Bangumi 登录成功：${result.nickname.isEmpty ? result.username : result.nickname}',
      );
    } catch (e) {
      if (!mounted) return;
      KazumiDialog.showToast(message: '$e');
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> _startBrowserAuth() async {
    if (isLoading) return;
    try {
      setState(() {
        isLoading = true;
      });
      final saved = await _saveBasicConfig();
      if (!saved) {
        return;
      }
      final result = await authService.authorizeInBrowser();
      _loadStatus();
      if (!mounted) return;
      KazumiDialog.showToast(
        message: 'Bangumi 登录成功：${result.nickname.isEmpty ? result.username : result.nickname}',
      );
    } catch (e) {
      if (!mounted) return;
      KazumiDialog.showToast(message: '$e');
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> _verifyCurrentLogin() async {
    if (isLoading) return;
    try {
      setState(() {
        isLoading = true;
      });
      final result = await authService.verifyCurrentLogin();
      _loadStatus();
      if (!mounted) return;
      KazumiDialog.showToast(
        message: '当前已登录：${result.nickname.isEmpty ? result.username : result.nickname}',
      );
    } catch (e) {
      if (!mounted) return;
      KazumiDialog.showToast(message: '$e');
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> _logout() async {
    await authService.logout();
    _loadStatus();
    if (!mounted) return;
    KazumiDialog.showToast(message: '已退出 Bangumi 登录');
  }

  String _buildStatusText() {
    final String accessToken =
        setting.get(SettingBoxKey.bangumiAccessToken, defaultValue: '');
    if (accessToken.isEmpty || username.isEmpty) {
      return '当前未登录';
    }

    final expiryText = expiresAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(expiresAt).toLocal().toString()
        : '未知';
    final displayName = nickname.isEmpty ? username : '$nickname (@$username)';
    return '已登录：$displayName\nToken 过期时间：$expiryText';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const SysAppBar(title: Text('Bangumi 授权登录')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: MediaQuery.of(context).size.width > 900 ? 900 : null,
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '说明：Bangumi 授权登录需要你先在 Bangumi 开发者平台创建应用，并将回调地址配置为本页填写的 Redirect URI。\n\n当前默认使用应用内 WebView 打开授权页；若系统环境不兼容，可退回系统浏览器授权。',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: clientIdController,
                    decoration: const InputDecoration(
                      labelText: 'Client ID',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return '请输入 Client ID';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: clientSecretController,
                    obscureText: !passwordVisible,
                    decoration: InputDecoration(
                      labelText: 'Client Secret',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        onPressed: () {
                          setState(() {
                            passwordVisible = !passwordVisible;
                          });
                        },
                        icon: Icon(
                          passwordVisible
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                        ),
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return '请输入 Client Secret';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: redirectUriController,
                    decoration: const InputDecoration(
                      labelText: 'Redirect URI',
                      hintText: BangumiOAuthService.defaultRedirectUri,
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return '请输入 Redirect URI';
                      }
                      final uri = Uri.tryParse(value.trim());
                      if (uri == null ||
                          uri.scheme != 'http' ||
                          !(uri.host == '127.0.0.1' || uri.host == 'localhost') ||
                          !uri.hasPort) {
                        return '当前仅支持 http://127.0.0.1:端口/路径 或 localhost';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.account_circle_rounded),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _buildStatusText(),
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: isLoading
                            ? null
                            : (_supportsInAppAuth
                                ? _startInAppAuth
                                : _startBrowserAuth),
                        icon: Icon(_supportsInAppAuth
                            ? Icons.web_rounded
                            : Icons.open_in_browser_rounded),
                        label: Text(
                          isLoading
                              ? '授权中…'
                              : (_supportsInAppAuth
                                  ? '应用内授权登录'
                                  : '浏览器授权登录'),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: isLoading ? null : _startBrowserAuth,
                        icon: const Icon(Icons.open_in_browser_rounded),
                        label: const Text('浏览器授权登录'),
                      ),
                      OutlinedButton.icon(
                        onPressed: isLoading
                            ? null
                            : () async {
                                final saved = await _saveBasicConfig();
                                if (!saved || !mounted) return;
                                KazumiDialog.showToast(message: '配置已保存');
                              },
                        icon: const Icon(Icons.save_rounded),
                        label: const Text('保存配置'),
                      ),
                      OutlinedButton.icon(
                        onPressed: isLoading ? null : _verifyCurrentLogin,
                        icon: const Icon(Icons.verified_user_rounded),
                        label: const Text('校验当前登录'),
                      ),
                      OutlinedButton.icon(
                        onPressed: isLoading ? null : _logout,
                        icon: const Icon(Icons.logout_rounded),
                        label: const Text('退出登录'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
