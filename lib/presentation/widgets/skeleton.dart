import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../theme/colors.dart';

/// Shimmer-backed skeleton placeholders for the main lists.
///
/// We render the same outer card geometry as the real list items so layout
/// doesn't jump when data lands — only the inner content swaps from
/// shimmering rectangles to real text/avatars.
class _Surface extends StatelessWidget {
  const _Surface({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Shimmer.fromColors(
      baseColor: isDark
          ? Theme.of(context).colorScheme.surface.withOpacity(0.7)
          : VentlyColors.softMauve.withOpacity(0.3),
      highlightColor: isDark
          ? Theme.of(context).scaffoldBackgroundColor.withOpacity(0.4)
          : Colors.white.withOpacity(0.9),
      child: child,
    );
  }
}

Widget _bar(double h, double w) => Container(
  height: h,
  width: w,
  decoration: BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(8),
  ),
);

class PostSkeletonList extends StatelessWidget {
  const PostSkeletonList({super.key, this.count = 4});
  final int count;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: count,
      itemBuilder: (_, __) => _Surface(
        child: Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _bar(10, 120),
                        const SizedBox(height: 6),
                        _bar(8, 60),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _bar(10, double.infinity),
                const SizedBox(height: 6),
                _bar(10, double.infinity),
                const SizedBox(height: 6),
                _bar(10, 200),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TribeSkeletonList extends StatelessWidget {
  const TribeSkeletonList({super.key, this.count = 5});
  final int count;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: count,
      itemBuilder: (_, __) => _Surface(
        child: Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _bar(12, 160),
                      const SizedBox(height: 8),
                      _bar(10, 100),
                      const SizedBox(height: 10),
                      _bar(8, double.infinity),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _bar(28, 64),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal whisper cards on Home.
class WhisperRailSkeleton extends StatelessWidget {
  const WhisperRailSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 176,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: 4,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, __) => _Surface(
          child: Container(
            width: 132,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen whisper feed first paint.
class WhisperFeedSkeleton extends StatelessWidget {
  const WhisperFeedSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: _Surface(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 100, 20, 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              Container(
                height: 72,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              const SizedBox(height: 16),
              _bar(14, 180),
              const SizedBox(height: 8),
              _bar(10, 240),
            ],
          ),
        ),
      ),
    );
  }
}

class QuestionsSkeletonList extends StatelessWidget {
  const QuestionsSkeletonList({super.key, this.count = 3});
  final int count;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: count,
      itemBuilder: (_, __) => _Surface(
        child: Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _bar(10, 100),
                        const SizedBox(height: 6),
                        _bar(8, 60),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _bar(14, double.infinity),
                const SizedBox(height: 6),
                _bar(14, 220),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Alternating chat-bubble placeholders for DM / tribe chat while the
/// thread loads — shimmer instead of a spinner, per the premium motion spec.
class ChatSkeleton extends StatelessWidget {
  const ChatSkeleton({super.key, this.count = 7});
  final int count;

  @override
  Widget build(BuildContext context) {
    Widget bubble(int i) {
      final mine = i.isOdd;
      final width = 140.0 + (i * 37) % 120;
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: width,
          height: 44,
          margin: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(mine ? 18 : 6),
              bottomRight: Radius.circular(mine ? 6 : 18),
            ),
          ),
        ),
      );
    }

    return _Surface(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
        children: [for (var i = 0; i < count; i++) bubble(i)],
      ),
    );
  }
}

/// First paint for a Keeper Studio page.
///
/// Two score tiles over a stack of rows, which is the shape every Studio push
/// screen settles into — Insights, Moderation, the Calendar and Co-mods all
/// open with a pair of summary cards and then a list. Matching that geometry
/// means the page does not jump when the data lands.
///
/// Replaces a centred `CircularProgressIndicator`, which on these screens sat
/// in the middle of an otherwise empty page and gave no sense of what was
/// coming. Shimmer reads as "this is nearly here"; a spinner reads as "wait".
class StudioSkeleton extends StatelessWidget {
  const StudioSkeleton({super.key, this.rows = 3, this.showTiles = true});

  /// How many list rows to imply.
  final int rows;

  /// The summary pair at the top. Off for a page that opens straight into a
  /// list.
  final bool showTiles;

  @override
  Widget build(BuildContext context) {
    return _Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showTiles) ...[
            Row(
              children: [
                Expanded(child: _block(96)),
                const SizedBox(width: 10),
                Expanded(child: _block(96)),
              ],
            ),
            const SizedBox(height: 14),
          ],
          for (var i = 0; i < rows; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _block(74),
            ),
        ],
      ),
    );
  }

  static Widget _block(double height) => Container(
    height: height,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
    ),
  );
}

/// First paint for the Studio member roster: a KPI strip over member rows.
class StudioMembersSkeleton extends StatelessWidget {
  const StudioMembersSkeleton({super.key, this.rows = 6});
  final int rows;

  @override
  Widget build(BuildContext context) {
    return _Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StudioSkeletonBlock(height: 86),
          const SizedBox(height: 12),
          _StudioSkeletonBlock(height: 44),
          const SizedBox(height: 14),
          for (var i = 0; i < rows; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _bar(11, 150),
                        const SizedBox(height: 7),
                        _bar(9, 90),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _bar(24, 58),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StudioSkeletonBlock extends StatelessWidget {
  const _StudioSkeletonBlock({required this.height});
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
    ),
  );
}
