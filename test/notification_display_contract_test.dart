import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/domain/entities/entities.dart';

void main() {
  NotificationItem notification({
    required String kind,
    String body = '',
    Map<String, dynamic> payload = const {},
  }) {
    return NotificationItem(
      id: 'notification-id',
      kind: kind,
      title: 'Notification',
      body: body,
      createdAt: DateTime.utc(2026, 7, 21),
      isRead: false,
      payload: payload,
    );
  }

  test('uses current notification body without changing its copy', () {
    final item = notification(
      kind: 'post_like',
      body: 'liked your vent “A quiet morning.”',
    );

    expect(item.displayBody, 'liked your vent “A quiet morning.”');
  });

  test('supports legacy message payloads from production history', () {
    final item = notification(
      kind: 'new_follower',
      payload: const {'message': 'GoldenHour sent you a friend request'},
    );

    expect(item.displayBody, 'GoldenHour sent you a friend request');
  });

  test('known sparse notifications always have useful fallback copy', () {
    expect(
      notification(kind: 'tribe_prompt').displayBody,
      'A new conversation is ready in your tribe.',
    );
    expect(
      notification(kind: 'comment_reply').displayBody,
      'replied to your vent.',
    );
  });
}
