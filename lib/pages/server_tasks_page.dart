import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/pages/server_library_page.dart';
import 'package:pica_comic/tools/time.dart';
import 'package:pica_comic/tools/translations.dart';

class ServerTasksPage extends StatefulWidget {
  const ServerTasksPage({super.key});

  @override
  State<ServerTasksPage> createState() => _ServerTasksPageState();
}

class _ServerTasksPageState extends State<ServerTasksPage> {
  bool loading = true;
  String? error;
  List<ServerTask> tasks = const [];
  Timer? _timer;
  bool _requestInFlight = false;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      if (loading) return;
      final hasActive = tasks.any((t) => t.status == 'queued' || t.status == 'running');
      if (hasActive) {
        _load(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (_requestInFlight) return;
    if (!PicaServer.instance.enabled) {
      setState(() {
        loading = false;
        error = "未配置服务器".tl;
        tasks = const [];
      });
      return;
    }
    _requestInFlight = true;
    if (!silent) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final list = await PicaServer.instance.listTasks(limit: 80);
      if (!mounted) return;
      setState(() {
        tasks = list;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    } finally {
      _requestInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("服务器任务".tl),
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
              ? _buildError(context)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _buildList(context),
                ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _load,
              child: Text("重试".tl),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (tasks.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.task_alt, size: 56),
          const SizedBox(height: 12),
          Center(child: Text("暂无任务".tl)),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: tasks.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final t = tasks[index];
        final trailing = _formatTimeMs(t.updatedAt ?? t.createdAt);
        final subtitle = _buildSubtitle(t);
        return ListTile(
          leading: _statusIcon(context, t.status),
          title: Text(
            '${t.source}: ${t.target}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: subtitle,
          trailing: trailing == null ? null : Text(trailing),
          onTap: () => _openTaskDetail(t.id),
        );
      },
    );
  }

  Widget _buildSubtitle(ServerTask t) {
    final pieces = <String>[];
    pieces.add(_statusText(t.status));
    if (t.total > 0) {
      pieces.add('${t.progress}/${t.total}');
    } else if (t.progress > 0) {
      pieces.add('${t.progress}');
    }
    final msg = (t.message ?? '').trim();
    if (msg.isNotEmpty) pieces.add(msg);
    return Text(
      pieces.join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  String _statusText(String status) {
    return switch (status) {
      'queued' => "排队中".tl,
      'running' => "下载中".tl,
      'succeeded' => "成功".tl,
      'failed' => "失败".tl,
      _ => status,
    };
  }

  Widget _statusIcon(BuildContext context, String status) {
    final cs = Theme.of(context).colorScheme;
    switch (status) {
      case 'queued':
        return const Icon(Icons.schedule);
      case 'running':
        return const SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case 'succeeded':
        return Icon(Icons.check_circle, color: cs.primary);
      case 'failed':
        return Icon(Icons.error, color: cs.error);
      default:
        return const Icon(Icons.help_outline);
    }
  }

  String? _formatTimeMs(int? ms) {
    if (ms == null || ms <= 0) return null;
    try {
      return timeToString(DateTime.fromMillisecondsSinceEpoch(ms));
    } catch (_) {
      return null;
    }
  }

  Future<void> _openTaskDetail(String id) async {
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }
    final dialog = showLoadingDialog(
      context,
      barrierDismissible: false,
      allowCancel: false,
      message: "加载中".tl,
    );
    try {
      final task = await PicaServer.instance.getTaskDetail(id);
      dialog.close();
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => _TaskDetailDialog(task: task),
      );
    } catch (e) {
      dialog.close();
      showToast(message: "${"加载失败".tl}: $e");
    }
  }
}

class _TaskDetailDialog extends StatelessWidget {
  const _TaskDetailDialog({required this.task});

  final ServerTask task;

  @override
  Widget build(BuildContext context) {
    final jsonText = const JsonEncoder.withIndent('  ').convert(task.toMap());
    return AlertDialog(
      title: Text("任务详情".tl),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: SelectableText(jsonText),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: task.id));
            showToast(message: "已复制".tl, icon: const Icon(Icons.check));
          },
          child: Text("复制ID".tl),
        ),
        if ((task.comicId ?? '').isNotEmpty)
          TextButton(
            onPressed: () {
              final nav = Navigator.of(context);
              nav.pop();
              nav.push(
                MaterialPageRoute(
                  builder: (_) => ServerComicDetailPage(comicId: task.comicId!),
                ),
              );
            },
            child: Text("打开漫画".tl),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text("关闭".tl),
        ),
      ],
    );
  }
}
