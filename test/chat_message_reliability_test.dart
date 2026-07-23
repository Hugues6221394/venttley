import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vently_app/data/services/mock_backend.dart';
import 'package:vently_app/domain/entities/entities.dart';

void main() {
  test('message enrichment preserves delivery receipts', () {
    final deliveredAt = DateTime.utc(2026, 7, 19, 12);
    final message = ChatMessage(
      messageId: 'message',
      roomId: 'room',
      senderId: 'sender',
      plaintext: 'hello',
      createdAt: deliveredAt.subtract(const Duration(seconds: 2)),
      deliveredAt: deliveredAt,
      sentByMe: true,
    );

    expect(message.copyWith(reactionCounts: const {'hug': 1}).deliveredAt,
        deliveredAt);
  });

  test('development backend supports author edit and both delete modes', () {
    final backend = MockBackend.instance;
    final room = backend.inbox(tab: 'active').first;

    final editable = backend.sendMessage(
      roomId: room.roomId,
      plaintext: 'before edit',
    );
    expect(
      backend.editChatMessage(
        messageId: editable.messageId,
        newPlaintext: 'after edit',
      ),
      isTrue,
    );
    expect(
      backend
          .roomMessages(room.roomId)
          .singleWhere((item) => item.messageId == editable.messageId)
          .plaintext,
      'after edit',
    );

    expect(backend.deleteChatMessage(editable.messageId), isTrue);
    final tombstone = backend
        .roomMessages(room.roomId)
        .singleWhere((item) => item.messageId == editable.messageId);
    expect(tombstone.isDeleted, isTrue);
    expect(tombstone.plaintext, isEmpty);

    final hidden = backend.sendMessage(
      roomId: room.roomId,
      plaintext: 'delete only for me',
    );
    expect(backend.hideChatMessage(hidden.messageId), isTrue);
    expect(
      backend.roomMessages(room.roomId).map((item) => item.messageId),
      isNot(contains(hidden.messageId)),
    );
  });

  test('DM edits are re-moderated and all live bubbles expose actions', () {
    final source = File(
      'lib/presentation/screens/inbox/chat_screen.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('an initially-safe message cannot be replaced with abuse'),
    );
    expect(
        source, contains('onLongPress: () => _openActionSheet(context, ref)'));
    expect(source, contains("message.attachedMediaType == 'image'"));
    expect(source, contains('snapshot != null'));
  });

  test('inbox and chat surfaces preserve peer profile photos', () {
    final migration = File(
      'supabase/migrations/20260721195342_inbox_peer_profile_photos.sql',
    ).readAsStringSync();
    final backend = File(
      'lib/data/services/supabase_backend.dart',
    ).readAsStringSync();
    final inbox = File(
      'lib/presentation/screens/inbox/inbox_screen.dart',
    ).readAsStringSync();
    final chat = File(
      'lib/presentation/screens/inbox/chat_screen.dart',
    ).readAsStringSync();
    final options = File(
      'lib/presentation/widgets/chat_options_sheet.dart',
    ).readAsStringSync();

    expect(migration, contains('WITH (security_invoker = true)'));
    expect(migration, contains('AS peer_profile_photo_url'));
    expect(migration, contains('REVOKE ALL ON public.inbox_rooms'));
    expect(
      backend,
      contains("peerProfilePhotoUrl: row['peer_profile_photo_url']"),
    );
    expect(inbox, contains('room.peerProfilePhotoUrl'));
    expect(chat, contains('r.peerProfilePhotoUrl'));
    expect(options, contains('room.peerProfilePhotoUrl'));
  });
}
