import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/image_loader/cached_image.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/tools/translations.dart';

class ServerFavoritesPage extends StatefulWidget {
  const ServerFavoritesPage({super.key});

  @override
  State<ServerFavoritesPage> createState() => _ServerFavoritesPageState();
}

class _ServerFavoritesPageState extends State<ServerFavoritesPage> {
  bool loading = true;
  String? error;

  List<ServerFavoriteFolder> folders = const [];
  String selectedFolder = '';
  List<ServerFavoriteItem> items = const [];

  bool reorderMode = false;
  final Key _gridKey = UniqueKey();
  final _reorderWidgetKey = GlobalKey();
  final _scrollController = ScrollController();

  Color _lightenColor(Color color, double lightenValue) {
    final red = (color.red + ((255 - color.red) * lightenValue)).round();
    final green = (color.green + ((255 - color.green) * lightenValue)).round();
    final blue = (color.blue + ((255 - color.blue) * lightenValue)).round();
    return Color.fromARGB(color.alpha, red, green, blue);
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
      final f = await PicaServer.instance.listFavoriteFolders();
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
      final list = await PicaServer.instance.listFavorites(selected);
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
      final list = await PicaServer.instance.listFavorites(folder);
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

  Future<String?> _promptFolderName({
    required String title,
    String? initial,
  }) async {
    final controller = TextEditingController(text: initial ?? '');
    final focusNode = FocusNode()..requestFocus();
    final res = await showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text(title),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: "名称".tl,
                ),
                onEditingComplete: () {
                  final v = controller.text.trim();
                  Navigator.of(context).pop(v.isEmpty ? null : v);
                },
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 40,
              child: Center(
                child: FilledButton(
                  onPressed: () {
                    final v = controller.text.trim();
                    Navigator.of(context).pop(v.isEmpty ? null : v);
                  },
                  child: Text("提交".tl),
                ),
              ),
            ),
          ],
        );
      },
    );
    focusNode.dispose();
    controller.dispose();
    return res?.trim();
  }

  Future<void> _createFolder() async {
    final name = await _promptFolderName(title: "创建收藏夹".tl);
    if (name == null || name.isEmpty) return;
    try {
      await PicaServer.instance.createFavoriteFolder(name);
      await _load();
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  Future<void> _openFolderManager() async {
    final changed = await context.to<bool>(
      () => ServerFavoriteFoldersPage(
        folders: folders.map((e) => e.name).toList(),
        selected: selectedFolder,
      ),
    );
    if (changed == true) {
      await _load();
    }
  }

  Future<String?> _pickFolder({
    required List<String> options,
    required String title,
  }) async {
    return showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text(title),
          children: [
            for (final name in options)
              ListTile(
                title: Text(name),
                onTap: () => Navigator.of(context).pop(name),
              ),
          ],
        );
      },
    );
  }

  Future<void> _moveItem(ServerFavoriteItem item) async {
    final options = folders
        .map((e) => e.name)
        .where((e) => e.trim().isNotEmpty && e != selectedFolder)
        .toList();
    if (options.isEmpty) {
      showToast(message: "没有可移动的收藏夹".tl);
      return;
    }
    final folder = await _pickFolder(options: options, title: "移动到".tl);
    if (folder == null) return;
    try {
      await PicaServer.instance.moveFavorites(
        folder: folder,
        items: [item.key],
      );
      await _loadItems(selectedFolder);
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  Future<void> _deleteItem(ServerFavoriteItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("删除".tl),
        content: Text("从服务器收藏中删除该漫画？".tl),
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
    if (ok != true) return;
    try {
      await PicaServer.instance.removeFavorite(
        sourceKey: item.sourceKey,
        target: item.target,
      );
      await _loadItems(selectedFolder);
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  void _openComic(ServerFavoriteItem item) {
    context.to(
      () => ComicPage(
        sourceKey: item.sourceKey,
        id: item.target,
        cover: item.cover,
      ),
    );
  }

  Widget _buildFoldersRow() {
    final folderNames =
        folders.map((e) => e.name).where((e) => e.trim().isNotEmpty).toList();
    if (folderNames.isEmpty) {
      return Row(
        children: [
          const SizedBox(width: 12),
          Text("暂无收藏夹".tl),
          const Spacer(),
          IconButton(
            tooltip: "创建收藏夹".tl,
            onPressed: _createFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
        ],
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          const SizedBox(width: 8),
          for (final name in folderNames)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: ChoiceChip(
                label: Text(name),
                selected: name == selectedFolder,
                onSelected: (_) => _loadItems(name),
              ),
            ),
          IconButton(
            tooltip: "创建收藏夹".tl,
            onPressed: _createFolder,
            icon: const Icon(Icons.add),
          ),
          const SizedBox(width: 8),
        ],
      ),
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

    final tiles = List.generate(items.length, (index) {
      final item = items[index];
      return _ServerFavoriteTile(
        item: item,
        onTap: () => _openComic(item),
        onMove: () => _moveItem(item),
        onDelete: () => _deleteItem(item),
        enableLongPressed: !reorderMode,
        key: Key('${item.sourceKey}::${item.target}'),
      );
    });

    if (!reorderMode) {
      return GridView(
        key: _gridKey,
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithComics(),
        children: tiles,
      );
    }

    return ReorderableBuilder(
      key: _reorderWidgetKey,
      scrollController: _scrollController,
      longPressDelay: App.isDesktop
          ? const Duration(milliseconds: 100)
          : const Duration(milliseconds: 500),
      onReorder: (reorderFunc) async {
        final reordered = reorderFunc(items);
        setState(() {
          items = List<ServerFavoriteItem>.from(reordered);
        });
        try {
          await PicaServer.instance.reorderFavorites(
            folder: selectedFolder,
            items: items.map((e) => e.key).toList(),
          );
        } catch (e) {
          showToast(message: e.toString());
        }
      },
      dragChildBoxDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: _lightenColor(Theme.of(context).splashColor.withOpacity(1), 0.2),
      ),
      builder: (children) {
        return GridView(
          key: _gridKey,
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithComics(),
          children: children,
        );
      },
      children: tiles,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("服务器收藏".tl),
        actions: [
          IconButton(
            tooltip: "管理收藏夹".tl,
            onPressed: folders.isEmpty ? null : _openFolderManager,
            icon: const Icon(Icons.folder_outlined),
          ),
          IconButton(
            tooltip: reorderMode ? "完成排序".tl : "排序".tl,
            onPressed: items.isEmpty
                ? null
                : () => setState(() => reorderMode = !reorderMode),
            icon: Icon(reorderMode ? Icons.check : Icons.swap_vert),
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
              ? NetworkError(message: error!, retry: _load)
              : Column(
                  children: [
                    const SizedBox(height: 8),
                    SizedBox(height: 44, child: _buildFoldersRow()),
                    const Divider(height: 1),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _load,
                        child: _buildGrid(),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _ServerFavoriteTile extends ComicTile {
  const _ServerFavoriteTile({
    required this.item,
    required this.onTap,
    required this.onMove,
    required this.onDelete,
    required this.enableLongPressed,
    super.key,
  });

  final ServerFavoriteItem item;
  final VoidCallback onTap;
  final VoidCallback onMove;
  final VoidCallback onDelete;
  @override
  final bool enableLongPressed;

  @override
  Widget get image => AnimatedImage(
        image: CachedImageProvider(
          item.cover,
          sourceKey: item.sourceKey,
        ),
        fit: BoxFit.cover,
        height: double.infinity,
        width: double.infinity,
        filterQuality: FilterQuality.medium,
      );

  @override
  String get title => item.title;

  @override
  String get subTitle => item.subtitle;

  @override
  String get description => item.sourceKey;

  @override
  List<String>? get tags => item.tags;

  @override
  bool get showFavorite => false;

  @override
  List<ComicTileMenuOption>? get addonMenuOptions => [
        ComicTileMenuOption("移动到收藏夹".tl, Icons.drive_file_move_outline,
            (_, __, ___) => onMove()),
        ComicTileMenuOption(
            "从服务器收藏删除".tl, Icons.delete_outline, (_, __, ___) => onDelete()),
      ];

  @override
  void onTap_() => onTap();
}

class ServerFavoriteFoldersPage extends StatefulWidget {
  const ServerFavoriteFoldersPage({
    super.key,
    required this.folders,
    required this.selected,
  });

  final List<String> folders;
  final String selected;

  @override
  State<ServerFavoriteFoldersPage> createState() =>
      _ServerFavoriteFoldersPageState();
}

class _ServerFavoriteFoldersPageState extends State<ServerFavoriteFoldersPage> {
  late List<String> folders = List<String>.from(widget.folders);
  bool changed = false;

  Future<String?> _promptName(String title, {String? initial}) async {
    final controller = TextEditingController(text: initial ?? '');
    final focusNode = FocusNode()..requestFocus();
    final res = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(title),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: "名称".tl,
              ),
              onEditingComplete: () {
                final v = controller.text.trim();
                Navigator.of(context).pop(v.isEmpty ? null : v);
              },
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 40,
            child: Center(
              child: FilledButton(
                onPressed: () {
                  final v = controller.text.trim();
                  Navigator.of(context).pop(v.isEmpty ? null : v);
                },
                child: Text("提交".tl),
              ),
            ),
          ),
        ],
      ),
    );
    focusNode.dispose();
    controller.dispose();
    return res?.trim();
  }

  Future<void> _createFolder() async {
    final name = await _promptName("创建收藏夹".tl);
    if (name == null || name.isEmpty) return;
    try {
      await PicaServer.instance.createFavoriteFolder(name);
      changed = true;
      setState(() {
        folders.add(name);
      });
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  Future<void> _renameFolder(String from) async {
    final to = await _promptName("重命名".tl, initial: from);
    if (to == null || to.isEmpty || to == from) return;
    try {
      await PicaServer.instance.renameFavoriteFolder(from, to);
      changed = true;
      setState(() {
        final idx = folders.indexOf(from);
        if (idx >= 0) folders[idx] = to;
      });
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  Future<void> _deleteFolder(String name) async {
    final moveToOptions = folders.where((e) => e != name).toList();
    if (moveToOptions.isEmpty) {
      showToast(message: "至少保留一个收藏夹".tl);
      return;
    }
    final moveTo = await showDialog<String>(
      context: context,
      builder: (context) {
        var selected = moveToOptions.first;
        return StatefulBuilder(builder: (context, setState) {
          return AlertDialog(
            title: Text("删除收藏夹".tl),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("将该收藏夹的漫画移动到:".tl),
                const SizedBox(height: 8),
                Select(
                  outline: true,
                  width: 220,
                  values: moveToOptions,
                  initialValue: moveToOptions.indexOf(selected),
                  onChange: (i) => setState(() => selected = moveToOptions[i]),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: Text("取消".tl),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(selected),
                child: Text("删除".tl),
              ),
            ],
          );
        });
      },
    );
    if (moveTo == null) return;
    try {
      await PicaServer.instance.deleteFavoriteFolder(name, moveTo: moveTo);
      changed = true;
      setState(() {
        folders.remove(name);
      });
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  Future<void> _persistOrder() async {
    try {
      await PicaServer.instance.reorderFavoriteFolders(folders);
      changed = true;
    } catch (e) {
      showToast(message: e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("管理收藏夹".tl),
        actions: [
          IconButton(
            tooltip: "创建收藏夹".tl,
            onPressed: _createFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
        ],
        leading: BackButton(
          onPressed: () => Navigator.of(context).pop(changed),
        ),
      ),
      body: ReorderableListView.builder(
        itemCount: folders.length,
        onReorder: (oldIndex, newIndex) async {
          if (newIndex > oldIndex) newIndex -= 1;
          setState(() {
            final item = folders.removeAt(oldIndex);
            folders.insert(newIndex, item);
          });
          await _persistOrder();
        },
        itemBuilder: (context, index) {
          final name = folders[index];
          return ListTile(
            key: Key(name),
            leading: const Icon(Icons.drag_handle),
            title: Text(name),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: "重命名".tl,
                  onPressed: () => _renameFolder(name),
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: "删除".tl,
                  onPressed: () => _deleteFolder(name),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
