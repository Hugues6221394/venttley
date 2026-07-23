import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('post thread keeps lazy rendering and bounded composer input', () {
    final source = File(
      'lib/presentation/screens/feed/post_detail_screen.dart',
    ).readAsStringSync();

    expect(source, contains('SliverChildBuilderDelegate'));
    expect(source, contains('cacheExtent: 720'));
    expect(source, contains('ScrollViewKeyboardDismissBehavior.onDrag'));
    expect(source, contains('focusNode: _replyFocus'));
    expect(source, contains('LengthLimitingTextInputFormatter(600)'));
    expect(source, contains("ValueKey('comment-\${comment.commentId}')"));
    expect(source, contains('class _CommentsError'));
  });
}
