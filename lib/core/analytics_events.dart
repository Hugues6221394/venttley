/// Typed event taxonomy for [AnalyticsService] / PostHog.
///
/// Every event name shipped from the client lives here. Call sites
/// reference the constant, never the literal string — that gives us
/// rename-safety and a single place to audit when the product team
/// asks "what are we tracking?".
///
/// Naming convention: `noun.verb` snake_case. Verbs are past-tense
/// for completed actions ("post_created"), present-tense for state
/// transitions ("typing_started"). Property keys are also snake_case.
///
/// New events MUST be added here BEFORE the call site or analytics
/// review will flag them.
library;

class Events {
  Events._();

  // Lifecycle
  static const String appOpened = 'app.opened';
  static const String appBackgrounded = 'app.backgrounded';

  // Onboarding + auth
  static const String onboardingStarted = 'onboarding.started';
  static const String onboardingCompleted = 'onboarding.completed';
  static const String signupAnonymous = 'auth.signup_anonymous';
  static const String signupEmail = 'auth.signup_email';
  static const String signinAnonymous = 'auth.signin_anonymous';
  static const String signinEmail = 'auth.signin_email';
  static const String recoveryUsed = 'auth.recovery_used';
  static const String logout = 'auth.logout';

  // Profile identity (never include display name, username, or profile text)
  static const String displayNameUpdated = 'profile.display_name_updated';

  // Posts / vents
  static const String postCreated = 'post.created';
  static const String postShared = 'post.shared';
  static const String postSaved = 'post.saved';
  static const String postUnsaved = 'post.unsaved';
  static const String postReported = 'post.reported';
  static const String postReacted = 'post.reacted';
  static const String commentCreated = 'comment.created';
  static const String selfInteractionRejected =
      'engagement.self_interaction_rejected';

  // Music (never include Vent/story contents or identity fields in props)
  static const String musicPickerOpened = 'music.picker_opened';
  static const String musicPreviewPlayed = 'music.preview_played';
  static const String musicAttached = 'music.attached';
  static const String musicRemoved = 'music.removed';

  // Whispers
  static const String whisperPublished = 'whisper.published';
  static const String whisperPlayed = 'whisper.played';
  static const String whisperLiked = 'whisper.liked';

  // Stories
  static const String storyPublished = 'story.published';
  static const String storyViewed = 'story.viewed';
  static const String storyReacted = 'story.reacted';

  // Friends
  static const String friendRequestSent = 'friend.request_sent';
  static const String friendRequestAccepted = 'friend.request_accepted';
  static const String friendRequestDeclined = 'friend.request_declined';
  static const String friendBlocked = 'friend.blocked';
  static const String friendUnfriended = 'friend.unfriended';

  // Chat (DMs)
  static const String chatMessageSent = 'chat.message_sent';
  static const String chatMessageReplied = 'chat.message_replied';
  static const String chatMessageEdited = 'chat.message_edited';
  static const String chatMessageDeleted = 'chat.message_deleted';
  static const String chatRoomAccepted = 'chat.room_accepted';

  // Tribes
  static const String tribeJoined = 'tribe.joined';
  static const String tribeLeft = 'tribe.left';
  static const String tribeCreated = 'tribe.created';
  static const String tribeChatMessage = 'tribe.chat_message';

  // Discovery + search
  static const String searchPerformed = 'discover.search_performed';
  static const String voiceFollowed = 'discover.voice_followed';
  static const String categoryFiltered = 'discover.category_filtered';

  // Notifications
  static const String notificationTapped = 'notification.tapped';

  // Premium / payments (queued for when Stripe lands)
  static const String checkoutOpened = 'billing.checkout_opened';
  static const String subscriptionStarted = 'billing.subscription_started';
  static const String subscriptionCanceled = 'billing.subscription_canceled';

  // Screens — used by AnalyticsService.screen() so PostHog can build
  // funnels off page views without manual tagging.
  static const String screenFeed = 'feed';
  static const String screenDiscover = 'discover';
  static const String screenWhispers = 'whispers';
  static const String screenInbox = 'inbox';
  static const String screenFriends = 'friends';
  static const String screenProfile = 'profile';
  static const String screenCompose = 'compose';
  static const String screenTribe = 'tribe_detail';
  static const String screenChat = 'chat';
  static const String screenStory = 'story_viewer';
}
