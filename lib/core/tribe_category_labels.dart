import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/entities/entities.dart';
import 'providers.dart';

/// The controlled taxonomy, read from the database.
///
/// 20260830090000 moved the category list out of the Flutter binary so that
/// adding one does not need an app store release. This is its single home in
/// the client; screens should read labels through [tribeCategoryLabel] rather
/// than keeping their own map, which is the drift that migration existed to
/// end.
final tribeCategoriesProvider = FutureProvider.autoDispose<List<TribeCategory>>(
  (ref) async {
    return ref.watch(repositoryProvider).tribeCategories();
  },
);

/// The labels to fall back on before the taxonomy has loaded, or if the table
/// is not there yet. Keep in step with the seed in 20260830090000.
///
/// A fallback exists because a category key is written into every tribes row:
/// showing a raw key like `lgbtq` where a person expects "LGBTQ+" is a worse
/// failure than showing a slightly stale label.
const Map<String, String> kFallbackTribeCategoryLabels = <String, String>{
  'campus': 'Campus',
  'city': 'City',
  'interest_group': 'Interest',
  'hobby': 'Hobby',
  'support': 'Support',
  'venting': 'Venting',
  'wellness': 'Wellness',
  'creativity': 'Creativity',
  'faith': 'Faith',
  'lgbtq': 'LGBTQ+',
  'grief': 'Grief',
  'growth': 'Growth',
  'study': 'Study',
  'gaming': 'Gaming',
  'music': 'Music',
  'fitness': 'Fitness',
};

/// A human label for a category key.
///
/// Prefers the database, falls back to the built-in list, and last of all
/// prettifies the key itself so a category added server-side still reads as
/// words rather than a slug while an older build catches up.
String tribeCategoryLabel(WidgetRef ref, String? key) {
  final raw = (key ?? '').trim();
  if (raw.isEmpty) return 'Community';

  final live = ref.watch(tribeCategoriesProvider).valueOrNull;
  if (live != null) {
    for (final category in live) {
      if (category.key == raw) return category.label;
    }
  }

  final fallback = kFallbackTribeCategoryLabels[raw];
  if (fallback != null) return fallback;

  return raw
      .split('_')
      .where((word) => word.isNotEmpty)
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}
