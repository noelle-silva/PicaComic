import 'package:flutter/material.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/comic_source/comic_source.dart';

import 'network_favorite_page.dart';
import 'server_favorites.dart';

/// 网络收藏区的一个条目：漫画源的网络收藏夹，或服务器收藏。
///
/// [key] 为持久化标识（存于网络收藏页面配置），[title] 为显示名（展示时翻译）。
class NetworkFavoriteEntry {
  const NetworkFavoriteEntry({
    required this.key,
    required this.title,
    required this.buildContent,
  });

  final String key;

  final String title;

  /// 打开该收藏集的内容（显示在收藏页内容区），[key] 用于保持页面状态。
  final Widget Function(Key key) buildContent;
}

/// 全部网络收藏条目：漫画源收藏 + 服务器收藏。
List<NetworkFavoriteEntry> allNetworkFavoriteEntries() => [
      for (var source in ComicSource.sources)
        if (source.favoriteData != null)
          NetworkFavoriteEntry(
            key: source.favoriteData!.key,
            title: source.favoriteData!.title,
            buildContent: (key) =>
                NetworkFavoritePage(source.favoriteData!, key: key),
          ),
      NetworkFavoriteEntry(
        key: kServerFavoritesKey,
        title: "服务器收藏",
        buildContent: (key) => ServerFavoritesView(key: key),
      ),
    ];

/// 已配置显示的网络收藏条目（按配置顺序，过滤无效项）。
List<NetworkFavoriteEntry> configuredNetworkFavoriteEntries() {
  var entries = {
    for (var entry in allNetworkFavoriteEntries()) entry.key: entry,
  };
  return appdata.appSettings.networkFavorites
      .map((key) => entries[key])
      .whereType<NetworkFavoriteEntry>()
      .toList();
}
