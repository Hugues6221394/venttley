import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../core/analytics_events.dart';
import '../../core/providers.dart';
import '../../data/services/analytics_service.dart';
import '../../domain/entities/entities.dart';

class MusicTrackCard extends ConsumerWidget {
  const MusicTrackCard({
    super.key,
    required this.track,
    this.startMs = 0,
    this.durationMs,
    this.volume = 0.75,
    this.onRemove,
    this.onChange,
    this.compact = false,
  });

  final MusicTrack track;
  final int startMs;
  final int? durationMs;
  final double volume;
  final VoidCallback? onRemove;
  final VoidCallback? onChange;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(musicPlaybackProvider);
    final isPlaying = player.isTrackPlaying(track.trackId);
    final isLoading = player.isTrackLoading(track.trackId);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '${track.title} by ${track.artist}',
      button: true,
      child: Container(
        padding: EdgeInsets.all(compact ? 9 : 12),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withOpacity(0.38),
          borderRadius: BorderRadius.circular(compact ? 14 : 18),
          border: Border.all(color: scheme.primary.withOpacity(0.15)),
        ),
        child: Row(
          children: [
            if (track.artworkUrl case final String artworkUrl) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: CachedNetworkImage(
                  imageUrl: artworkUrl,
                  width: compact ? 38 : 44,
                  height: compact ? 38 : 44,
                  fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 120),
                  errorWidget: (_, __, ___) => const Icon(Icons.music_note),
                ),
              ),
              const SizedBox(width: 6),
            ],
            IconButton.filledTonal(
              tooltip: isPlaying ? 'Pause music preview' : 'Play music preview',
              onPressed: isLoading
                  ? null
                  : () async {
                      await ref
                          .read(musicPlaybackProvider)
                          .playPause(
                            track,
                            startMs: startMs,
                            durationMs: durationMs,
                            volume: volume,
                          );
                      if (!isPlaying) {
                        unawaited(
                          AnalyticsService.instance.track(
                            Events.musicPreviewPlayed,
                            props: {'provider': track.provider},
                          ),
                        );
                      }
                    },
              icon: isLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withOpacity(0.62),
                    ),
                  ),
                ],
              ),
            ),
            if (onChange != null)
              TextButton(onPressed: onChange, child: const Text('Change')),
            if (onRemove != null)
              IconButton(
                tooltip: 'Remove music',
                onPressed: onRemove,
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

Future<MusicTrack?> showMusicPicker(
  BuildContext context, {
  MusicTrack? selected,
}) {
  unawaited(AnalyticsService.instance.track(Events.musicPickerOpened));
  return showModalBottomSheet<MusicTrack>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _MusicPickerSheet(selected: selected),
  );
}

class _MusicPickerSheet extends ConsumerStatefulWidget {
  const _MusicPickerSheet({this.selected});
  final MusicTrack? selected;

  @override
  ConsumerState<_MusicPickerSheet> createState() => _MusicPickerSheetState();
}

class _MusicPickerSheetState extends ConsumerState<_MusicPickerSheet> {
  static const _moods = <String, String>{
    'healing': 'Healing',
    'heartbreak': 'Heartbreak',
    'happy': 'Happy',
    'motivation': 'Motivation',
    'late_night': 'Late Night',
    'peaceful': 'Peaceful',
    'romantic': 'Romantic',
    'celebration': 'Celebration',
    'nostalgic': 'Nostalgic',
    'campus': 'Campus',
    'confidence': 'Confidence',
  };

  final _search = TextEditingController();
  Timer? _debounce;
  String? _mood;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _changed(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final request = (query: _query, mood: _mood);
    final catalog = ref.watch(musicCatalogProvider(request));
    final isBrowsing = _query.isEmpty && _mood == null;
    return FractionallySizedBox(
      heightFactor: 0.88,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add music',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22),
            ),
            const SizedBox(height: 4),
            Text(
              'Short previews from Venttly-authorized catalogs only.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              onChanged: _changed,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search song, artist, genre or mood',
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final entry in _moods.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 7),
                      child: ChoiceChip(
                        label: Text(entry.value),
                        selected: _mood == entry.key,
                        onSelected: (selected) =>
                            setState(() => _mood = selected ? entry.key : null),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: isBrowsing
                  ? const _MusicDiscoverySections()
                  : catalog.when(
                      loading: () => const Center(
                        child: CircularProgressIndicator.adaptive(),
                      ),
                      error: (_, __) => Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text("Music isn't available right now."),
                            const SizedBox(height: 8),
                            OutlinedButton(
                              onPressed: () =>
                                  ref.invalidate(musicCatalogProvider(request)),
                              child: const Text('Try again'),
                            ),
                          ],
                        ),
                      ),
                      data: (tracks) => tracks.isEmpty
                          ? const Center(
                              child: Text('No authorized tracks matched.'),
                            )
                          : ListView.separated(
                              itemCount: tracks.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final track = tracks[index];
                                return InkWell(
                                  borderRadius: BorderRadius.circular(18),
                                  onTap: () => Navigator.of(context).pop(track),
                                  child: MusicTrackCard(
                                    track: track,
                                    compact: true,
                                  ),
                                );
                              },
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MusicDiscoverySections extends ConsumerWidget {
  const _MusicDiscoverySections();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const sections = <(String, String)>[
      ('recent', 'Recently used'),
      ('for_you', 'For you'),
      ('trending', 'Trending'),
    ];
    return ListView(
      children: [
        for (final section in sections)
          _MusicSection(
            title: section.$2,
            value: ref.watch(musicCatalogSectionProvider(section.$1)),
          ),
      ],
    );
  }
}

class _MusicSection extends StatelessWidget {
  const _MusicSection({required this.title, required this.value});

  final String title;
  final AsyncValue<List<MusicTrack>> value;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (_, __) => const SizedBox.shrink(),
      data: (tracks) {
        if (tracks.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              for (final track in tracks) ...[
                InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => Navigator.of(context).pop(track),
                  child: MusicTrackCard(track: track, compact: true),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        );
      },
    );
  }
}
