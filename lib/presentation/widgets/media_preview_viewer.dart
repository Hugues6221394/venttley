import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

@immutable
class MediaPreviewItem {
  const MediaPreviewItem({required this.url, required this.label});

  final String url;
  final String label;
}

/// Opens a full-screen, swipeable and pinch-to-zoom media preview.
Future<void> showMediaPreview(
  BuildContext context, {
  required List<MediaPreviewItem> items,
  int initialIndex = 0,
  String? title,
}) async {
  final uniqueItems = <MediaPreviewItem>[];
  final seenUrls = <String>{};
  for (final item in items) {
    final url = item.url.trim();
    if (url.isEmpty || !seenUrls.add(url)) continue;
    uniqueItems.add(MediaPreviewItem(url: url, label: item.label));
  }
  if (uniqueItems.isEmpty || !context.mounted) return;

  final requestedUrl = items.isEmpty
      ? null
      : items[initialIndex.clamp(0, items.length - 1)].url.trim();
  final resolvedIndex = requestedUrl == null
      ? 0
      : uniqueItems.indexWhere((item) => item.url == requestedUrl);

  await Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (_, __, ___) => _MediaPreviewScreen(
        items: uniqueItems,
        initialIndex: resolvedIndex < 0 ? 0 : resolvedIndex,
        title: title,
      ),
      transitionsBuilder: (_, animation, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    ),
  );
}

class _MediaPreviewScreen extends StatefulWidget {
  const _MediaPreviewScreen({
    required this.items,
    required this.initialIndex,
    required this.title,
  });

  final List<MediaPreviewItem> items;
  final int initialIndex;
  final String? title;

  @override
  State<_MediaPreviewScreen> createState() => _MediaPreviewScreenState();
}

class _MediaPreviewScreenState extends State<_MediaPreviewScreen> {
  late final PageController _pageController;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToPage(int index) {
    if (index < 0 || index >= widget.items.length) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: PageView.builder(
                controller: _pageController,
                itemCount: widget.items.length,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (value) => setState(() => _index = value),
                itemBuilder: (context, index) {
                  final media = widget.items[index];
                  return Semantics(
                    image: true,
                    label: media.label,
                    child: _ZoomablePreviewImage(media: media),
                  );
                },
              ),
            ),
            if (_index > 0)
              Positioned(
                left: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _PreviewIconButton(
                    tooltip: 'Previous image',
                    icon: Icons.chevron_left_rounded,
                    onPressed: () => _goToPage(_index - 1),
                  ),
                ),
              ),
            if (_index < widget.items.length - 1)
              Positioned(
                right: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _PreviewIconButton(
                    tooltip: 'Next image',
                    icon: Icons.chevron_right_rounded,
                    onPressed: () => _goToPage(_index + 1),
                  ),
                ),
              ),
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  _PreviewIconButton(
                    tooltip: 'Close preview',
                    icon: Icons.close_rounded,
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ((widget.title ?? '').trim().isNotEmpty)
                          Text(
                            widget.title!.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.72),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.items.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.48),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${_index + 1} of ${widget.items.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.items.length > 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 18,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var index = 0; index < widget.items.length; index++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: index == _index ? 18 : 6,
                        height: 6,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: index == _index
                              ? Colors.white
                              : Colors.white.withOpacity(0.42),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ZoomablePreviewImage extends StatefulWidget {
  const _ZoomablePreviewImage({required this.media});

  final MediaPreviewItem media;

  @override
  State<_ZoomablePreviewImage> createState() => _ZoomablePreviewImageState();
}

class _ZoomablePreviewImageState extends State<_ZoomablePreviewImage> {
  late final TransformationController _transformationController;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transformationController = TransformationController()
      ..addListener(_handleTransformChanged);
  }

  @override
  void dispose() {
    _transformationController
      ..removeListener(_handleTransformChanged)
      ..dispose();
    super.dispose();
  }

  void _handleTransformChanged() {
    final zoomed = _transformationController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _transformationController,
      panEnabled: _zoomed,
      minScale: 1,
      maxScale: 5,
      boundaryMargin: const EdgeInsets.all(24),
      child: Center(
        child: CachedNetworkImage(
          imageUrl: widget.media.url,
          width: double.infinity,
          fit: BoxFit.contain,
          fadeInDuration: const Duration(milliseconds: 120),
          placeholder: (_, __) => const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: Colors.white,
              ),
            ),
          ),
          errorWidget: (_, __, ___) => const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white70,
                  size: 42,
                ),
                SizedBox(height: 10),
                Text(
                  'Image unavailable',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewIconButton extends StatelessWidget {
  const _PreviewIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withOpacity(0.48),
        shape: const CircleBorder(),
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon, color: Colors.white),
        ),
      ),
    );
  }
}
