part of comic_source;

/// 应用级旧数据迁移入口（幂等，可在每个数据入口重复调用）。
///
/// 覆盖所有"旧格式数据进入内存"的入口：应用启动读取与数据导入。
Future<void> migrateLegacySettings() async {
  var pageTabsMigrated = _migratePageTabSettings();
  var initialPageMigrated = _migrateInitialPageSetting();
  if (!pageTabsMigrated && !initialPageMigrated) {
    return;
  }
  await appdata.updateSettings(false);
}

/// 将旧版分离存储的探索/分类页面配置合并为统一的页面栏配置。
///
/// 旧数据中探索栏（裸标题）与分类栏（裸 key）分别存储，合并时仍保持
/// "探索栏全部在前、分类栏全部在后"的顺序。返回是否发生迁移。
bool _migratePageTabSettings() {
  var tabs = appdata.appSettings.pageTabs.where((e) => e.isNotEmpty).toList();
  var legacyCategories = appdata.appSettings.legacyCategoryPages
      .where((e) => e.isNotEmpty)
      .toList();
  var needMigrate = legacyCategories.isNotEmpty ||
      tabs.any((e) => PageTab.tryParse(e) == null);
  if (!needMigrate) {
    return false;
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
  return true;
}

/// 将旧版初始页面位置索引迁移为 [HomePageId] 语义 id。
///
/// 旧索引含义：0-我, 1-收藏, 2-探索, 3-分类（分类已并入探索）。返回是否发生迁移。
bool _migrateInitialPageSetting() {
  var migrated = switch (appdata.appSettings.initialPage) {
    "0" => HomePageId.me.name,
    "1" => HomePageId.favorites.name,
    "2" => HomePageId.explore.name,
    "3" => HomePageId.explore.name,
    _ => null,
  };
  if (migrated == null) {
    return false;
  }
  appdata.appSettings.initialPage = migrated;
  return true;
}
