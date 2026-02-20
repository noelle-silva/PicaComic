part of 'components.dart';

class SmoothCustomScrollView extends StatelessWidget {
  const SmoothCustomScrollView({super.key, required this.slivers, this.controller});

  final ScrollController? controller;

  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    return SmoothScrollProvider(
      controller: controller,
      builder: (context, controller, physics) {
        return CustomScrollView(
          controller: controller,
          physics: physics,
          slivers: slivers,
        );
      },
    );
  }
}


class SmoothScrollProvider extends StatefulWidget {
  const SmoothScrollProvider({super.key, this.controller, required this.builder});

  final ScrollController? controller;

  final Widget Function(BuildContext, ScrollController, ScrollPhysics) builder;

  static bool get isMouseScroll => _SmoothScrollProviderState._isMouseScroll;

  @override
  State<SmoothScrollProvider> createState() => _SmoothScrollProviderState();
}

class _SmoothScrollProviderState extends State<SmoothScrollProvider> {
  late final ScrollController _controller;

  double? _futurePosition;

  static bool _isMouseScroll = App.isDesktop;

  @override
  void initState() {
    _controller = widget.controller ?? ScrollController();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    if(App.isMacOS) {
      return widget.builder(
        context,
        _controller,
        const ClampingScrollPhysics(),
      );
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (_isMouseScroll) {
          setState(() {
            _isMouseScroll = false;
          });
        }
      },
      onPointerSignal: (pointerSignal) {
        if (pointerSignal is PointerScrollEvent) {
          if (pointerSignal.kind == PointerDeviceKind.mouse &&
              !_isMouseScroll) {
            setState(() {
              _isMouseScroll = true;
            });
          }
          if (!_isMouseScroll) return;
          if (!_controller.hasClients) return;
          final position = _controller.position;
          if (!position.hasContentDimensions) return;

          final before = position.pixels;
          _futurePosition ??= before;
          final k = (_futurePosition! - before).abs() / 1600 + 1;
          _futurePosition = (_futurePosition! + pointerSignal.scrollDelta.dy * k)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
          final target = _futurePosition!;

          Future.microtask(() {
            if (!mounted || !_controller.hasClients) return;
            final p = _controller.position;
            if (!p.hasContentDimensions) return;
            final after = p.pixels;
            if (after == before) return;
            _controller.jumpTo(before);
            _controller.animateTo(target,
                duration: _fastAnimationDuration, curve: Curves.linear);
          });
        }
      },
      child: widget.builder(
        context,
        _controller,
        const ClampingScrollPhysics(),
      ),
    );
  }
}
