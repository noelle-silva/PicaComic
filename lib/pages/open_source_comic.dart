import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/network/custom_download_model.dart';
import 'package:pica_comic/network/download_model.dart';
import 'package:pica_comic/network/eh_network/eh_download_model.dart';
import 'package:pica_comic/network/hitomi_network/hitomi_download_model.dart';
import 'package:pica_comic/network/htmanga_network/ht_download_model.dart';
import 'package:pica_comic/network/jm_network/jm_download.dart';
import 'package:pica_comic/network/nhentai_network/download.dart';
import 'package:pica_comic/network/picacg_network/picacg_download_model.dart';
import 'package:pica_comic/pages/comic_page.dart';
import 'package:pica_comic/pages/ehentai/eh_gallery_page.dart';
import 'package:pica_comic/pages/hitomi/hitomi_comic_page.dart';
import 'package:pica_comic/pages/htmanga/ht_comic_page.dart';
import 'package:pica_comic/pages/jm/jm_comic_page.dart';
import 'package:pica_comic/pages/nhentai/comic_page.dart';
import 'package:pica_comic/pages/picacg/comic_page.dart';

/// 打开已下载/已入库漫画对应的源站详情页（本地下载与服务器漫画共用）。
void openSourceComic(DownloadedItem comic) {
  var context = App.mainNavigatorKey!.currentContext!;
  if (comic is DownloadedComic) {
    context.to(() => PicacgComicPage(comic.comicItem.id, null));
  } else if (comic is DownloadedGallery) {
    context.to(() => EhGalleryPage(comic.gallery.toBrief()));
  } else if (comic is DownloadedJmComic) {
    context.to(() => JmComicPage(comic.comic.id));
  } else if (comic is DownloadedHitomiComic) {
    context.to(() => HitomiComicPage(comic.toBrief()));
  } else if (comic is DownloadedHtComic) {
    context.to(() => HtComicPage(comic.id.replaceFirst('Ht', '')));
  } else if (comic is NhentaiDownloadedComic) {
    context.to(() => NhentaiComicPage(comic.id.replaceFirst("nhentai", "")));
  } else if (comic is CustomDownloadedItem) {
    context.to(() => ComicPage(sourceKey: comic.sourceKey, id: comic.comicId));
  }
}
