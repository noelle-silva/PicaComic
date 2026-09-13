import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/history.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/foundation/local_favorites.dart';
import 'package:pica_comic/network/download.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/network/res.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/favorites/server_favorite_dialogs.dart';
import 'package:pica_comic/pages/open_source_comic.dart';
import 'package:pica_comic/pages/reader/comic_reading_page.dart';
import 'package:pica_comic/tools/io_tools.dart';
import 'package:pica_comic/tools/time.dart';
import 'package:pica_comic/tools/translations.dart';

/// 服务器漫画详情页数据：漫画 + 章节信息 + 随机推荐。
class ServerComicDetailData {
  final ServerComic comic;

  final ServerReadInfo readInfo;

  final List<ServerComic> recommendations;

  const ServerComicDetailData(this.comic, this.readInfo, this.recommendations);
}

/// 服务器漫画详情页（与其他源详情页同构，复用统一骨架）。
class ServerComicPage extends BaseComicPage<ServerComicDetailData> {
  const ServerComicPage({required this.comicId, super.key});

  final String comicId;

  @override
  String get id => comicId;

  @override
  String get sourceKey => kServerFavoritesKey;

  @override
  String get tag => "server comic page with id: $comicId";

  /// 漫画本身就在服务器上，服务器操作与本地收藏不适用。
  @override
  bool get enableServerActions => false;

  @override
  bool get enableLocalFavorite => false;

  /// 查询漫画是否已加入服务器资源收藏。
  @override
  Future<ComicServerStatus> loadServerStatus(
      ServerComicDetailData data) async {
    if (!PicaServer.instance.enabled) return ComicServerStatus.unknown;
    try {
      final contains =
          await PicaServer.instance.containsResourceFavorite(data.comic.id);
      return ComicServerStatus(resourceFavorite: contains.exists);
    } catch (e) {
      return ComicServerStatus.unknown;
    }
  }

  @override
  List<Widget> buildExtraActionItems(
      ComicPageLogic<ServerComicDetailData> logic) {
    if (!PicaServer.instance.enabled) return const [];
    final favorite = logic.serverStatus.resourceFavorite == true;
    return [
      ComicActionItem(
        title: favorite ? "已收藏".tl : "收藏到…".tl,
        icon: favorite ? Icons.bookmark_added : Icons.bookmark_add_outlined,
        onTap: () => _collectToResourceFavorite(logic),
      ),
    ];
  }

  Future<void> _collectToResourceFavorite(
      ComicPageLogic<ServerComicDetailData> logic) async {
    final folder = await pickServerResourceFavoriteFolder(context);
    if (folder == null) return;
    try {
      await PicaServer.instance
          .addResourceFavorite(id: comicId, folder: folder);
      showToast(message: "已收藏".tl);
      logic.applyServerStatus(
        logic.serverStatus.copyWith(resourceFavorite: true),
      );
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  @override
  String? get title => data!.comic.title;

  @override
  String? get subTitle => data!.comic.subtitle;

  @override
  String? get cover => data!.comic.coverUrl;

  @override
  Map<String, String> get headers => PicaServer.instance.imageHeaders();

  @override
  String get source => "私人服务器".tl;

  @override
  Map<String, List<String>> get tags => {
        if (data!.comic.tags.isNotEmpty) "标签".tl: data!.comic.tags,
      };

  @override
  int? get pages => null;

  @override
  String? get introduction => null;

  @override
  Card? get uploaderInfo => null;

  @override
  ThumbnailsData? get thumbnailsCreator => null;

  @override
  Future<Res<ServerComicDetailData>> loadData() async {
    try {
      final comic = await PicaServer.instance.getComic(comicId);
      if (comic == null) {
        return const Res.error("未找到该漫画");
      }
      var results = await Future.wait([
        PicaServer.instance.getReadInfo(comicId),
        PicaServer.instance.listComics(),
      ]);
      final readInfo = results[0] as ServerReadInfo;
      final others = (results[1] as List<ServerComic>)
          .where((e) => e.id != comicId)
          .toList()
        ..shuffle();
      return Res(ServerComicDetailData(
        comic,
        readInfo,
        others.take(8).toList(),
      ));
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  @override
  Future<bool> loadFavorite(ServerComicDetailData data) async => false;

  @override
  EpsData? get eps {
    final info = data!.readInfo;
    if (info.eps.isEmpty) {
      return null;
    }
    return EpsData(
      info.eps
          .map((e) => e.title.trim().isEmpty ? "第${e.ep}话".tl : e.title)
          .toList(),
      (i) async {
        await History.findOrCreate(data!.comic);
        App.globalTo(() => _readingPage(i + 1));
      },
    );
  }

  @override
  void read(History? history) async {
    history = await History.createIfNull(history, data!.comic);
    App.globalTo(() => _readingPage(
          history!.ep < 1 ? 1 : history.ep,
          initialPage: history.page,
        ));
  }

  ComicReadingPage _readingPage(int ep, {int initialPage = 1}) {
    return ComicReadingPage(
      PicaServerReadingData(
        comicId: comicId,
        title: data!.comic.title,
        eps: data!.readInfo.eps,
      ),
      initialPage,
      ep,
    );
  }

  @override
  void download() async {
    final comic = data!.comic;
    final item = comic.toDownloadedItem();
    if (item == null) {
      showToast(message: "服务器数据不完整".tl);
      return;
    }

    await DownloadManager().init();
    final directory = comic.directory;
    if (directory.isEmpty) {
      showToast(message: "服务器缺少目录信息".tl);
      return;
    }

    final targetDir = Directory('${DownloadManager().path}$pathSep$directory');

    Future<void> run() async {
      final dialog = showLoadingDialog(
        App.globalContext!,
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

        if (comic.coverUrl != null && comic.coverUrl!.isNotEmpty) {
          await dio.download(
            comic.coverUrl!,
            '${targetDir.path}${pathSep}cover.jpg',
          );
        }

        final info = await PicaServer.instance.getReadInfo(comic.id);
        if (info.hasEps) {
          for (final epInfo in info.eps) {
            final epNo = epInfo.ep;
            if (epNo <= 0) continue;
            final epDir = Directory('${targetDir.path}$pathSep$epNo')
              ..createSync(recursive: true);
            final pages = await PicaServer.instance.listPages(comic.id, epNo);
            for (final name in pages) {
              final url =
                  '$base/api/v1/comics/${Uri.encodeComponent(comic.id)}/image?ep=$epNo&name=${Uri.encodeQueryComponent(name)}';
              await dio.download(url, '${epDir.path}$pathSep$name');
            }
          }
        } else {
          final pages = await PicaServer.instance.listPages(comic.id, 0);
          for (final name in pages) {
            final url =
                '$base/api/v1/comics/${Uri.encodeComponent(comic.id)}/image?ep=0&name=${Uri.encodeQueryComponent(name)}';
            await dio.download(url, '${targetDir.path}$pathSep$name');
          }
        }

        item.directory = directory;
        item.comicSize = await getFolderSize(targetDir);
        DownloadManager().upsertDownloadedItem(item, directory);

        dialog.close();
        showToast(message: "已添加到本地下载".tl);
        update();
      } catch (e) {
        dialog.close();
        showToast(message: "${"下载失败".tl}: $e");
      }
    }

    if (targetDir.existsSync()) {
      showConfirmDialog(
        App.globalContext!,
        "覆盖本地下载?".tl,
        "本地已存在同名下载目录, 是否覆盖?".tl,
        run,
      );
    } else {
      await run();
    }
  }

  @override
  void openFavoritePanel() {}

  @override
  void tapOnTag(String tag, String key) {}

  @override
  String get downloadedId => data!.comic.id;

  @override
  FavoriteItem toLocalFavoriteItem() => FavoriteItem(
        target: data!.comic.id,
        name: data!.comic.title,
        coverPath: data!.comic.coverUrl ?? "",
        author: data!.comic.subtitle,
        type: const FavoriteType(999),
        tags: data!.comic.tags,
      );

  @override
  Widget? recommendationBuilder(ServerComicDetailData data) {
    if (data.recommendations.isEmpty) {
      return null;
    }
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithComics(),
      delegate: SliverChildBuilderDelegate((context, i) {
        final comic = data.recommendations[i];
        return ServerComicTile(
          comic,
          onTap: () => context.to(() => ServerComicPage(comicId: comic.id)),
        );
      }, childCount: data.recommendations.length),
    );
  }

  @override
  bool get moreInfoBelowTags => true;

  /// 有源信息时提供"源页面"入口（还原失败则隐藏）。
  @override
  ActionFunc? get openSourceComicPage {
    final item = data?.comic.toDownloadedItem();
    if (item == null) return null;
    return () => openSourceComic(item);
  }

  @override
  Widget? get buildMoreInfo => _ServerComicInfoCard(comic: data?.comic);

  @override
  List<PopupMenuEntry> buildMoreMenuItems() => [
        const PopupMenuDivider(),
        PopupMenuItem(
          onTap: _refreshInfo,
          child: Text("刷新信息".tl),
        ),
        PopupMenuItem(
          onTap: _deleteFromServer,
          child: Text("从服务器删除".tl),
        ),
      ];

  void _refreshInfo() {
    StateController.find<ComicPageLogic<ServerComicDetailData>>(tag: tag)
        .refresh_();
  }

  Future<void> _deleteFromServer() async {
    final comic = data?.comic;
    if (comic == null) return;
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
          await PicaServer.instance.deleteComic(comic.id);
          dialog.close();
          showToast(message: "删除成功".tl);
          navigator.pop(true);
        } catch (e) {
          dialog.close();
          showToast(message: "${"操作失败".tl}: $e");
        }
      },
    );
  }
}

/// 服务器信息卡：展示基本信息。
class _ServerComicInfoCard extends StatelessWidget {
  const _ServerComicInfoCard({required this.comic});

  final ServerComic? comic;

  @override
  Widget build(BuildContext context) {
    final size = comic?.size;
    final time = comic?.time;
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud, size: 18),
                const SizedBox(width: 8),
                Text(
                  "服务器信息".tl,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (size != null)
              Text(
                "${"大小".tl}: ${(size / 1024 / 1024).toStringAsFixed(1)} MB",
                style: const TextStyle(fontSize: 13),
              ),
            if (time != null)
              Text(
                "${"上传时间".tl}: ${timeToString(DateTime.fromMillisecondsSinceEpoch(time))}",
                style: const TextStyle(fontSize: 13),
              ),
          ],
        ),
      ),
    );
  }
}

/// 服务器漫画卡片（服务器库与推荐区共用）。
class ServerComicTile extends ComicTile {
  const ServerComicTile(this.comic, {required this.onTap, super.key});

  final ServerComic comic;

  final VoidCallback onTap;

  @override
  bool get enableLongPressed => false;

  @override
  Widget? get trailing => _ServerComicMenuButton(comic: comic);

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
        () => ImageManager().getImage(url, PicaServer.instance.imageHeaders()),
        url,
      ),
    );
  }

  @override
  void onTap_() => onTap();

  @override
  void onSecondaryTap_(TapDownDetails details) => onTap();
}

/// 服务器漫画卡片的"点点点"菜单按钮：收藏 / 取消收藏到服务器资源收藏。
class _ServerComicMenuButton extends StatefulWidget {
  const _ServerComicMenuButton({required this.comic});

  final ServerComic comic;

  @override
  State<_ServerComicMenuButton> createState() =>
      _ServerComicMenuButtonState();
}

class _ServerComicMenuButtonState extends State<_ServerComicMenuButton> {
  Future<void> _showMenu() async {
    ServerResourceFavoriteContains contains;
    try {
      contains = await PicaServer.instance
          .containsResourceFavorite(widget.comic.id);
    } catch (e) {
      if (mounted) {
        showToast(message: e.toString());
      }
      return;
    }
    if (!mounted) return;

    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    final action = await showMenu<String>(
      context: context,
      position: position,
      items: [
        if (contains.exists)
          PopupMenuItem(
            value: 'remove',
            child: Text("从服务器资源收藏删除".tl),
          )
        else
          PopupMenuItem(
            value: 'collect',
            child: Text("收藏到服务器资源收藏…".tl),
          ),
      ],
    );
    if (action == null || !mounted) return;

    if (action == 'collect') {
      final folder = await pickServerResourceFavoriteFolder(context);
      if (folder == null) return;
      try {
        await PicaServer.instance
            .addResourceFavorite(id: widget.comic.id, folder: folder);
        showToast(message: "已收藏".tl);
      } catch (e) {
        showToast(message: e.toString());
      }
    } else if (action == 'remove') {
      try {
        await PicaServer.instance.removeResourceFavorite(widget.comic.id);
        showToast(message: "已删除".tl);
      } catch (e) {
        showToast(message: e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: "更多".tl,
      onPressed: _showMenu,
      icon: const Icon(Icons.more_vert, size: 20),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      padding: EdgeInsets.zero,
    );
  }
}
