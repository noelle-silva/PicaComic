import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/image_loader/cached_image.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/time.dart';
import 'package:pica_comic/tools/translations.dart';

import 'comic_page.dart';
import 'server_subscription_dialogs.dart';

/// 服务器订阅管理页：查看订阅、切换级别/频率、立即检查、更新历史、取消订阅。
class ServerSubscriptionsPage extends StatefulWidget {
  const ServerSubscriptionsPage({super.key});

  @override
  State<ServerSubscriptionsPage> createState() =>
      _ServerSubscriptionsPageState();
}

class _ServerSubscriptionsPageState extends State<ServerSubscriptionsPage> {
  bool loading = true;
  String? error;
  List<ServerSubscription> subscriptions = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!PicaServer.instance.enabled) {
      setState(() {
        loading = false;
        error = "未配置服务器".tl;
        subscriptions = const [];
      });
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final list = await PicaServer.instance.listSubscriptions();
      if (!mounted) return;
      setState(() {
        subscriptions = list;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  Future<void> _edit(ServerSubscription sub) async {
    final result = await showSubscriptionEditDialog(
      context,
      autoDownload: sub.autoDownload,
      intervalMinutes: sub.intervalMinutes,
      allowRemove: true,
    );
    if (result == null || !mounted) return;
    if (result.remove) {
      showConfirmDialog(
        context,
        "取消订阅".tl,
        "不再检查该漫画的更新，确定取消？".tl,
        () async {
          try {
            await PicaServer.instance
                .removeSubscription(source: sub.source, target: sub.target);
            showToast(message: "已取消订阅".tl);
            await _load();
          } catch (e) {
            showToast(message: e.toString());
          }
        },
      );
      return;
    }
    try {
      await PicaServer.instance.updateSubscription(
        source: sub.source,
        target: sub.target,
        autoDownload: result.autoDownload,
        intervalMinutes: result.intervalMinutes,
        clearInterval: result.intervalMinutes == null,
      );
      showToast(message: "已保存".tl);
      await _load();
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  void _openSourcePage(ServerSubscription sub) {
    context.to(() => ComicPage(
          sourceKey: sub.source,
          id: sub.target,
          cover: sub.cover,
        ));
  }

  Future<void> _checkNow(ServerSubscription sub) async {
    final dialog = showLoadingDialog(
      context,
      barrierDismissible: false,
      allowCancel: false,
      message: "检查中".tl,
    );
    ServerSubscriptionCheckResult? result;
    try {
      result = await PicaServer.instance
          .checkSubscriptionNow(source: sub.source, target: sub.target);
    } catch (e) {
      dialog.close();
      showToast(message: e.toString());
      return;
    }
    dialog.close();
    if (!mounted) return;
    await _load();
    if (!mounted || result == null) return;
    _showCheckResult(result);
  }

  void _showCheckResult(ServerSubscriptionCheckResult r) {
    final time = r.checkedAt == null
        ? ''
        : timeToString(DateTime.fromMillisecondsSinceEpoch(r.checkedAt!));
    final lines = <String>[];
    String title;
    if (r.status == 'failed') {
      title = "检查失败".tl;
      if (r.message != null && r.message!.isNotEmpty) {
        lines.add(r.message!);
      }
    } else if (r.status == 'busy') {
      title = "检查进行中".tl;
      lines.add("该订阅正在进行检查，请稍后再试".tl);
    } else if (r.status == 'updated') {
      title = "发现更新".tl;
      lines.add("新增 @num 个内容：@items".tlParams({
        "num": r.newItems.length.toString(),
        "items": r.newItems.join("、"),
      }));
      if (r.totalItems != null) {
        lines.add("当前共 @num 话".tlParams({"num": r.totalItems.toString()}));
      }
      if (r.latestItem != null) {
        lines.add("最新：${r.latestItem}");
      }
      if (time.isNotEmpty) {
        lines.add("检查时间：$time");
      }
    } else {
      title = r.firstCheck ? "首次检查完成".tl : "检查完成".tl;
      if (r.firstCheck && r.totalItems != null) {
        lines.add("已记录当前内容：共 @num 话"
            .tlParams({"num": r.totalItems.toString()}));
      } else {
        lines.add("没有发现新内容".tl);
        if (r.totalItems != null) {
          lines.add("当前共 @num 话".tlParams({"num": r.totalItems.toString()}));
        }
      }
      if (r.latestItem != null) {
        lines.add("最新：${r.latestItem}");
      }
      if (time.isNotEmpty) {
        lines.add("检查时间：$time");
      }
    }
    final recentTable = _buildRecentTable(r);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(lines.join("\n")),
            if (recentTable != null) ...[
              const SizedBox(height: 14),
              Text(
                "最近更新".tl,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 6),
              recentTable,
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text("知道了".tl),
          ),
        ],
      ),
    );
  }

  Widget? _buildRecentTable(ServerSubscriptionCheckResult r) {
    if (r.recentItems.isEmpty) return null;
    Widget cell(String text, {bool header = false}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: header ? FontWeight.w600 : null,
            ),
          ),
        );
    return Table(
      border: TableBorder.all(
        color: Theme.of(context).colorScheme.outlineVariant,
        width: 0.5,
      ),
      columnWidths: const {
        0: IntrinsicColumnWidth(),
        1: FlexColumnWidth(),
      },
      children: [
        TableRow(children: [
          cell("话".tl, header: true),
          cell("更新时间".tl, header: true),
        ]),
        for (final item in r.recentItems)
          TableRow(children: [
            cell(item.name),
            cell(_formatDate(item.updatedAt)),
          ]),
      ],
    );
  }

  String _formatDate(int? ms) {
    if (ms == null) return "—";
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return "${d.year}-${two(d.month)}-${two(d.day)}";
  }

  Future<void> _showHistory(ServerSubscription sub) async {
    List<ServerSubscriptionCheck> checks;
    try {
      checks = await PicaServer.instance.listSubscriptionHistory(
        source: sub.source,
        target: sub.target,
      );
    } catch (e) {
      if (mounted) showToast(message: e.toString());
      return;
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text("更新历史".tl),
          content: SizedBox(
            width: 420,
            child: checks.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text("暂无更新记录".tl)),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: checks.length,
                    itemBuilder: (context, i) {
                      final c = checks[i];
                      final time = c.checkedAt == null
                          ? ''
                          : timeToString(DateTime.fromMillisecondsSinceEpoch(
                              c.checkedAt!));
                      if (c.status == 'failed') {
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.error_outline),
                          title: Text("$time · ${"检查失败".tl}"),
                          subtitle: Text(
                            c.message ?? '',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.new_releases_outlined),
                        title: Text("$time · ${"发现更新".tl}"),
                        subtitle: Text(
                          c.newItems.join("、"),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text("关闭".tl),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("服务器订阅".tl),
        actions: [
          IconButton(
            tooltip: "刷新".tl,
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? NetworkError(message: error!, retry: _load, withAppbar: false)
              : _buildList(),
    );
  }

  Widget _buildList() {
    if (subscriptions.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.notifications_none, size: 56),
          const SizedBox(height: 12),
          Center(child: Text("暂无订阅".tl)),
          const SizedBox(height: 8),
          Center(
            child: Text(
              "在漫画详情页点击“订阅”，服务器将按频率自动检查更新".tl,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: subscriptions.length,
        itemBuilder: (context, i) {
          final sub = subscriptions[i];
          return _SubscriptionTile(
            sub: sub,
            onTap: () => _openSourcePage(sub),
            onEdit: () => _edit(sub),
            onCheckNow: () => _checkNow(sub),
            onHistory: () => _showHistory(sub),
          );
        },
      ),
    );
  }
}

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({
    required this.sub,
    required this.onTap,
    required this.onEdit,
    required this.onCheckNow,
    required this.onHistory,
  });

  final ServerSubscription sub;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onCheckNow;
  final VoidCallback onHistory;

  String get _statusText {
    if (sub.lastError != null && sub.lastError!.isNotEmpty) {
      return "上次检查失败".tl;
    }
    if (sub.lastUpdatedAt != null) {
      final t = timeToString(
          DateTime.fromMillisecondsSinceEpoch(sub.lastUpdatedAt!));
      return "${"最近更新".tl}: $t";
    }
    if (sub.lastCheckAt != null) {
      final t =
          timeToString(DateTime.fromMillisecondsSinceEpoch(sub.lastCheckAt!));
      return "${"上次检查".tl}: $t";
    }
    return "等待首次检查".tl;
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: SizedBox(
        width: 44,
        height: 60,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: sub.cover.isEmpty
              ? const ColoredBox(
                  color: Colors.black12,
                  child: Center(child: Icon(Icons.photo, size: 20)),
                )
              : AnimatedImage(
                  image: CachedImageProvider(
                    sub.cover,
                    sourceKey: sub.source,
                  ),
                  fit: BoxFit.cover,
                ),
        ),
      ),
      title: Text(
        sub.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        "${sub.autoDownload ? "订阅 + 下载".tl : "仅订阅更新".tl} · "
        "${subscriptionIntervalLabel(sub.intervalMinutes)} · $_statusText",
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: PopupMenuButton<String>(
        tooltip: "更多".tl,
        onSelected: (v) {
          if (v == 'check') onCheckNow();
          if (v == 'history') onHistory();
          if (v == 'edit') onEdit();
        },
        itemBuilder: (context) => [
          PopupMenuItem(value: 'check', child: Text("立即检查".tl)),
          PopupMenuItem(value: 'history', child: Text("更新历史".tl)),
          PopupMenuItem(value: 'edit', child: Text("订阅设置".tl)),
        ],
      ),
    );
  }
}
