import 'package:flutter/material.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/pica_server.dart';
import 'package:pica_comic/tools/translations.dart';

import 'server_comic_page.dart';

/// 服务器标签组合搜索结果页（按标签 AND 过滤服务器漫画库）。
class ServerTagSearchPage extends StatefulWidget {
  const ServerTagSearchPage({super.key, required this.tags});

  /// 参与组合筛选的标签（结果需同时包含全部标签）。
  final List<String> tags;

  @override
  State<ServerTagSearchPage> createState() => _ServerTagSearchPageState();
}

class _ServerTagSearchPageState extends State<ServerTagSearchPage> {
  bool loading = true;
  String? error;
  List<ServerComic> results = const [];

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
      final all = await PicaServer.instance.listComics();
      final filtered = all
          .where((comic) => widget.tags.every(comic.tags.contains))
          .toList();
      if (!mounted) return;
      setState(() {
        results = filtered;
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
        title: Text("标签搜索".tl),
        actions: [
          IconButton(
            tooltip: "刷新".tl,
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in widget.tags)
                  Chip(
                    label: Text(tag),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
              ],
            ),
          ),
          if (!loading && error == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                "共 @num 本".tlParams({"num": results.length.toString()}),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return NetworkError(message: error!, retry: _load, withAppbar: false);
    }
    if (results.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.search_off_outlined, size: 56),
          const SizedBox(height: 12),
          Center(child: Text("没有匹配的漫画".tl)),
        ],
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: SliverGridDelegateWithComics(),
      itemCount: results.length,
      itemBuilder: (context, i) {
        final comic = results[i];
        return ServerComicTile(
          comic,
          onTap: () => context.to(() => ServerComicPage(comicId: comic.id)),
        );
      },
    );
  }
}
