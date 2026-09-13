import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/image_loader/cached_image.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/time.dart';
import 'package:pica_comic/tools/translations.dart';

/// 订阅自动下载历史页：展示订阅触发的自动下载记录与结果。
class ServerSubscriptionDownloadsPage extends StatefulWidget {
  const ServerSubscriptionDownloadsPage({super.key});

  @override
  State<ServerSubscriptionDownloadsPage> createState() =>
      _ServerSubscriptionDownloadsPageState();
}

class _ServerSubscriptionDownloadsPageState
    extends State<ServerSubscriptionDownloadsPage> {
  bool loading = true;
  String? error;
  List<ServerSubscriptionDownload> downloads = const [];

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
        downloads = const [];
      });
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final list = await PicaServer.instance.listSubscriptionDownloads();
      if (!mounted) return;
      setState(() {
        downloads = list;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("订阅下载历史".tl),
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
    if (downloads.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.cloud_download_outlined, size: 56),
          const SizedBox(height: 12),
          Center(child: Text("暂无自动下载记录".tl)),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: downloads.length,
        itemBuilder: (context, i) =>
            _DownloadHistoryTile(item: downloads[i]),
      ),
    );
  }
}

class _DownloadHistoryTile extends StatelessWidget {
  const _DownloadHistoryTile({required this.item});

  final ServerSubscriptionDownload item;

  String get _statusLabel => switch (item.status) {
        'queued' => "排队中".tl,
        'running' => "下载中".tl,
        'paused' => "已暂停".tl,
        'succeeded' => "已完成".tl,
        'failed' => "失败".tl,
        'cancelled' => "已取消".tl,
        _ => item.status,
      };

  Color _statusColor(BuildContext context) => switch (item.status) {
        'succeeded' => Colors.green,
        'failed' => Theme.of(context).colorScheme.error,
        'running' || 'queued' => Theme.of(context).colorScheme.primary,
        _ => Theme.of(context).colorScheme.outline,
      };

  IconData get _statusIcon => switch (item.status) {
        'succeeded' => Icons.check_circle_outline,
        'failed' => Icons.error_outline,
        'running' => Icons.downloading,
        'queued' => Icons.schedule,
        'paused' => Icons.pause_circle_outline,
        'cancelled' => Icons.cancel_outlined,
        _ => Icons.info_outline,
      };

  @override
  Widget build(BuildContext context) {
    final time = item.createdAt == null
        ? ''
        : timeToString(DateTime.fromMillisecondsSinceEpoch(item.createdAt!));
    final content = item.newItems.isEmpty
        ? "首次全量下载".tl
        : "${"新增".tl}: ${item.newItems.join("、")}";
    final progress = (item.status == 'running' && (item.total ?? 0) > 0)
        ? "（${item.progress ?? 0}/${item.total}）"
        : "";
    final failedMessage = (item.status == 'failed' &&
            item.message != null &&
            item.message!.isNotEmpty)
        ? item.message!
        : null;
    return ListTile(
      leading: SizedBox(
        width: 44,
        height: 60,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: item.cover.isEmpty
              ? const ColoredBox(
                  color: Colors.black12,
                  child: Center(child: Icon(Icons.photo, size: 20)),
                )
              : AnimatedImage(
                  image: CachedImageProvider(
                    item.cover,
                    sourceKey: item.source,
                  ),
                  fit: BoxFit.cover,
                ),
        ),
      ),
      title: Text(
        item.title.isEmpty ? "未知漫画".tl : item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          time,
          content,
          if (failedMessage != null) failedMessage,
        ].where((e) => e.isNotEmpty).join(" · "),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_statusIcon, size: 18, color: _statusColor(context)),
          const SizedBox(width: 4),
          Text(
            "$_statusLabel$progress",
            style: TextStyle(color: _statusColor(context), fontSize: 12),
          ),
        ],
      ),
    );
  }
}
