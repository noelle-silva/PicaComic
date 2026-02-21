import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
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
  bool _selectMode = false;
  final Set<String> _selectedTaskIds = {};

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
        if (_selectMode) {
          final existing = list.map((e) => e.id).toSet();
          _selectedTaskIds.removeWhere((e) => !existing.contains(e));
        }
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
    final selectedCount = _selectedTaskIds.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectMode ? "${"已选择".tl} $selectedCount" : "服务器任务".tl,
        ),
        actions: [
          if (_selectMode) ...[
            IconButton(
              tooltip: "删除".tl,
              onPressed: selectedCount == 0
                  ? null
                  : () {
                      showConfirmDialog(
                        context,
                        "删除".tl,
                        "${"删除选中任务记录".tl}?",
                        () => unawaited(_deleteSelectedTasks()),
                      );
                    },
              icon: const Icon(Icons.delete_outline),
            ),
            IconButton(
              tooltip: "退出多选".tl,
              onPressed: _exitSelectMode,
              icon: const Icon(Icons.close),
            ),
          ] else ...[
            IconButton(
              tooltip: "多选".tl,
              onPressed: _enterSelectMode,
              icon: const Icon(Icons.checklist),
            ),
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
        return ListTile(
          leading: _buildLeading(context, t),
          title: Text(
            _buildTitleText(t),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: _buildSubtitle(context, t, trailing),
          trailing: _selectMode
              ? Checkbox(
                  value: _selectedTaskIds.contains(t.id),
                  onChanged: (_) => _toggleSelected(t.id),
                )
              : Row(
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
          onTap: () {
            if (_selectMode) {
              _toggleSelected(t.id);
            } else {
              _openTaskDetail(t.id);
            }
          },
          onLongPress: () {
            if (_selectMode) {
              _toggleSelected(t.id);
            } else {
              _enterSelectMode();
              _toggleSelected(t.id);
            }
          },
        );
      },
    );
  }

  String _buildTitleText(ServerTask t) {
    final title = (t.title ?? '').trim();
    if (title.isNotEmpty) return title;
    return '${t.source}: ${t.target}';
  }

  Widget _buildSubtitle(BuildContext context, ServerTask t, String? timeText) {
    final pieces = <String>[];
    pieces.add(_statusText(t));
    if (t.total > 0) {
      pieces.add('${t.progress}/${t.total}');
    } else if (t.progress > 0) {
      pieces.add('${t.progress}');
    }
    final msg = (t.message ?? '').trim();
    if (msg.isNotEmpty) pieces.add(msg);
    if (timeText != null && _selectMode) pieces.add(timeText);

    final title = (t.title ?? '').trim();
    final showSourceTarget = title.isNotEmpty;

    if (!showSourceTarget) {
      return Text(
        pieces.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    final secondary = '${t.source}: ${t.target}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          secondary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text(
          pieces.join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  String _statusText(ServerTask t) {
    final status = t.status;
    return switch (status) {
      'queued' => "排队中".tl,
      'running' => t.type == 'upload' ? "上传中".tl : "下载中".tl,
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

  Widget _buildLeading(BuildContext context, ServerTask t) {
    final url = (t.coverUrl ?? '').trim();
    final hasUrl = url.startsWith('http://') || url.startsWith('https://');
    if (!hasUrl) return _statusIcon(context, t.status);

    final headers =
        url.contains('/api/v1/') ? PicaServer.instance.imageHeaders() : null;

    return SizedBox.square(
      dimension: 44,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image(
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              image: StreamImageProvider(
                () => ImageManager().getImage(url, headers),
                url,
              ),
              errorBuilder: (_, __, ___) => const ColoredBox(
                color: Colors.black12,
                child: Center(child: Icon(Icons.photo, size: 22)),
              ),
            ),
            Positioned(
              right: 2,
              bottom: 2,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  _statusBadgeIcon(t),
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _statusBadgeIcon(ServerTask t) {
    final status = t.status;
    return switch (status) {
      'queued' => Icons.schedule,
      'running' => t.type == 'upload' ? Icons.cloud_upload : Icons.downloading,
      'paused' => Icons.pause,
      'succeeded' => Icons.check,
      'failed' => Icons.error_outline,
      'canceled' => Icons.cancel_outlined,
      _ => Icons.help_outline,
    };
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
        items.add(_TaskAction.retry);
        items.add(_TaskAction.delete);
        break;
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

  void _enterSelectMode() {
    if (_selectMode) return;
    setState(() {
      _selectMode = true;
      _selectedTaskIds.clear();
    });
  }

  void _exitSelectMode() {
    if (!_selectMode) return;
    setState(() {
      _selectMode = false;
      _selectedTaskIds.clear();
    });
  }

  void _toggleSelected(String id) {
    if (id.trim().isEmpty) return;
    setState(() {
      if (_selectedTaskIds.contains(id)) {
        _selectedTaskIds.remove(id);
      } else {
        _selectedTaskIds.add(id);
      }
    });
  }

  Future<void> _deleteSelectedTasks() async {
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }
    final ids = _selectedTaskIds.toList();
    if (ids.isEmpty) return;

    final dialog = showLoadingDialog(
      context,
      barrierDismissible: false,
      allowCancel: false,
      message: "删除中".tl,
    );
    var ok = 0;
    var failed = 0;
    for (final id in ids) {
      try {
        await PicaServer.instance.deleteTask(id);
        ok++;
      } catch (_) {
        failed++;
      }
    }
    dialog.close();
    if (!mounted) return;
    _exitSelectMode();
    await _load(silent: true);
    final msg = failed == 0
        ? "${"已删除".tl} $ok"
        : "${"已删除".tl} $ok, ${"失败".tl} $failed";
    showToast(message: msg);
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
