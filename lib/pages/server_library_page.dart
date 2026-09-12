import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/translations.dart';

import 'server_comic_page.dart';

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
          _ComicCountIndicator(
            countText: loading
                ? "…"
                : error != null
                    ? "--"
                    : comics.length.toString(),
          ),
          IconButton(
            tooltip: "搜索".tl,
            onPressed: (loading || error != null)
                ? null
                : () {
                    context
                        .to<bool>(() => ServerLibrarySearchPage(comics: comics))
                        .then((changed) {
                      if (changed == true) _load();
                    });
                  },
            icon: const Icon(Icons.search),
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
        return ServerComicTile(
          comic,
          onTap: () => _openComic(context, comic),
        );
      },
    );
  }

  void _openComic(BuildContext context, ServerComic comic) {
    context.to<bool>(() => ServerComicPage(comicId: comic.id)).then((changed) {
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

class _ComicCountIndicator extends StatelessWidget {
  const _ComicCountIndicator({required this.countText});

  final String countText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Center(
        child: Tooltip(
          message: "服务器漫画总数".tl,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                countText,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ServerLibrarySearchPage extends StatefulWidget {
  const ServerLibrarySearchPage({super.key, required this.comics});

  final List<ServerComic> comics;

  @override
  State<ServerLibrarySearchPage> createState() =>
      _ServerLibrarySearchPageState();
}

class _ServerLibrarySearchPageState extends State<ServerLibrarySearchPage> {
  final controller = TextEditingController();
  final focusNode = FocusNode();

  late List<ServerComic> comics;
  String keyword = "";
  bool changed = false;
  bool allowPop = false;

  @override
  void initState() {
    super.initState();
    comics = List.of(widget.comics);
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    controller.dispose();
    focusNode.dispose();
    super.dispose();
  }

  bool _match(ServerComic comic, String keyword) {
    final k = keyword.trim().toLowerCase();
    if (k.isEmpty) return true;
    if (comic.title.toLowerCase().contains(k)) return true;
    if (comic.subtitle.toLowerCase().contains(k)) return true;
    if (comic.id.toLowerCase().contains(k)) return true;
    for (final t in comic.tags) {
      if (t.toLowerCase().contains(k)) return true;
    }
    return false;
  }

  Future<void> _openComic(BuildContext context, ServerComic comic) async {
    final res =
        await context.to<bool>(() => ServerComicPage(comicId: comic.id));
    if (res == true && mounted) {
      setState(() {
        changed = true;
        comics.removeWhere((c) => c.id == comic.id);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = comics.where((c) => _match(c, keyword)).toList();

    return PopScope(
      canPop: allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        setState(() => allowPop = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop(changed);
        });
      },
      child: Scaffold(
        appBar: AppBar(
          title: TextField(
            focusNode: focusNode,
            controller: controller,
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: "搜索".tl,
            ),
            onChanged: (s) => setState(() => keyword = s),
          ),
          actions: [
            if (keyword.isNotEmpty)
              IconButton(
                tooltip: "清除".tl,
                onPressed: () {
                  controller.clear();
                  setState(() => keyword = "");
                },
                icon: const Icon(Icons.clear_rounded),
              ),
          ],
        ),
        body: filtered.isEmpty
            ? ListView(
                children: [
                  const SizedBox(height: 120),
                  const Icon(Icons.search_off_outlined, size: 56),
                  const SizedBox(height: 12),
                  Center(child: Text("无匹配结果".tl)),
                ],
              )
            : GridView.builder(
                gridDelegate: SliverGridDelegateWithComics(),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final comic = filtered[index];
                  return ServerComicTile(
                    comic,
                    onTap: () => _openComic(context, comic),
                  );
                },
              ),
      ),
    );
  }
}
