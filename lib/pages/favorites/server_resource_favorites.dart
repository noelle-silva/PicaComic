import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/image_loader/stream_image_provider.dart';
import 'package:pica_comic/foundation/image_manager.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/pages/server_comic_page.dart';
import 'package:pica_comic/tools/translations.dart';

import 'server_favorite_dialogs.dart';
import 'server_favorites.dart';

/// 服务器资源收藏内容视图（嵌入收藏页内容区显示）。
class ServerResourceFavoritesView extends StatefulWidget {
  const ServerResourceFavoritesView({super.key});

  @override
  State<ServerResourceFavoritesView> createState() =>
      _ServerResourceFavoritesViewState();
}

class _ServerResourceFavoritesViewState
    extends State<ServerResourceFavoritesView> {
  /// 倒序显示偏好在隐式数据中的下标。
  static const int _kDisplayOrderIndex = 7;

  bool loading = true;
  String? error;

  List<ServerResourceFavoriteFolder> folders = const [];
  String selectedFolder = '';
  List<ServerResourceFavoriteItem> items = const [];

  bool reorderMode = false;
  final Key _normalGridKey = UniqueKey();
  final GlobalKey _reorderGridKey = GlobalKey();
  final _reorderWidgetKey = GlobalKey();
  final _scrollController = ScrollController();
  bool _descOrder =
      appdata.implicitData.length > _kDisplayOrderIndex &&
          appdata.implicitData[_kDisplayOrderIndex] == "1";

  void _toggleDisplayOrder() {
    setState(() => _descOrder = !_descOrder);
    while (appdata.implicitData.length <= _kDisplayOrderIndex) {
      appdata.implicitData.add("0");
    }
    appdata.implicitData[_kDisplayOrderIndex] = _descOrder ? "1" : "0";
    appdata.writeImplicitData();
    showToast(message: (_descOrder ? "倒序".tl : "正序".tl));
  }

  Color _lightenColor(Color color, double lightenValue) {
    double lightenChannel(double v) => v + (1 - v) * lightenValue;
    return Color.fromARGB(
      (color.a * 255).round(),
      (lightenChannel(color.r) * 255).round(),
      (lightenChannel(color.g) * 255).round(),
      (lightenChannel(color.b) * 255).round(),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!PicaServer.instance.enabled) {
      setState(() {
        loading = false;
        error = "未配置服务器".tl;
        folders = const [];
        items = const [];
      });
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final f = await PicaServer.instance.listResourceFavoriteFolders();
      final folderNames =
          f.map((e) => e.name).where((e) => e.trim().isNotEmpty).toList();
      if (folderNames.isEmpty) {
        if (!mounted) return;
        setState(() {
          folders = f;
          selectedFolder = '';
          items = const [];
          loading = false;
          reorderMode = false;
        });
        return;
      }
      final selected = folderNames.contains(selectedFolder)
          ? selectedFolder
          : folderNames.first;
      final list = await PicaServer.instance.listResourceFavorites(selected);
      if (!mounted) return;
      setState(() {
        folders = f;
        selectedFolder = selected;
        items = list;
        loading = false;
        reorderMode = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  Future<void> _loadItems(String folder) async {
    if (!PicaServer.instance.enabled) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final list = await PicaServer.instance.listResourceFavorites(folder);
      if (!mounted) return;
      setState(() {
        selectedFolder = folder;
        items = list;
        loading = false;
        reorderMode = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  Future<void> _createFolder() async {
    final name =
        await promptServerFavoriteFolderName(context, title: "创建收藏夹".tl);
    if (name == null || name.isEmpty) return;
    try {
      await PicaServer.instance.createResourceFavoriteFolder(name);
      await _load();
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  Future<void> _openFolderManager() async {
    final changed = await context.to<bool>(
      () => ServerFavoriteFoldersPage(
        folders: folders.map((e) => e.name).toList(),
        onCreate: (name) =>
            PicaServer.instance.createResourceFavoriteFolder(name),
        onRename: (from, to) =>
            PicaServer.instance.renameResourceFavoriteFolder(from, to),
        onDelete: (name, moveTo) => PicaServer.instance
            .deleteResourceFavoriteFolder(name, moveTo: moveTo),
        onReorder: (names) =>
            PicaServer.instance.reorderResourceFavoriteFolders(names),
      ),
    );
    if (changed == true) {
      await _load();
    }
  }

  Future<void> _moveItem(ServerResourceFavoriteItem item) async {
    final options = folders
        .map((e) => e.name)
        .where((e) => e.trim().isNotEmpty && e != selectedFolder)
        .toList();
    if (options.isEmpty) {
      showToast(message: "没有可移动的收藏夹".tl);
      return;
    }
    final folder =
        await pickFolderFromNames(context, names: options, title: "移动到".tl);
    if (folder == null || !mounted) return;
    try {
      await PicaServer.instance.moveResourceFavorites(
        folder: folder,
        ids: [item.id],
      );
      await _loadItems(selectedFolder);
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  Future<void> _deleteItem(ServerResourceFavoriteItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("删除".tl),
        content: Text("从服务器资源收藏中删除该漫画？".tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text("取消".tl),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text("删除".tl),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await PicaServer.instance.removeResourceFavorite(item.id);
      await _loadItems(selectedFolder);
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  void _openComic(ServerResourceFavoriteItem item) {
    context.to(() => ServerComicPage(comicId: item.id));
  }

  Widget _buildToolbar() {
    final folderNames =
        folders.map((e) => e.name).where((e) => e.trim().isNotEmpty).toList();
    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const SizedBox(width: 8),
                if (folderNames.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text("暂无收藏夹".tl),
                  ),
                for (final name in folderNames)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: ChoiceChip(
                      label: Text(name),
                      selected: name == selectedFolder,
                      onSelected: (_) => _loadItems(name),
                    ),
                  ),
                _buildToolbarAction(
                  tooltip: "创建收藏夹".tl,
                  onPressed: _createFolder,
                  icon: const Icon(Icons.add),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
        _buildToolbarAction(
          tooltip: "管理收藏夹".tl,
          onPressed: folders.isEmpty ? null : _openFolderManager,
          icon: const Icon(Icons.folder_outlined),
        ),
        _buildToolbarAction(
          tooltip: reorderMode ? "完成排序".tl : "排序".tl,
          onPressed: items.isEmpty
              ? null
              : () {
                  final next = !reorderMode;
                  setState(() => reorderMode = next);
                  if (next) {
                    showToast(
                      message:
                          App.isDesktop ? "拖动以排序".tl : "长按并拖动以排序".tl,
                    );
                  }
                },
          icon: Icon(reorderMode ? Icons.check : Icons.swap_vert),
        ),
        _buildToolbarAction(
          tooltip: _descOrder ? "倒序".tl : "正序".tl,
          onPressed:
              (items.isEmpty || reorderMode) ? null : _toggleDisplayOrder,
          icon: Icon(
            _descOrder ? Icons.arrow_downward : Icons.arrow_upward,
          ),
        ),
        _buildToolbarAction(
          tooltip: "刷新".tl,
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  Widget _buildToolbarAction({
    required String tooltip,
    required VoidCallback? onPressed,
    required Widget icon,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: icon,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildGrid() {
    if (items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.collections_bookmark_outlined, size: 56),
          const SizedBox(height: 12),
          Center(child: Text("暂无收藏".tl)),
        ],
      );
    }

    final displayItems = _descOrder ? items.reversed.toList() : items;

    final tiles = List.generate(displayItems.length, (index) {
      final item = displayItems[index];
      return _ServerResourceFavoriteTile(
        item: item,
        onTap: reorderMode ? () {} : () => _openComic(item),
        onMove: () => _moveItem(item),
        onDelete: () => _deleteItem(item),
        enableLongPressed: !reorderMode,
        key: Key(item.id),
      );
    });

    if (!reorderMode) {
      return KeyedSubtree(
        key: const PageStorageKey("server_resource_favorites"),
        child: GridView(
          key: _normalGridKey,
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithComics(),
          children: tiles,
        ),
      );
    }

    return ReorderableBuilder(
      key: _reorderWidgetKey,
      scrollController: _scrollController,
      enableLongPress: !App.isDesktop,
      longPressDelay: App.isDesktop
          ? const Duration(milliseconds: 100)
          : const Duration(milliseconds: 350),
      onReorder: (reorderFunc) async {
        final reordered = List<ServerResourceFavoriteItem>.from(
          reorderFunc(displayItems),
        );
        setState(() {
          items = _descOrder ? reordered.reversed.toList() : reordered;
        });
        try {
          await PicaServer.instance.reorderResourceFavorites(
            folder: selectedFolder,
            ids: items.map((e) => e.id).toList(),
          );
        } catch (e) {
          showToast(message: e.toString());
        }
      },
      dragChildBoxDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: _lightenColor(Theme.of(context).splashColor, 0.2),
      ),
      builder: (children) {
        return KeyedSubtree(
          key: const PageStorageKey("server_resource_favorites"),
          child: GridView(
            key: _reorderGridKey,
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithComics(),
            children: children,
          ),
        );
      },
      children: tiles,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return NetworkError(message: error!, retry: _load, withAppbar: false);
    }
    return Column(
      children: [
        const SizedBox(height: 8),
        SizedBox(height: 44, child: _buildToolbar()),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _buildGrid(),
          ),
        ),
      ],
    );
  }
}

class _ServerResourceFavoriteTile extends ComicTile {
  const _ServerResourceFavoriteTile({
    required this.item,
    required this.onTap,
    required this.onMove,
    required this.onDelete,
    required this.enableLongPressed,
    super.key,
  });

  final ServerResourceFavoriteItem item;
  final VoidCallback onTap;
  final VoidCallback onMove;
  final VoidCallback onDelete;
  @override
  final bool enableLongPressed;

  @override
  Widget get image {
    final url = item.coverUrl;
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
  String get title => item.title;

  @override
  String get subTitle => "";

  @override
  String get description => item.subtitle;

  @override
  List<String>? get tags => item.tags;

  @override
  bool get showFavorite => false;

  @override
  List<ComicTileMenuOption>? get addonMenuOptions => [
        ComicTileMenuOption("移动到收藏夹".tl, Icons.drive_file_move_outline,
            (_, __, ___) => onMove()),
        ComicTileMenuOption("从服务器资源收藏删除".tl, Icons.delete_outline,
            (_, __, ___) => onDelete()),
      ];

  @override
  void onTap_() => onTap();
}
