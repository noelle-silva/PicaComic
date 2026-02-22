import 'package:flutter/material.dart';
import 'package:pica_comic/comic_source/comic_source.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/translations.dart';

class LocalFavoritesImportResult {
  final int total;
  final int imported;
  final int skipped;
  final int failed;
  final int folderRemapped;
  final bool canceled;

  const LocalFavoritesImportResult({
    required this.total,
    required this.imported,
    required this.skipped,
    required this.failed,
    required this.folderRemapped,
    required this.canceled,
  });

  String toToastText() {
    final parts = <String>[
      "${"已导入".tl} $imported/$total",
      if (skipped > 0) "${"跳过".tl} $skipped",
      if (failed > 0) "${"失败".tl} $failed",
      if (folderRemapped > 0) "${"文件夹合并到默认".tl} $folderRemapped",
      if (canceled) "已取消".tl,
    ];
    return parts.join(" · ");
  }
}

class ImportLocalFavoritesToServerDialog extends StatefulWidget {
  const ImportLocalFavoritesToServerDialog({
    super.key,
    required this.items,
  });

  final List<FavoriteItemWithFolderInfo> items;

  @override
  State<ImportLocalFavoritesToServerDialog> createState() =>
      _ImportLocalFavoritesToServerDialogState();
}

class _ImportLocalFavoritesToServerDialogState
    extends State<ImportLocalFavoritesToServerDialog> {
  static const _defaultFolder = '默认';

  int imported = 0;
  int skipped = 0;
  int failed = 0;
  int folderRemapped = 0;
  bool cancel = false;
  bool done = false;
  String? lastError;

  int get total => widget.items.length;

  @override
  void initState() {
    super.initState();
    _run();
  }

  bool _isValidServerFolder(String name) {
    final v = name.trim();
    if (v.isEmpty) return false;
    if (v.length > 64) return false;
    if (v.contains('/') || v.contains('\\')) return false;
    if (v.contains('..')) return false;
    return true;
  }

  String _toServerFolder(String name) {
    final v = name.trim();
    if (_isValidServerFolder(v)) return v;
    return _defaultFolder;
  }

  String? _toSourceKey(FavoriteItem item) {
    final typeName = item.type.comicType.name;
    if (typeName != 'other') {
      return typeName.toLowerCase();
    }
    return ComicSource.fromIntKey(item.type.key)?.key;
  }

  Future<void> _run() async {
    if (!PicaServer.instance.enabled) {
      setState(() {
        done = true;
        lastError = "未配置服务器".tl;
      });
      return;
    }

    final ok = await PicaServer.instance.health();
    if (!ok) {
      setState(() {
        done = true;
        lastError = "连接失败".tl;
      });
      return;
    }

    for (final it in widget.items) {
      if (cancel) break;

      final sourceKey = _toSourceKey(it.comic);
      if (sourceKey == null || ComicSource.find(sourceKey) == null) {
        skipped += 1;
        if (mounted) setState(() {});
        continue;
      }

      final folder = _toServerFolder(it.folder);
      if (folder == _defaultFolder && it.folder.trim() != _defaultFolder) {
        folderRemapped += 1;
      }

      final payload = ServerFavoriteItem(
        sourceKey: sourceKey,
        target: it.comic.target,
        folder: folder,
        title: it.comic.name,
        subtitle: it.comic.author,
        cover: it.comic.coverPath,
        tags: it.comic.tags,
      );

      try {
        await PicaServer.instance.addFavorite(payload);
        imported += 1;
      } catch (e) {
        failed += 1;
        lastError = e.toString();
      }

      if ((imported + skipped + failed) % 5 == 0 && mounted) {
        setState(() {});
      }
    }

    if (!mounted) return;
    setState(() {
      done = true;
    });
  }

  LocalFavoritesImportResult _result() {
    return LocalFavoritesImportResult(
      total: total,
      imported: imported,
      skipped: skipped,
      failed: failed,
      folderRemapped: folderRemapped,
      canceled: cancel,
    );
  }

  @override
  Widget build(BuildContext context) {
    final finished = imported + skipped + failed;
    final progress = total == 0 ? 1.0 : (finished / total).clamp(0.0, 1.0);
    final result = _result();

    return ContentDialog(
      title: "导入到服务器".tl,
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text("$finished/$total"),
            ),
            const SizedBox(height: 8),
            Text(result.toToastText(), style: const TextStyle(fontSize: 12)),
            if (lastError != null) ...[
              const SizedBox(height: 8),
              Text(
                "${"最近错误".tl}: $lastError",
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        Button.filled(
          onPressed: done
              ? () => Navigator.of(context).pop(result)
              : () {
                  cancel = true;
                  setState(() {});
                },
          child: Text(done ? "关闭".tl : "取消".tl),
        ),
      ],
    );
  }
}
