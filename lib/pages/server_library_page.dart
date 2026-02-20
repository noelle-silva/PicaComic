import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/translations.dart';

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
                  child: _buildGrid(context),
                ),
    );
  }

  Widget _buildGrid(BuildContext context) {
    if (comics.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.collections_bookmark_outlined, size: 56),
          const SizedBox(height: 12),
          Center(child: Text("暂无漫画".tl)),
        ],
      );
    }

    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithComics(),
      itemCount: comics.length,
      itemBuilder: (context, index) {
        final comic = comics[index];
        return _ServerComicTile(
          comic,
          onTap: () => _openComic(context, comic),
        );
      },
    );
  }

  void _openComic(BuildContext context, ServerComic comic) {
    context
        .to<bool>(() => ServerComicDetailPage(comicId: comic.id))
        .then((changed) {
      if (changed == true) _load();
    });
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

class _ServerComicTile extends ComicTile {
  const _ServerComicTile(this.comic, {required this.onTap});

  final ServerComic comic;

  final VoidCallback onTap;

  @override
  bool get enableLongPressed => false;

  @override
  String get title => comic.title;

  @override
  String get subTitle => "";

  @override
  String get description => comic.subtitle;

  @override
  List<String>? get tags => [...comic.tags];

  @override
  Widget get image {
    final url = comic.coverUrl;
    if (url == null || url.isEmpty) {
      return const ColoredBox(
        color: Colors.black12,
        child: Center(child: Icon(Icons.photo, size: 36)),
      );
    }
    return Image(
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      width: double.infinity,
      height: double.infinity,
      image: StreamImageProvider(
        () =>
            ImageManager().getImage(url, PicaServer.instance.imageHeaders()),
        url,
      ),
    );
  }

  @override
  void onTap_() => onTap();

  @override
  void onSecondaryTap_(TapDownDetails details) => onTap();
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
                    children: c.tags
                        .take(10)
                        .map((t) => Chip(
                            label: Text(t, overflow: TextOverflow.ellipsis)))
                        .toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => _readOnline(context, c),
          child: Text("在线阅读".tl),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: () => _downloadToLocal(context, c),
          child: Text("下载到本地".tl),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: () => _deleteFromServer(context, c),
          child: Text("从服务器删除".tl),
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
            () => ImageManager()
                .getImage(url, PicaServer.instance.imageHeaders()),
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
    if (!context.mounted) return;
    final directory = c.directory;
    if (directory.isEmpty) {
      showToast(message: "服务器缺少目录信息".tl);
      return;
    }

    final targetDir = Directory('${DownloadManager().path}$pathSep$directory');

    Future<void> run() async {
      final dialog = showLoadingDialog(
        context,
        allowCancel: false,
        barrierDismissible: false,
        message: "下载中".tl,
      );
      try {
        if (targetDir.existsSync()) {
          targetDir.deleteSync(recursive: true);
        }
        targetDir.createSync(recursive: true);

        String normalizedBaseUrl() {
          var v = PicaServer.instance.baseUrl.trim();
          while (v.endsWith('/')) {
            v = v.substring(0, v.length - 1);
          }
          return v;
        }

        final base = normalizedBaseUrl();
        final headers = PicaServer.instance.imageHeaders();
        final dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(minutes: 5),
            sendTimeout: const Duration(minutes: 5),
            headers: headers.isEmpty ? null : headers,
          ),
        );

        if (c.coverUrl != null && c.coverUrl!.isNotEmpty) {
          await dio.download(
            c.coverUrl!,
            '${targetDir.path}${pathSep}cover.jpg',
          );
        }

        final info = await PicaServer.instance.getReadInfo(c.id);
        if (info.hasEps) {
          for (final epInfo in info.eps) {
            final epNo = epInfo.ep;
            if (epNo <= 0) continue;
            final epDir = Directory('${targetDir.path}$pathSep$epNo')
              ..createSync(recursive: true);
            final pages = await PicaServer.instance.listPages(c.id, epNo);
            for (final name in pages) {
              final url =
                  '$base/api/v1/comics/${Uri.encodeComponent(c.id)}/image?ep=$epNo&name=${Uri.encodeQueryComponent(name)}';
              await dio.download(url, '${epDir.path}$pathSep$name');
            }
          }
        } else {
          final pages = await PicaServer.instance.listPages(c.id, 0);
          for (final name in pages) {
            final url =
                '$base/api/v1/comics/${Uri.encodeComponent(c.id)}/image?ep=0&name=${Uri.encodeQueryComponent(name)}';
            await dio.download(url, '${targetDir.path}$pathSep$name');
          }
        }

        item.directory = directory;
        item.comicSize = await getFolderSize(targetDir);
        DownloadManager().upsertDownloadedItem(item, directory);

        dialog.close();
        showToast(message: "已添加到本地下载".tl);
      } catch (e) {
        dialog.close();
        showToast(message: "${"下载失败".tl}: $e");
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

  Future<void> _deleteFromServer(BuildContext context, ServerComic c) async {
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }

    showConfirmDialog(
      context,
      "从服务器删除".tl,
      "此操作无法撤销, 是否继续?".tl,
      () async {
        final navigator = Navigator.of(context);
        final dialog = showLoadingDialog(
          context,
          allowCancel: false,
          barrierDismissible: false,
        );
        try {
          await PicaServer.instance.deleteComic(c.id);
          dialog.close();
          showToast(message: "删除成功".tl);
          if (!mounted) return;
          navigator.pop(true);
        } catch (e) {
          dialog.close();
          showToast(message: "${"操作失败".tl}: $e");
        }
      },
    );
  }

  Future<void> _readOnline(BuildContext context, ServerComic c) async {
    if (!PicaServer.instance.enabled) {
      showToast(message: "未配置服务器".tl);
      return;
    }

    final dialog = showLoadingDialog(
      context,
      allowCancel: false,
      barrierDismissible: false,
      message: "加载中".tl,
    );

    try {
      final info = await PicaServer.instance.getReadInfo(c.id);
      dialog.close();
      App.globalTo(
        () => ComicReadingPage(
          PicaServerReadingData(
            comicId: c.id,
            title: c.title,
            eps: info.eps,
          ),
          1,
          1,
        ),
      );
    } catch (e) {
      dialog.close();
      showToast(message: "${"操作失败".tl}: $e");
    }
  }
}
