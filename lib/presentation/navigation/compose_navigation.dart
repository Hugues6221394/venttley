import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../core/providers.dart';

/// Opens compose with the right prefill flags (poll, category, story, etc.).
void openCompose(
  BuildContext context,
  WidgetRef ref, {
  String? format,
  String? category,
  String? draft,
  bool story = false,
}) {
  ref.read(composeStoryModeProvider.notifier).state = story;
  ref.read(composeIncludePollProvider.notifier).state = format == 'poll';
  ref.read(composeInitialDraftProvider.notifier).state = draft;

  String? resolvedCategory = category;
  if (format == 'poll') {
    resolvedCategory = 'questions';
  }
  if (resolvedCategory != null &&
      !FeedCategories.all.contains(resolvedCategory)) {
    resolvedCategory = 'confessions';
  }
  ref.read(composeInitialCategoryProvider.notifier).state = resolvedCategory;

  if (story) {
    context.push('/compose/story');
    return;
  }
  context.push('/compose');
}

// NOTE: deep-link query params (/compose?format=poll&...) are applied
// locally inside ComposeScreen.initState -- mutating providers from there
// crashes Riverpod ("modify during build"), so no helper writes providers
// on route entry.
