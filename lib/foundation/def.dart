import 'package:flutter/material.dart';

typedef ActionFunc = void Function();

enum ComicType {
  picacg,
  ehentai,
  jm,
  hitomi,
  htManga,
  htFavorite,
  nhentai,
  other;

  @override
  toString() => name;
}

/// 底栏主页面标识。枚举顺序即底栏顺序，作为页面顺序的唯一事实源。
///
/// [name] 为稳定语义 id（用于持久化，勿随意更改），[label] 为显示名（展示时翻译）。
enum HomePageId {
  me('主页'),
  search('搜索'),
  favorites('收藏'),
  explore('探索');

  const HomePageId(this.label);

  final String label;
}

const String webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36";

//App版本
const appVersion = "4.2.10";

//定义宽屏设备的临界值
const changePoint = 600;
const changePoint2 = 1300;

List<MaterialAccentColor> get colors => [
  Colors.redAccent,
  Colors.pinkAccent,
  Colors.purpleAccent,
  Colors.indigoAccent,
  Colors.blueAccent,
  Colors.cyanAccent,
  Colors.tealAccent,
  Colors.greenAccent,
  Colors.limeAccent,
  Colors.yellowAccent,
  Colors.amberAccent,
  Colors.orangeAccent,
];

const builtInSources = [
  "picacg",
  "ehentai",
  "jm",
  "hitomi",
  "htmanga",
  "nhentai"
];

/// 服务器收藏在网络收藏页面配置中的标识。
const kServerFavoritesKey = "pica_server";

/// 服务器资源收藏在网络收藏页面配置中的标识。
const kServerResourceFavoritesKey = "pica_server_resource";

/// 服务器漫画在历史记录/阅读数据等体系中的目标前缀。
const kServerComicPrefix = "server:";