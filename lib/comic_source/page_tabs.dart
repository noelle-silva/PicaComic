part of comic_source;

/// 页面栏类型。
enum PageTabType {
  /// 漫画源的探索页（[ExplorePageData]）。
  explore,

  /// 漫画源的分类页（[CategoryData]）。
  category,
}

/// 探索页中一个页面栏的统一引用。
///
/// 探索栏与分类栏来源不同，但同属探索页的一种栏。序列化格式为
/// "<type>:<id>"，作为配置持久化在 settings 中，并作为栏在界面上的唯一标识
/// （探索页标题与分类页 key 允许同值，因此必须带类型命名空间）。
class PageTab {
  final PageTabType type;

  /// [PageTabType.explore] 时为探索页标题；[PageTabType.category] 时为分类页 key。
  final String id;

  const PageTab(this.type, this.id);

  const PageTab.explore(String title) : this(PageTabType.explore, title);

  const PageTab.category(String key) : this(PageTabType.category, key);

  String get serialized => "${type.name}:$id";

  static PageTab? tryParse(String raw) {
    var separator = raw.indexOf(':');
    if (separator <= 0 || separator == raw.length - 1) {
      return null;
    }
    var typeName = raw.substring(0, separator);
    var id = raw.substring(separator + 1);
    for (var type in PageTabType.values) {
      if (type.name == typeName) {
        return PageTab(type, id);
      }
    }
    return null;
  }

  /// 对应的探索页数据；非探索栏或对应源不可用时为 null。
  ExplorePageData? get exploreData {
    if (type != PageTabType.explore) {
      return null;
    }
    for (var source in ComicSource.sources) {
      for (var page in source.explorePages) {
        if (page.title == id) {
          return page;
        }
      }
    }
    return null;
  }

  /// 对应的分类页数据；非分类栏或对应源不可用时为 null。
  CategoryData? get categoryData {
    if (type != PageTabType.category) {
      return null;
    }
    for (var source in ComicSource.sources) {
      if (source.categoryData?.key == id) {
        return source.categoryData;
      }
    }
    return null;
  }

  /// 当前漫画源是否能提供此栏。
  bool get isValid => exploreData != null || categoryData != null;

  /// 显示用标题；无法解析时回退为原始 id。
  String get displayTitle => exploreData?.title ?? categoryData?.title ?? id;

  /// 所有漫画源当前可提供的页面栏（每源先探索栏后分类栏）。
  static List<PageTab> get allAvailable => [
        for (var source in ComicSource.sources) ...[
          for (var page in source.explorePages) PageTab.explore(page.title),
          if (source.categoryData != null)
            PageTab.category(source.categoryData!.key),
        ],
      ];

  /// 用户配置的页面栏（按配置顺序，过滤无法识别与不可用的条目）。
  static List<PageTab> get configured => appdata.appSettings.pageTabs
      .map(PageTab.tryParse)
      .whereType<PageTab>()
      .where((e) => e.isValid)
      .toList();
}

/// 将旧版分离存储的探索/分类页面配置合并为统一的页面栏配置。
///
/// 旧数据中探索栏（裸标题）与分类栏（裸 key）分别存储，合并时仍保持
/// "探索栏全部在前、分类栏全部在后"的顺序。幂等：可在每个数据入口重复调用。
Future<void> migratePageTabSettings() async {
  var tabs = appdata.appSettings.pageTabs.where((e) => e.isNotEmpty).toList();
  var legacyCategories = appdata.appSettings.legacyCategoryPages
      .where((e) => e.isNotEmpty)
      .toList();
  var needMigrate = legacyCategories.isNotEmpty ||
      tabs.any((e) => PageTab.tryParse(e) == null);
  if (!needMigrate) {
    return;
  }

  var merged = <String>{};
  for (var raw in tabs) {
    merged.add(
        PageTab.tryParse(raw) != null ? raw : PageTab.explore(raw).serialized);
  }
  for (var raw in legacyCategories) {
    merged.add(PageTab.category(raw).serialized);
  }

  appdata.appSettings.pageTabs = merged.toList();
  appdata.appSettings.legacyCategoryPages = [];
  if (appdata.settings[23] == "3") {
    appdata.settings[23] = "2";
  }
  await appdata.updateSettings(false);
}
