import 'package:flutter/material.dart';
import 'package:kazumi/utils/utils.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/utils/logger.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:kazumi/request/query_manager.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'dart:async';
import 'dart:convert';
import 'package:kazumi/providers/captcha/captcha_provider.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';

class SourceSheet extends StatefulWidget {
  const SourceSheet({
    super.key,
    required this.tabController,
    required this.infoController,
    this.autoQueryOnInit = true,
    this.navigateToVideoPage = true,
    this.onSourceSelected,
  });

  final TabController tabController;
  final InfoController infoController;
  final bool autoQueryOnInit;
  final bool navigateToVideoPage;
  final Future<void> Function()? onSourceSelected;

  @override
  State<SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends State<SourceSheet>
    with SingleTickerProviderStateMixin {
  final VideoPageController videoPageController =
      Modular.get<VideoPageController>();
  final CollectController collectController = Modular.get<CollectController>();
  final PluginsController pluginsController = Modular.get<PluginsController>();
  late String keyword;

  /// Concurrent query manager
  QueryManager? queryManager;

  /// Captcha solving provider (created on demand)
  CaptchaProvider? _captchaProvider;

  /// Timeout timer waiting for captcha verification result
  Timer? _captchaVerifyTimer;

  void _handleTabControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    keyword = widget.infoController.bangumiItem.nameCn == ''
        ? widget.infoController.bangumiItem.name
        : widget.infoController.bangumiItem.nameCn;
    queryManager = QueryManager(infoController: widget.infoController);
    widget.tabController.addListener(_handleTabControllerChanged);
    if (widget.autoQueryOnInit) {
      queryManager?.queryAllSource(keyword);
    }
    super.initState();
  }

  @override
  void dispose() {
    widget.tabController.removeListener(_handleTabControllerChanged);
    queryManager?.cancel();
    queryManager = null;
    _captchaProvider?.dispose();
    _captchaProvider = null;
    _captchaVerifyTimer?.cancel();
    _captchaVerifyTimer = null;
    super.dispose();
  }

  /// 根据插件的验证类型分发到对应的验证对话框
  void showAntiCrawlerDialog(Plugin plugin) {
    switch (plugin.antiCrawlerConfig.captchaType) {
      case CaptchaType.autoClickButton:
        showButtonClickDialog(plugin);
        break;
      default:
        showCaptchaDialog(plugin);
    }
  }

  void showCaptchaDialog(Plugin plugin) {
    final captchaImageNotifier = ValueNotifier<String?>(null);
    final submittingNotifier = ValueNotifier<bool>(false);
    final TextEditingController codeController = TextEditingController();

    /// flag whether verification has passed, used to distinguish normal dismissal from cancellation in onDismiss
    bool verified = false;

    _captchaProvider?.dispose();
    _captchaProvider = CaptchaProvider();

    final searchUrl = plugin.searchURL.replaceAll('@keyword', keyword);

    _captchaProvider!.loadForCaptcha(
      searchUrl,
      plugin.antiCrawlerConfig.captchaImage,
      inputXpath: plugin.antiCrawlerConfig.captchaInput,
    );

    final imageSub = _captchaProvider!.onCaptchaImageUrl.listen((url) {
      if (url != null) captchaImageNotifier.value = url;
    });

    Future<void> doSubmit() async {
      if (submittingNotifier.value) return;
      if (codeController.text.trim().isEmpty) {
        KazumiDialog.showToast(message: '请输入验证码');
        return;
      }
      submittingNotifier.value = true;
      await _captchaProvider?.submitCaptcha(
        captchaCode: codeController.text.trim(),
        inputXpath: plugin.antiCrawlerConfig.captchaInput,
        buttonXpath: plugin.antiCrawlerConfig.captchaButton,
        pluginName: plugin.name,
        onVerified: () {
          _captchaVerifyTimer?.cancel();
          _captchaVerifyTimer = null;
          verified = true;
          KazumiDialog.dismiss();
          // show a 3s countdown progress dialog before re-querying,
          // to avoid triggering rate limits immediately after verification.
          KazumiDialog.showTimedSuccessDialog(
            title: '验证成功',
            message: '正在重新检索，请稍候…',
            onComplete: () => queryManager?.querySource(keyword, plugin.name),
          );
        },
      );
      // submitCaptcha completes after the JS button click is fired.
      // Start the 8-second timeout only NOW, waiting for the webview to
      // detect the captcha disappearing and call onVerified.
      if (!verified) {
        _captchaVerifyTimer?.cancel();
        _captchaVerifyTimer = Timer(const Duration(seconds: 8), () {
          if (!verified) {
            KazumiDialog.dismiss();
          }
        });
      }
    }

    KazumiDialog.show(
      onDismiss: () async {
        _captchaVerifyTimer?.cancel();
        _captchaVerifyTimer = null;
        // Cancel the image subscription before disposing the notifier to
        // prevent late stream events writing to an already-disposed notifier.
        imageSub.cancel();
        codeController.dispose();
        captchaImageNotifier.dispose();
        submittingNotifier.dispose();
        // Capture the current provider instance locally NOW, before any await.
        // Without this, an async gap could allow _captchaProvider to be
        // replaced (or nulled by _SourceSheetState.dispose()), causing the
        // closure to dispose the wrong/already-disposed instance.
        final provider = _captchaProvider;
        _captchaProvider = null;
        if (!verified) {
          await provider?.saveAndUnload(plugin.name);
          provider?.dispose();
          queryManager?.querySource(keyword, plugin.name);
        } else {
          provider?.dispose();
        }
      },
      builder: (context) {
        return Dialog(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '验证码验证',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${plugin.name} 需要验证码验证',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  ValueListenableBuilder<String?>(
                    valueListenable: captchaImageNotifier,
                    builder: (context, imageUrl, _) {
                      if (imageUrl == null) {
                        return const Column(
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 12),
                            Text('正在加载验证码图片...'),
                          ],
                        );
                      }
                      return ValueListenableBuilder<bool>(
                        valueListenable: submittingNotifier,
                        builder: (context, isSubmitting, _) {
                          return Column(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(
                                  base64Decode(imageUrl.split(',').last),
                                  height: 80,
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, _) =>
                                      const Text('图片解码失败'),
                                ),
                              ),
                              const SizedBox(height: 16),
                              TextField(
                                controller: codeController,
                                autofocus: true,
                                enabled: !isSubmitting,
                                decoration: const InputDecoration(
                                  labelText: '请输入验证码',
                                  border: OutlineInputBorder(),
                                ),
                                onSubmitted:
                                    isSubmitting ? null : (_) => doSubmit(),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  ListenableBuilder(
                    listenable: Listenable.merge(
                        [captchaImageNotifier, submittingNotifier]),
                    builder: (context, _) {
                      final isImageLoading = captchaImageNotifier.value == null;
                      final isSubmitting = submittingNotifier.value;
                      final isDisabled = isImageLoading || isSubmitting;
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => KazumiDialog.dismiss(),
                            child: Text(
                              '取消',
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.outline),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: isDisabled ? null : doSubmit,
                            child: isSubmitting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('提交'),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void showButtonClickDialog(Plugin plugin) {
    /// flag whether onVerified was fired by the auto-click flow (cookies already saved + page unloaded)
    bool autoVerified = false;

    _captchaProvider?.dispose();
    _captchaProvider = CaptchaProvider();

    final searchUrl = plugin.searchURL.replaceAll('@keyword', keyword);

    void onVerified() {
      if (autoVerified) return;
      autoVerified = true;
      KazumiDialog.dismiss();
      // show a 3s countdown progress dialog before re-querying
      KazumiDialog.showTimedSuccessDialog(
        title: '验证成功',
        message: '正在重新检索，请稍候…',
        onComplete: () => queryManager?.querySource(keyword, plugin.name),
      );
    }

    _captchaProvider!.loadForButtonClick(
      url: searchUrl,
      buttonXpath: plugin.antiCrawlerConfig.captchaButton,
      pluginName: plugin.name,
      onVerified: onVerified,
    );

    KazumiDialog.show(
      onDismiss: () async {
        // Capture the current provider instance locally before any await.
        final provider = _captchaProvider;
        _captchaProvider = null;
        if (autoVerified) {
          // auto-verify already saved cookies and unloaded the page
          provider?.dispose();
        } else {
          // save whatever cookies are present and unload the page
          await provider?.saveAndUnload(plugin.name);
          provider?.dispose();
          queryManager?.querySource(keyword, plugin.name);
        }
      },
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '自动验证中',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  '${plugin.name} 正在自动完成验证，请稍候',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text(
                  '已检测到验证按钮并模拟点击，等待验证通过…',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => KazumiDialog.dismiss(),
                    child: Text(
                      '取消',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _statusColor(String? status) {
    return switch (status) {
      'success' => Colors.green,
      'noResult' => Colors.orange,
      'captcha' => Colors.blue,
      'error' => Colors.red,
      _ => Colors.grey,
    };
  }

  String _statusText(String? status) {
    return switch (status) {
      'success' => '可用',
      'noResult' => '无结果',
      'captcha' => '需验证',
      'error' => '失败',
      'pending' => '检索中',
      _ => '等待中',
    };
  }

  int _resultCountOfPlugin(String pluginName) {
    for (final response in widget.infoController.pluginSearchResponseList) {
      if (response.pluginName == pluginName) {
        return response.data.length;
      }
    }
    return 0;
  }

  Widget _buildSourceTabChip({
    required BuildContext context,
    required Plugin plugin,
    required bool selected,
  }) {
    final status = widget.infoController.pluginSearchStatus[plugin.name];
    final count = _resultCountOfPlugin(plugin.name);
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = selected
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest;
    final foregroundColor = selected
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.35)
              : colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              plugin.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: foregroundColor,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _statusColor(status),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            count > 0 ? '$count' : _statusText(status),
            style: TextStyle(
              fontSize: 11,
              color: foregroundColor.withValues(alpha: 0.82),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildPluginView(Plugin plugin, List<Widget> cardList) {
    final status =
        widget.infoController.pluginSearchStatus[plugin.name];
    if (status == 'pending') {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text('${plugin.name} 检索中...'),
          ],
        ),
      );
    }
    if (status == 'captcha') {
      return GeneralErrorWidget(
        errMsg: '${plugin.name} 需要验证码验证',
        actions: [
          GeneralErrorButton(
            onPressed: () => showAntiCrawlerDialog(plugin),
            text: '进行验证',
          ),
          GeneralErrorButton(
            onPressed: () => queryManager?.querySource(keyword, plugin.name),
            text: '重试',
          ),
        ],
      );
    }
    if (status == 'noResult') {
      return GeneralErrorWidget(
        errMsg: '${plugin.name} 无结果 使用别名或左右滑动以切换到其他视频来源',
        actions: [
          GeneralErrorButton(
            onPressed: () => showAliasSearchDialog(plugin.name),
            text: '别名检索',
          ),
          GeneralErrorButton(
            onPressed: () => showCustomSearchDialog(plugin.name),
            text: '手动检索',
          ),
        ],
      );
    }
    if (status == 'error') {
      return GeneralErrorWidget(
        errMsg: '${plugin.name} 检索失败 重试或左右滑动以切换到其他视频来源',
        actions: [
          GeneralErrorButton(
            onPressed: () => queryManager?.querySource(keyword, plugin.name),
            text: '重试',
          ),
        ],
      );
    }
    if (cardList.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 48),
          GeneralErrorWidget(
            errMsg: '暂无来源，请下拉刷新或切换来源',
            actions: [
              GeneralErrorButton(
                onPressed: () => queryManager?.querySource(keyword, plugin.name),
                text: '刷新',
              ),
            ],
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: () async {
        await queryManager?.querySource(keyword, plugin.name);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: cardList,
      ),
    );
  }

  void showAliasSearchDialog(String pluginName) {
    if (widget.infoController.bangumiItem.alias.isEmpty) {
      KazumiDialog.showToast(message: '无可用别名，试试手动检索');
      return;
    }
    final aliasNotifier =
        ValueNotifier<List<String>>(widget.infoController.bangumiItem.alias);
    KazumiDialog.show(builder: (context) {
      return Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 560,
          child: ValueListenableBuilder<List<String>>(
            valueListenable: aliasNotifier,
            builder: (context, aliasList, child) {
              return ListView(
                shrinkWrap: true,
                children: aliasList.asMap().entries.map((entry) {
                  final index = entry.key;
                  final alias = entry.value;
                  return ListTile(
                    title: Text(alias),
                    trailing: IconButton(
                      onPressed: () {
                        KazumiDialog.show(
                          builder: (context) {
                            return AlertDialog(
                              title: const Text('删除确认'),
                              content: const Text('删除后无法恢复，确认要永久删除这个别名吗？'),
                              actions: [
                                TextButton(
                                  onPressed: () {
                                    KazumiDialog.dismiss();
                                  },
                                  child: Text(
                                    '取消',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .outline),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    KazumiDialog.dismiss();
                                    aliasList.removeAt(index);
                                    aliasNotifier.value = List.from(aliasList);
                                    collectController.updateLocalCollect(
                                        widget.infoController.bangumiItem);
                                    if (aliasList.isEmpty) {
                                      // pop whole dialog when empty
                                      Navigator.of(context).pop();
                                    }
                                  },
                                  child: const Text('确认'),
                                ),
                              ],
                            );
                          },
                        );
                      },
                      icon: Icon(Icons.delete),
                    ),
                    onTap: () {
                      KazumiDialog.dismiss();
                      queryManager?.querySource(alias, pluginName);
                    },
                  );
                }).toList(),
              );
            },
          ),
        ),
      );
    });
  }

  void showCustomSearchDialog(String pluginName) {
    KazumiDialog.show(
      builder: (context) {
        final TextEditingController textController = TextEditingController();
        return AlertDialog(
          title: const Text('输入别名'),
          content: TextField(
            controller: textController,
            onSubmitted: (keyword) {
              if (textController.text != '') {
                widget.infoController.bangumiItem.alias
                    .add(textController.text);
                KazumiDialog.dismiss();
                queryManager?.querySource(textController.text, pluginName);
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                KazumiDialog.dismiss();
              },
              child: Text(
                '取消',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            TextButton(
              onPressed: () {
                if (textController.text != '') {
                  widget.infoController.bangumiItem.alias
                      .add(textController.text);
                  collectController
                      .updateLocalCollect(widget.infoController.bangumiItem);
                  KazumiDialog.dismiss();
                  queryManager?.querySource(textController.text, pluginName);
                }
              },
              child: const Text(
                '确认',
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Observer(builder: (context) {
            final total = pluginsController.pluginList.length;
            final completed = widget.infoController.pluginSearchStatus.values
                .where((status) =>
                    status == 'success' ||
                    status == 'noResult' ||
                    status == 'captcha' ||
                    status == 'error')
                .length;
            final totalResults = widget.infoController.pluginSearchResponseList
                .fold<int>(0, (sum, item) => sum + item.data.length);
            return Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          keyword,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '已完成 $completed/$total · 共 $totalResults 条结果',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新当前来源',
                    onPressed: () async {
                      if (pluginsController.pluginList.isEmpty) {
                        return;
                      }
                      final currentIndex = widget.tabController.index;
                      await queryManager?.querySource(
                        keyword,
                        pluginsController.pluginList[currentIndex].name,
                      );
                    },
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    tooltip: '全部重试',
                    onPressed: () => queryManager?.queryAllSource(keyword),
                    icon: const Icon(Icons.restart_alt_rounded),
                  ),
                  IconButton(
                    tooltip: '浏览器打开当前来源',
                    onPressed: () {
                      if (pluginsController.pluginList.isEmpty) {
                        return;
                      }
                      final currentIndex = widget.tabController.index;
                      launchUrl(
                        Uri.parse(pluginsController
                            .pluginList[currentIndex].searchURL
                            .replaceFirst('@keyword', keyword)),
                        mode: LaunchMode.externalApplication,
                      );
                    },
                    icon: const Icon(Icons.open_in_browser_rounded),
                  ),
                ],
              ),
            );
          }),
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(18),
            ),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              dividerHeight: 0,
              indicatorColor: Colors.transparent,
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
              padding: EdgeInsets.zero,
              labelPadding: const EdgeInsets.only(right: 8),
              controller: widget.tabController,
              tabs: List.generate(pluginsController.pluginList.length, (index) {
                final plugin = pluginsController.pluginList[index];
                return Tab(
                  height: 46,
                  child: Observer(
                    builder: (context) => _buildSourceTabChip(
                      context: context,
                      plugin: plugin,
                      selected: widget.tabController.index == index,
                    ),
                  ),
                );
              }),
            ),
          ),
            const Divider(height: 1),
            Expanded(
              child: Observer(
                builder: (context) => TabBarView(
                  controller: widget.tabController,
                  children: List.generate(pluginsController.pluginList.length,
                      (pluginIndex) {
                    var plugin = pluginsController.pluginList[pluginIndex];
                    var cardList = <Widget>[];
                    for (var searchResponse
                        in widget.infoController.pluginSearchResponseList) {
                      if (searchResponse.pluginName == plugin.name) {
                        for (var i = 0; i < searchResponse.data.length; i++) {
                          final searchItem = searchResponse.data[i];
                          final isCurrent =
                              !videoPageController.isOfflineMode &&
                                  videoPageController.currentPlugin.name ==
                                      plugin.name &&
                                  videoPageController.src == searchItem.src;
                          cardList.add(
                            Container(
                              margin: const EdgeInsets.only(
                                  left: 12, right: 12, top: 10),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(16),
                                  onTap: () async {
                                    KazumiDialog.showLoading(
                                      msg: '获取中',
                                      barrierDismissible: Utils.isDesktop(),
                                      onDismiss: () {
                                        videoPageController.cancelQueryRoads();
                                      },
                                    );
                                    try {
                                      await videoPageController.selectSource(
                                        bangumiItem:
                                            widget.infoController.bangumiItem,
                                        plugin: plugin,
                                        searchItem: searchItem,
                                      );
                                      KazumiDialog.dismiss();
                                      if (widget.navigateToVideoPage) {
                                        Modular.to.pushNamed('/video/');
                                      } else {
                                        final onSourceSelected =
                                            widget.onSourceSelected;
                                        if (onSourceSelected != null) {
                                          await onSourceSelected();
                                        }
                                      }
                                    } catch (_) {
                                      KazumiLogger().w(
                                          "QueryManager: failed to query video playlist");
                                      KazumiDialog.dismiss();
                                    }
                                  },
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 180),
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: isCurrent
                                          ? Theme.of(context)
                                              .colorScheme
                                              .primaryContainer
                                          : Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerLow,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: isCurrent
                                            ? Theme.of(context)
                                                .colorScheme
                                                .primary
                                            : Theme.of(context)
                                                .colorScheme
                                                .outlineVariant
                                                .withValues(alpha: 0.45),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 34,
                                          height: 34,
                                          alignment: Alignment.center,
                                          decoration: BoxDecoration(
                                            color: isCurrent
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                                : Theme.of(context)
                                                    .colorScheme
                                                    .surfaceContainerHighest,
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: Text(
                                            '${i + 1}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: isCurrent
                                                  ? Theme.of(context)
                                                      .colorScheme
                                                      .onPrimary
                                                  : Theme.of(context)
                                                      .colorScheme
                                                      .onSurface,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      searchItem.name,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontWeight: isCurrent
                                                            ? FontWeight.w700
                                                            : FontWeight.w600,
                                                        color: isCurrent
                                                            ? Theme.of(context)
                                                                .colorScheme
                                                                .primary
                                                            : null,
                                                      ),
                                                    ),
                                                  ),
                                                  if (isCurrent) ...[
                                                    const SizedBox(width: 8),
                                                    Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                              horizontal: 8,
                                                              vertical: 4),
                                                      decoration: BoxDecoration(
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .primary,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                                999),
                                                      ),
                                                      child: Text(
                                                        '当前',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          color: Theme.of(context)
                                                              .colorScheme
                                                              .onPrimary,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                searchItem.src.isEmpty
                                                    ? '点击切换到该来源'
                                                    : searchItem.src,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Icon(
                                          isCurrent
                                              ? Icons.check_circle_rounded
                                              : Icons.play_circle_fill_rounded,
                                          color: isCurrent
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
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
                    }
                    return buildPluginView(plugin, cardList);
                  }),
                ),
              ),
            )
          ],
        ),
    );
  }
}
