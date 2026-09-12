import 'package:flutter/widgets.dart';

/// 跨路由实例的滚动位置共享存储。
///
/// 框架的位置存储随路由销毁而清空；需要在"页面关闭后再次打开"时恢复原位的
/// 滚动视图，在子树中提供本桶作为其位置存储，即可跨路由实例恢复。
final PageStorageBucket sharedScrollStorage = PageStorageBucket();
