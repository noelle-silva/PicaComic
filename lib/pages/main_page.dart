import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pica_comic/base.dart';
import 'package:pica_comic/components/components.dart';
import 'package:pica_comic/foundation/app_page_route.dart';
import 'package:pica_comic/network/webdav.dart';
import 'package:pica_comic/tools/app_links.dart';
import 'package:pica_comic/tools/background_service.dart';
import 'package:pica_comic/tools/translations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'explore_page.dart';
import 'favorites/main_favorites_page.dart';
import 'pre_search_page.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/update.dart';
import 'me_page.dart';
import 'package:pica_comic/network/picacg_network/methods.dart';

bool _haveClipboardDialog = false;

void checkClipboard() async {
  if (appdata.settings[61] == "0") {
    return;
  }
  var data = await Clipboard.getData(Clipboard.kTextPlain);
  if (data?.text != null && canHandle(data!.text!)) {
    await Future.delayed(const Duration(milliseconds: 200));
    if (_haveClipboardDialog) {
      return;
    }
    _haveClipboardDialog = true;
    await showDialog(
      context: App.globalContext!,
      builder: (context) => ContentDialog(
        title: "发现剪切板中的链接".tl,
        content: Text(data.text!),
        actions: [
          TextButton(
            onPressed: () {
              App.globalContext!.pop();
              handleAppLinks(Uri.parse(data.text!));
            },
            child: Text("打开".tl),
          ),
        ],
      ),
    );
    _haveClipboardDialog = false;
  }
}

class MainPage extends StatefulWidget {
  const MainPage({Key? key}) : super(key: key);

  static MainPageState of(BuildContext context) {
    return context.findAncestorStateOfType<MainPageState>()!;
  }

  @override
  State<MainPage> createState() => MainPageState();
}

class MainPageState extends State<MainPage> {
  /// 每个主页面各自持有独立页面栈，互不干扰，切换时保活。
  final _navigatorKeys = <HomePageId, GlobalKey<NavigatorState>>{
    for (var id in HomePageId.values) id: GlobalKey<NavigatorState>(),
  };

  final _observers = <HomePageId, NaviObserver>{
    for (var id in HomePageId.values) id: NaviObserver(),
  };

  late final List<NaviObserver> _observerList = [
    for (var id in HomePageId.values) _observers[id]!,
  ];

  /// 各主页面 Navigator 专属的观察者列表（稳定实例，避免重建时反复换绑）。
  late final Map<HomePageId, List<NaviObserver>> _navigatorObservers = {
    for (var id in HomePageId.values) id: List.unmodifiable([_observers[id]!]),
  };

  /// 已进入过的主页面。首次访问才创建页面栈，之后一直保活。
  final _visitedPages = <HomePageId>{};

  late HomePageId _currentPageId = HomePageId.values[_initialPageIndex];

  void to(Widget Function() widget, {bool preventDuplicate = false}) {
    if (preventDuplicate) {
      var page = widget();
      var routes = _observers[_currentPageId]!.routes;
      if (routes.isNotEmpty &&
          "/${page.runtimeType}" == routes.last.toString()) {
        return;
      }
    }
    App.to(App.mainNavigatorKey!.currentContext!, widget);
  }

  void back() {
    App.mainNavigatorKey!.currentContext!.pop();
  }

  Widget _buildPage(HomePageId id) => switch (id) {
        HomePageId.me => const MePage(),
        HomePageId.search => const PreSearchPage(),
        HomePageId.favorites => FavoritesPage(),
        HomePageId.explore => ExplorePage(key: Key(appdata.settings[77])),
      };

  Widget _buildPageNavigator(HomePageId id) {
    return Navigator(
      key: _navigatorKeys[id],
      observers: _navigatorObservers[id]!,
      onGenerateRoute: (settings) => AppPageRoute(
        preventRebuild: false,
        isRootRoute: true,
        builder: (context) {
          return NaviPaddingWidget(child: _buildPage(id));
        },
      ),
    );
  }

  /// 内容区：只显示当前主页面，其余冻结保活（不绘制、动画暂停，状态保留）。
  Widget _buildPageContent(int index) {
    var current = HomePageId.values[index];
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var id in HomePageId.values)
          if (_visitedPages.contains(id))
            TickerMode(
              enabled: id == current,
              child: Offstage(
                offstage: id != current,
                child: _buildPageNavigator(id),
              ),
            ),
      ],
    );
  }

  PaneItemEntry _paneEntry(HomePageId id) {
    var (icon, activeIcon) = switch (id) {
      HomePageId.me => (Icons.home_outlined, Icons.home),
      HomePageId.search => (Icons.search_outlined, Icons.search),
      HomePageId.favorites =>
        (Icons.local_activity_outlined, Icons.local_activity),
      HomePageId.explore => (Icons.explore_outlined, Icons.explore),
    };
    return PaneItemEntry(
        label: id.label.tl, icon: icon, activeIcon: activeIcon);
  }

  int get _initialPageIndex {
    var index = HomePageId.values
        .indexWhere((e) => e.name == appdata.appSettings.initialPage);
    return index < 0 ? 0 : index;
  }

  void _login() {
    network.updateProfile().then((res) {
      if (res.error) {
        showToast(message: res.errorMessageWithoutNull);
      } else {
        //检查是否打卡
        if (network.user?.isPunched == false && appdata.settings[6] == "1") {
          if (App.isMobile) {
            runBackgroundService();
          } else {
            network.user?.isPunched = true;
            network.punchIn().then((b) {
              if (b) {
                showToast(message: "打卡成功".tl);
                network.user?.exp += 10;
              }
            });
          }
        }
      }
    });
  }

  void _checkUpdates() async {
    var s = await SharedPreferences.getInstance();
    var lastCheck = s.getInt("lastCheckUpdate");
    if (lastCheck != null) {
      if (DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastCheck)).inDays < 1) {
        return;
      }
    }
    if (appdata.settings[2] != "1") {
      return;
    }
    var res = await checkUpdate();
    s.setInt("lastCheckUpdate", DateTime.now().millisecondsSinceEpoch);
    if (res != true) return;
    var info = await getUpdatesInfo();
    if (info == null) return;
    showDialog(
        context: App.globalContext!,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text("有可用更新".tl),
            content: Text(info),
            actions: [
              TextButton(
                  onPressed: () {
                    dialogContext.pop();
                    appdata.settings[2] = "0";
                    appdata.writeData();
                  },
                  child: const Text("关闭更新检查")),
              TextButton(onPressed: dialogContext.pop, child: Text("取消".tl)),
              TextButton(
                  onPressed: () {
                    getDownloadUrl().then((s) {
                      launchUrlString(s, mode: LaunchMode.externalApplication);
                    });
                  },
                  child: Text("下载".tl))
            ],
          );
        });

    // if (appdata.settings[80] == "1") {
    //   ComicSourceSettings.checkCustomComicSourceUpdate();
    // }
  }

  void _checkDownload() {
    if (downloadManager.downloading.isNotEmpty) {
      Future.delayed(const Duration(microseconds: 500), () {
        if (mounted) {
          showDialog(
            context: context,
            builder: (dialogContext) {
              return AlertDialog(
                title: Text("下载管理器".tl),
                content: Text("继续未完成的下载?".tl),
                actions: [
                  TextButton(onPressed: dialogContext.pop, child: Text("否".tl)),
                  TextButton(
                      onPressed: () {
                        downloadManager.start();
                        dialogContext.pop();
                      },
                      child: Text("是".tl))
                ],
              );
            },
          );
        }
      });
    }
  }

  @override
  void initState() {
    _visitedPages.add(_currentPageId);
    App.mainNavigatorKey = _navigatorKeys[_currentPageId];
    _login();
    notifications.requestPermission();
    notifications.cancelAll();
    _checkUpdates();
    _checkDownload();

    if (appdata.firstUse[3] == "0") {
      appdata.firstUse[3] = "1";
      appdata.writeData();
    }

    Future.delayed(const Duration(milliseconds: 300), () => Webdav.syncData())
        .then((v) => checkClipboard());
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return NaviPane(
      initialPage: _initialPageIndex,
      observers: _observerList,
      paneItems: [for (var id in HomePageId.values) _paneEntry(id)],
      paneActions: const [],
      pageBuilder: _buildPageContent,
      onPageChange: (index) {
        HapticFeedback.selectionClick();
        var id = HomePageId.values[index];
        _currentPageId = id;
        App.mainNavigatorKey = _navigatorKeys[id];
        FocusManager.instance.primaryFocus?.unfocus();
        if (_visitedPages.add(id)) {
          setState(() {});
        }
      },
    );
  }
}
