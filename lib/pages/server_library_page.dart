import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/widget_utils.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:zip_flutter/zip_flutter.dart';

class ServerLibraryPage extends StatefulWidget {
  const ServerLibraryPage({super.key});

  @override
  State<ServerLibraryPage> createState() => _ServerLibraryPageState();
}

class _ServerLibraryPageState extends State<ServerLibraryPage> {
  bool loading = true;
  String? error;
  List<ServerComic> comics = const [];

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
        comics = const [];
      });
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final list = await PicaServer.instance.listComics();
      if (!mounted) return;
      setState(() {
        comics = list;
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
        title: Text("服务器漫画库".tl),
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
                  child: ListView.separated(
                    itemCount: comics.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final comic = comics[index];
                      return ListTile(
                        leading: _buildCover(comic),
                        title: Text(comic.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          comic.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.to(() => ServerComicDetailPage(comicId: comic.id)),
                      );
                    },
                  ),
                ),
    );
  }

  Widget _buildCover(ServerComic comic) {
    final url = comic.coverUrl;
    if (url == null || url.isEmpty) {
      return const SizedBox(
        width: 48,
        height: 64,
        child: Icon(Icons.photo, size: 28),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 48,
        height: 64,
        child: Image(
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          image: StreamImageProvider(
            () => ImageManager().getImage(url, PicaServer.instance.imageHeaders()),
            url,
          ),
        ),
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
}

class ServerComicDetailPage extends StatefulWidget {
  const ServerComicDetailPage({super.key, required this.comicId});

  final String comicId;

  @override
  State<ServerComicDetailPage> createState() => _ServerComicDetailPageState();
}

class _ServerComicDetailPageState extends State<ServerComicDetailPage> {
  bool loading = true;
  String? error;
  ServerComic? comic;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final c = await PicaServer.instance.getComic(widget.comicId);
      if (!mounted) return;
      setState(() {
        comic = c;
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
      appBar: AppBar(title: Text("服务器漫画".tl)),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Text(error!))
              : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = comic;
    if (c == null) return Center(child: Text("未找到".tl));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCover(c),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(c.subtitle),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: c.tags.take(10).map((t) => Chip(label: Text(t, overflow: TextOverflow.ellipsis))).toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => _downloadToLocal(context, c),
          child: Text("下载到本地".tl),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: _load,
          child: Text("刷新信息".tl),
        ),
      ],
    );
  }

  Widget _buildCover(ServerComic comic) {
    final url = comic.coverUrl;
    if (url == null || url.isEmpty) {
      return const SizedBox(
        width: 96,
        height: 128,
        child: Icon(Icons.photo, size: 36),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 96,
        height: 128,
        child: Image(
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          image: StreamImageProvider(
            () => ImageManager().getImage(url, PicaServer.instance.imageHeaders()),
            url,
          ),
        ),
      ),
    );
  }

  Future<void> _downloadToLocal(BuildContext context, ServerComic c) async {
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }

    final item = c.toDownloadedItem();
    if (item == null) {
      showToast(message: "服务器数据不完整".tl);
      return;
    }

    await DownloadManager().init();
    final directory = c.directory;
    if (directory.isEmpty) {
      showToast(message: "服务器缺少目录信息".tl);
      return;
    }

    final targetDir = Directory('${DownloadManager().path}$pathSep$directory');

    Future<void> run() async {
      final temp = await getTemporaryDirectory();
      final zipPath = '${temp.path}${pathSep}pica_server_${c.id}.zip';

      final dialog = showLoadingDialog(
        context,
        allowCancel: false,
        barrierDismissible: false,
        message: "下载中".tl,
      );
      try {
        await PicaServer.instance.downloadComicZip(c.id, zipPath);

        if (targetDir.existsSync()) {
          targetDir.deleteSync(recursive: true);
        }
        targetDir.createSync(recursive: true);

        final extractZipPath = zipPath;
        final extractTargetPath = targetDir.path;
        await Isolate.run(() {
          ZipFile.openAndExtract(extractZipPath, extractTargetPath);
        });

        item.directory = directory;
        item.comicSize = await getFolderSize(targetDir);
        DownloadManager().upsertDownloadedItem(item, directory);

        dialog.close();
        showToast(message: "已添加到本地下载".tl);
      } catch (e) {
        dialog.close();
        showToast(message: "${"下载失败".tl}: $e");
      } finally {
        try {
          File(zipPath).deleteSync();
        } catch (_) {
          // ignore
        }
      }
    }

    if (targetDir.existsSync()) {
      showConfirmDialog(
        context,
        "覆盖本地下载?".tl,
        "本地已存在同名下载目录, 是否覆盖?".tl,
        run,
      );
    } else {
      await run();
    }
  }
}
