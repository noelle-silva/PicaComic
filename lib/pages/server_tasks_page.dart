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
  int? _maxConcurrent;

  @override
  void initState() {
    super.initState();
    _load();
    _loadConfig(silent: true);
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

  Future<void> _loadConfig({bool silent = false}) async {
    if (!PicaServer.instance.enabled) return;
    try {
      final v = await PicaServer.instance.getMaxConcurrent();
      if (!mounted) return;
      setState(() {
        _maxConcurrent = v;
      });
    } catch (e) {
      if (!silent) {
        showToast(message: e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("服务器任务".tl),
        actions: [
          IconButton(
            tooltip: "并发".tl,
            onPressed: _openConcurrencyDialog,
            icon: const Icon(Icons.tune),
          ),
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (trailing != null) Text(trailing),
              PopupMenuButton<_TaskAction>(
                tooltip: "更多".tl,
                onSelected: (a) => _onAction(t, a),
                itemBuilder: (_) => _buildActions(t),
              ),
            ],
          ),
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
      'paused' => "已暂停".tl,
      'succeeded' => "成功".tl,
      'failed' => "失败".tl,
      'canceled' => "已取消".tl,
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
      case 'paused':
        return const Icon(Icons.pause_circle_outline);
      case 'succeeded':
        return Icon(Icons.check_circle, color: cs.primary);
      case 'failed':
        return Icon(Icons.error, color: cs.error);
      case 'canceled':
        return const Icon(Icons.cancel_outlined);
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

  List<PopupMenuEntry<_TaskAction>> _buildActions(ServerTask t) {
    final items = <_TaskAction>[];
    switch (t.status) {
      case 'running':
      case 'queued':
        items.add(_TaskAction.pause);
        items.add(_TaskAction.cancel);
        break;
      case 'paused':
        items.add(_TaskAction.resume);
        items.add(_TaskAction.cancel);
        break;
      case 'failed':
        items.add(_TaskAction.retry);
        items.add(_TaskAction.cancel);
        items.add(_TaskAction.delete);
        break;
      case 'canceled':
      case 'succeeded':
        items.add(_TaskAction.delete);
        break;
      default:
        items.add(_TaskAction.delete);
    }

    return items
        .map(
          (a) => PopupMenuItem<_TaskAction>(
            value: a,
            child: Text(a.label),
          ),
        )
        .toList();
  }

  Future<void> _onAction(ServerTask t, _TaskAction action) async {
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }

    Future<void> call(Future<void> Function() fn) async {
      final dialog = showLoadingDialog(
        context,
        barrierDismissible: false,
        allowCancel: false,
        message: "处理中".tl,
      );
      try {
        await fn();
        dialog.close();
        if (!mounted) return;
        await _load(silent: true);
      } catch (e) {
        dialog.close();
        showToast(message: e.toString());
      }
    }

    switch (action) {
      case _TaskAction.pause:
        await call(() => PicaServer.instance.pauseTask(t.id));
        break;
      case _TaskAction.resume:
        await call(() => PicaServer.instance.resumeTask(t.id));
        break;
      case _TaskAction.cancel:
        showConfirmDialog(
          context,
          "取消".tl,
          "取消任务并删除临时文件?".tl,
          () => call(() => PicaServer.instance.cancelTask(t.id)),
        );
        break;
      case _TaskAction.retry:
        await call(() => PicaServer.instance.retryTask(t.id));
        break;
      case _TaskAction.delete:
        showConfirmDialog(
          context,
          "删除".tl,
          "删除任务记录?".tl,
          () => call(() => PicaServer.instance.deleteTask(t.id)),
        );
        break;
    }
  }

  Future<void> _openConcurrencyDialog() async {
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }
    await _loadConfig(silent: true);
    if (!mounted) return;
    var value = (_maxConcurrent ?? 1).clamp(1, 20);

    final controller = TextEditingController(text: value.toString());

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text("下载并发".tl),
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () {
                  value = (value - 1).clamp(1, 20);
                  controller.text = value.toString();
                },
                icon: const Icon(Icons.remove),
              ),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                onPressed: () {
                  value = (value + 1).clamp(1, 20);
                  controller.text = value.toString();
                },
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text("取消".tl),
            ),
            FilledButton(
              onPressed: () async {
                final parsed = int.tryParse(controller.text) ?? value;
                value = parsed.clamp(1, 20);
                if (!mounted) return;
                final dialog = showLoadingDialog(
                  context,
                  barrierDismissible: false,
                  allowCancel: false,
                  message: "设置中".tl,
                );
                try {
                  final nav = Navigator.of(dialogContext);
                  final newV = await PicaServer.instance.setMaxConcurrent(value);
                  dialog.close();
                  if (!mounted) return;
                  setState(() {
                    _maxConcurrent = newV;
                  });
                  if (dialogContext.mounted) {
                    nav.pop();
                  }
                  showToast(message: "${"已设置并发".tl}: $newV");
                } catch (e) {
                  dialog.close();
                  showToast(message: e.toString());
                }
              },
              child: Text("确定".tl),
            ),
          ],
        );
      },
    );
  }
}

enum _TaskAction {
  pause,
  resume,
  cancel,
  retry,
  delete;

  String get label => switch (this) {
        pause => "暂停".tl,
        resume => "继续".tl,
        cancel => "取消".tl,
        retry => "重试".tl,
        delete => "删除".tl,
      };
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
