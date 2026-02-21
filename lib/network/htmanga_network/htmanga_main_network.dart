import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:pica_comic/comic_source/built_in/ht_manga.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:pica_comic/network/cache_network.dart';
import 'package:pica_comic/network/cookie_jar.dart';
import 'package:pica_comic/network/htmanga_network/models.dart';
import 'package:pica_comic/network/app_dio.dart';
import 'package:pica_comic/network/res.dart';
import 'package:html/dom.dart' show Element;
import 'package:html/parser.dart';
import 'package:pica_comic/pages/pre_search_page.dart';
import 'package:pica_comic/tools/extensions.dart';
import 'package:pica_comic/tools/translations.dart';
import '../../base.dart';

class HtmangaNetwork {
  ///用于获取绅士漫画的网络请求类
  factory HtmangaNetwork() => _cache ?? (_cache = HtmangaNetwork._create());

  static HtmangaNetwork? _cache;

  HtmangaNetwork._create();

  static String get baseUrl => appdata.settings[31];

  String _absUrl(String urlOrPath) {
    try {
      return Uri.parse(baseUrl).resolve(urlOrPath).toString();
    } catch (_) {
      return urlOrPath;
    }
  }

  String _dedupTitle(String title, Map<String, String> map) {
    if (!map.containsKey(title)) return title;
    for (int i = 2;; i++) {
      final t = "$title($i)";
      if (!map.containsKey(t)) return t;
    }
  }

  String? _extractComicId(String url) {
    final match = RegExp(r"(?:-aid-|aid=)(\d+)").firstMatch(url);
    return match?.group(1);
  }

  int _extractPages(String text) {
    final m = RegExp(r"(\d+)\s*[Pp頁页]").firstMatch(text) ??
        RegExp(r"頁數[:：]\s*(\d+)").firstMatch(text);
    if (m == null) return 0;
    return int.tryParse(m.group(1) ?? "") ?? 0;
  }

  String _extractTime(String text) {
    final m = RegExp(r"(\d{4}[-/]\d{1,2}[-/]\d{1,2})").firstMatch(text);
    return m?.group(1) ?? "";
  }

  HtComicBrief? _parseComicBrief(Element li) {
    try {
      final a = li.querySelector("div.pic_box > a") ?? li.querySelector("a");
      final href = a?.attributes["href"];
      if (href == null) return null;
      final id = _extractComicId(href);
      if (id == null) return null;

      final img = a?.querySelector("img") ?? li.querySelector("img");
      final src = img?.attributes["src"] ?? img?.attributes["data-src"];
      if (src == null || src.isEmpty) return null;
      final cover = _absUrl(src);

      final titleA = li.querySelector("div.info > div.title > a") ??
          li.querySelector("div.title > a") ??
          li.querySelector("a");
      var name = titleA?.attributes["title"] ?? titleA?.text ?? "";
      name = name.replaceAll("<em>", "").replaceAll("</em>", "");
      name = name.replaceAll("\n", "").trim();
      if (name.isEmpty) return null;

      final infoText = (li.querySelector("div.info > div.info_col")?.text ??
              li.querySelector(".info_col")?.text ??
              "")
          .replaceAll("\n", " ")
          .trim();
      final pages = _extractPages(infoText);
      final time = _extractTime(infoText);

      return HtComicBrief(name, time, cover, id, pages);
    } catch (_) {
      return null;
    }
  }

  List<HtComicBrief> _parseComicList(Iterable<Element> items) {
    final res = <HtComicBrief>[];
    for (final li in items) {
      final comic = _parseComicBrief(li);
      if (comic != null) res.add(comic);
    }
    return res;
  }

  Element? _findGalleryListForTitle(Element titleEl) {
    // Most pages put the comic list in the sibling block right after the title.
    final parent = titleEl.parent;
    if (parent != null) {
      final siblings = parent.children;
      final idx = siblings.indexOf(titleEl);
      if (idx != -1) {
        for (int i = idx + 1; i < siblings.length; i++) {
          final sib = siblings[i];
          if (sib.classes.contains("title_sort")) break;
          final ul = sib.querySelector("div.gallary_wrap > ul.cc") ??
              sib.querySelector("ul.cc");
          if (ul != null) return ul;
        }
      }
    }

    var n = titleEl.nextElementSibling;
    for (int i = 0; i < 8 && n != null; i++) {
      final ul = n.querySelector("div.gallary_wrap > ul.cc") ?? n.querySelector("ul.cc");
      if (ul != null) return ul;
      n = n.nextElementSibling;
    }
    return null;
  }

  void logout() {
    SingleInstanceCookieJar.instance?.deleteUri(Uri.parse(baseUrl));
  }

  ///基本的Get请求
  Future<Res<String>> get(String url,
      {bool cache = true, Map<String, String>? headers}) async {
    var dio = CachedNetwork();
    try {
      var res = await dio.get(
          url,
          BaseOptions(headers: {
            "User-Agent": webUA,
            if (headers != null) ...headers
          }),
          cookieJar: SingleInstanceCookieJar.instance,
          expiredTime: cache ? CacheExpiredTime.short : CacheExpiredTime.no);
      if(res.url.contains("users-login")){
        return Res(null, errorMessage: "未登录或登录到期".tl);
      }
      return Res(res.data);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const Res(null, errorMessage: "连接超时");
      } else {
        return Res(null, errorMessage: e.toString());
      }
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  ///基本的Post请求
  Future<Res<String>> post(String url, String data) async {
    var dio = logDio(BaseOptions(headers: {
      "User-Agent": webUA,
      "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
    }));
    dio.interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
    try {
      var res = await dio.post(url, data: data);
      return Res(res.data);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return const Res(null, errorMessage: "连接超时");
      } else {
        return Res(null, errorMessage: e.toString());
      }
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  ///登录
  Future<Res<bool>> login(String account, String pwd, [bool saveData = true]) async {
    var res = await post("$baseUrl/users-check_login.html",
        "login_name=${Uri.encodeComponent(account)}&login_pass=${Uri.encodeComponent(pwd)}");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var json = const JsonDecoder().convert(res.data);
      if (json["html"].contains("登錄成功")) {
        return const Res(true);
      }
      return Res(null, errorMessage: json["html"]);
    } catch (e) {
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<bool>> loginFromAppdata() async {
    var res = await htManga.reLogin();
    return res ? const Res(true) : const Res.error("error");
  }

  Future<Res<HtHomePageData>> getHomePage() async {
    final candidates = <String>[
      baseUrl,
      _absUrl("/albums.html"),
    ];
    if (candidates.length >= 2 && candidates[0] == candidates[1]) {
      candidates.removeLast();
    }

    String? lastError;
    for (final url in candidates) {
      final res = await get(url, cache: false);
      if (res.error) {
        lastError = res.errorMessage;
        continue;
      }

      try {
        final document = parse(res.data);
        final titleMap = <String, String>{};
        final comicsRes = <List<HtComicBrief>>[];

        final titles = document.querySelectorAll("div.title_sort");
        for (final titleEl in titles) {
          var text = titleEl.querySelector("div.title_h2")?.text ?? "";
          text = text.replaceAll("\n", "").removeAllBlank;
          if (text.isEmpty) continue;

          final href = titleEl.querySelector("div.r > a")?.attributes["href"] ??
              titleEl.querySelector("a")?.attributes["href"];
          final link = href == null ? _absUrl("/albums.html") : _absUrl(href);

          final ul = _findGalleryListForTitle(titleEl);
          final comics = ul == null ? const <HtComicBrief>[] : _parseComicList(ul.querySelectorAll("li"));
          if (comics.isEmpty) continue;

          final dedup = _dedupTitle(text, titleMap);
          titleMap[dedup] = link;
          comicsRes.add(comics);
        }

        if (comicsRes.isNotEmpty) {
          return Res(HtHomePageData(comicsRes, titleMap));
        }

        // Fallback: treat as a normal comic list page (some homepages no longer expose multi blocks).
        var listItems = document.querySelectorAll("div.gallary_wrap > ul.cc > li");
        listItems = listItems.isNotEmpty ? listItems : document.querySelectorAll("ul.cc > li");
        final comics = _parseComicList(listItems);
        if (comics.isNotEmpty) {
          titleMap["最新"] = _absUrl("/albums.html");
          return Res(HtHomePageData([comics], titleMap));
        }

        lastError = "空的内容不能解析哦".tl;
      } catch (e, s) {
        LogManager.addLog(LogLevel.error, "Data Analyze", "$e\n$s");
        lastError = "解析失败: $e";
      }
    }

    return Res(null, errorMessage: lastError ?? "解析失败".tl);
  }

  /// 获取给定漫画列表页面的漫画
  Future<Res<List<HtComicBrief>>> getComicList(String url, int page, {bool searchPage = false}) async {
    if (page != 1) {
      if (url.contains("search")) {
        url = "$url&p=$page";
      } else if (url.contains("ranking")) {
        url = url.replaceAll("ranking", "ranking-page-$page");
      } else {
        if (!url.contains("-")) {
          url = url.replaceAll(".html", "-.html");
        }
        url = url.replaceAll("index", "");
        var lr = url.split("albums-");
        lr[1] = "index-page-$page${lr[1]}";
        url = "${lr[0]}albums-${lr[1]}";
      }
    }
    var res = await get(url, cache: false);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var comics = <HtComicBrief>[];
      for (var comic in document
          .querySelectorAll("div.grid div.gallary_wrap > ul.cc > li")) {
        try {
          var link =
              comic.querySelector("div.pic_box > a")!.attributes["href"]!;
          var id = RegExp(r"(?<=-aid-)[0-9]+").firstMatch(link)![0]!;
          var image =
              comic.querySelector("div.pic_box > a > img")!.attributes["src"]!;
          image = "https:$image";
          var name = comic
              .querySelector("div.info > div.title > a")!
              .attributes["title"]
              ?.replaceAll("<em>", "")
              .replaceAll("</em>", "");
          name = name ??
              comic
                  .querySelector("div.info > div.title > a")!
                  .text
                  .replaceAll("<em>", "")
                  .replaceAll("</em>", "");
          var infoCol = comic.querySelector("div.info > div.info_col")!.text;
          var lr = infoCol.split("，");
          var time = lr[1].removeAllBlank;
          time = time.replaceAll("\n", "");
          var pagesStr = "";
          for (int i = 0; i < lr[0].length; i++) {
            if (lr[0][i].isNum) {
              pagesStr += lr[0][i];
            }
          }
          var pages = pagesStr == "" ? 0 : int.parse(pagesStr);
          comics.add(HtComicBrief(name, time, image, id, pages));
        } catch (e) {
          continue;
        }
      }
      int pages;
      try {
        if(searchPage){
          var result = int.parse(document.querySelectorAll("p.result > b")[0].text.nums);
          var comicsOnePage = document.querySelectorAll("div.grid div.gallary_wrap > ul.cc > li").length;
          pages = result ~/ comicsOnePage + 1;
        }else{
          var pagesLink = document.querySelectorAll("div.f_left.paginator > a");
          pages = int.parse(pagesLink.last.text);
        }
      } catch (e) {
        pages = 1;
      }
      return Res(comics, subData: pages);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<HtComicBrief>>> search(String keyword, int page) {
    if (keyword != "") {
      appdata.searchHistory.remove(keyword);
      appdata.searchHistory.add(keyword);
      appdata.writeHistory();
    }
    Future.delayed(const Duration(milliseconds: 300),
            () => StateController.find<PreSearchController>().update())
        .onError((error, stackTrace) => null);
    return getComicList(
        "$baseUrl/search/?q=${Uri.encodeComponent(keyword)}&f=_all&s=create_time_DESC&syn=yes",
        page, searchPage: true);
  }

  /// 获取漫画详情, subData为第一页的缩略图
  Future<Res<HtComicInfo>> getComicInfo(String id) async {
    var res =
        await get("$baseUrl/photos-index-page-1-aid-$id.html", cache: false);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var name = document.querySelector("div.userwrap > h2")!.text;
      var coverPath = document
          .querySelector(
              "div.userwrap > div.asTB > div.asTBcell.uwthumb > img")!
          .attributes["src"]!;
      coverPath = "https:$coverPath";
      coverPath = coverPath.replaceRange(6, 8, "");
      var labels = document.querySelectorAll("div.asTBcell.uwconn > label");
      var category = labels[0].text.split("：")[1];
      var pages = int.parse(
          RegExp(r"\d+").firstMatch(labels[1].text.split("：")[1])![0]!);
      var tagsDom = document.querySelectorAll("a.tagshow");
      var tags = <String, String>{};
      for (var tag in tagsDom) {
        var link = tag.attributes["href"]!;
        tags[tag.text] = link;
      }
      var description = document.querySelector("div.asTBcell.uwconn > p")!.text;
      var uploader =
          document.querySelector("div.asTBcell.uwuinfo > a > p")!.text;
      var avatar = document
          .querySelector("div.asTBcell.uwuinfo > a > img")!
          .attributes["src"]!;
      avatar = "$baseUrl/$avatar";
      var uploadNum = int.parse(
          document.querySelector("div.asTBcell.uwuinfo > p > font")!.text);
      var photosDom = document.querySelectorAll("div.pic_box.tb > a > img");
      var photos = List<String>.generate(photosDom.length,
          (index) => "https:${photosDom[index].attributes["src"]!}");
      return Res(
          HtComicInfo(id, coverPath, name, category, pages, tags, description,
              uploader, avatar, uploadNum, photos));
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<String>>> getThumbnails(String id, int page) async {
    var res = await get("$baseUrl/photos-index-page-$page-aid-$id.html");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var photosDom = document.querySelectorAll("div.pic_box.tb > a > img");
      var photos = List<String>.generate(photosDom.length,
          (index) => "https:${photosDom[index].attributes["src"]!}");
      return Res(photos);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<Res<List<String>>> getImages(String id) async {
    var res = await get("$baseUrl/photos-gallery-aid-$id.html");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var urls = RegExp(r"(?<=//)[\w./\[\]()-]+").allMatches(res.data);
      var images = <String>[];
      for (var url in urls) {
        images.add("https://${url[0]!}");
      }
      return Res(images);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  /// 获取收藏夹
  ///
  /// 返回Map, 值为收藏夹名，键为ID
  Future<Res<Map<String, String>>> getFolders() async {
    var res = await get(
        "$baseUrl/users-addfav-id-210814.html",
        cache: false);
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var data = <String, String>{};
      for (var option in document.querySelectorAll("option")) {
        if (option.attributes["value"] == "") continue;
        data[option.attributes["value"]!] = option.text;
      }
      return Res(data);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }

  Future<bool> createFolder(String name) async => !(await post(
          "$baseUrl/users-favc_save-id.html",
          "favc_name=${Uri.encodeComponent(name)}"))
      .error;

  Future<bool> deleteFolder(String id) async => !(await get(
          "$baseUrl/users-favclass_del-id-$id.html"
          "?ajax=true&_t=${Random.secure().nextDouble()}",
          cache: false))
      .error;

  Future<Res<bool>> addFavorite(String comicId, String folderId) async {
    var res = await post(
        "$baseUrl/users-save_fav-id-$comicId.html", "favc_id=$folderId");
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    return const Res(true);
  }

  Future<Res<bool>> delFavorite(String favoriteId) async {
    var res = await get(
      "$baseUrl/users-fav_del-id-$favoriteId.html?"
      "ajax=true&_t=${Random.secure().nextDouble()}",
      cache: false,
    );
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    return const Res(true);
  }

  ///获取收藏夹中的漫画
  Future<Res<List<HtComicBrief>>> getFavoriteFolderComics(
      String folderId, int page) async {
    var res = await get(
      "$baseUrl/users-users_fav-page-$page-c-$folderId.html",
      cache: false,
    );
    if (res.error) {
      return Res(null, errorMessage: res.errorMessage);
    }
    try {
      var document = parse(res.data);
      var comics = <HtComicBrief>[];
      for (var comic in document.querySelectorAll("div.asTB")) {
        var cover = comic
            .querySelector("div.asTBcell.thumb > div > img")!
            .attributes["src"]!;
        cover = "https:$cover";
        var time = comic
            .querySelector("div.box_cel.u_listcon > p.l_catg > span")!
            .text
            .replaceAll("創建時間：", "");
        var name =
            comic.querySelector("div.box_cel.u_listcon > p.l_title > a")!.text;
        var link = comic
            .querySelector("div.box_cel.u_listcon > p.l_title > a")!
            .attributes["href"]!;
        var id = RegExp(r"(?<=-aid-)[0-9]+").firstMatch(link)![0]!;
        var info =
            comic.querySelector("div.box_cel.u_listcon > p.l_detla")!.text;
        var pages = int.parse(RegExp(r"(?<=頁數：)[0-9]+").firstMatch(info)![0]!);
        var delUrl = comic
            .querySelector("div.box_cel.u_listcon > p.alopt > a")!
            .attributes["onclick"]!;
        var favoriteId = RegExp(r"(?<=del-id-)[0-9]+").firstMatch(delUrl)![0];
        comics.add(
            HtComicBrief(name, time, cover, id, pages, favoriteId: favoriteId));
      }
      int pages;
      try {
        var pagesLink = document.querySelectorAll("div.f_left.paginator > a");
        pages = int.parse(pagesLink.last.text);
      } catch (e) {
        pages = page;
      }
      return Res(comics, subData: pages);
    } catch (e, s) {
      LogManager.addLog(LogLevel.error, "Data Analyse", "$e\n$s");
      return Res(null, errorMessage: e.toString());
    }
  }
}
