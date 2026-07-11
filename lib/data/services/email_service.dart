import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants.dart';
import '../../core/logger.dart';

/// Transactional email — client-side enqueue only.
///
/// The Flutter app never holds the Resend API key. Instead it calls
/// the `queue_email` RPC which inserts a row into `email_outbox`;
/// the `email-dispatcher` Edge Function drains the outbox and sends
/// through Resend. That keeps the secret server-side AND gives us a
/// natural retry queue.
///
/// When [VentlyConfig.isResendEnabled] is false the queue still
/// accepts rows — the dispatcher is just paused. UI can surface "we'll
/// email you" copy or not based on the flag.
abstract class EmailService {
  static final EmailService instance =
      _SupabaseQueueEmailService(Supabase.instance.client);

  /// Queue a transactional email. [template] is one of the keys baked
  /// into the dispatcher (welcome / verify / security_alert / digest…).
  /// Variables become Handlebars-style replacements in the template.
  Future<void> queue({
    required String template,
    required String toUserId,
    Map<String, Object?> variables = const {},
  });
}

class _SupabaseQueueEmailService implements EmailService {
  _SupabaseQueueEmailService(this._client);
  final SupabaseClient _client;

  @override
  Future<void> queue({
    required String template,
    required String toUserId,
    Map<String, Object?> variables = const {},
  }) async {
    try {
      await _client.rpc('queue_email', params: {
        'p_template':   template,
        'p_to_user_id': toUserId,
        'p_variables':  variables,
      });
      log.info('email.queued',
          props: {'template': template, 'to_user_id': toUserId});
    } catch (e) {
      log.warn('email.queue_failed',
          props: {'template': template}, error: e);
    }
  }
}
