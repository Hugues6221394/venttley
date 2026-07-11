/// KPI types on a public profile — each maps to a premium detail screen.
enum ProfileStatKind {
  connections,
  vents,
  comments,
  reactions,
  tribes,
  badges,
  streak;

  String get routeSegment => name;

  static ProfileStatKind? fromRoute(String? raw) {
    if (raw == null) return null;
    for (final k in ProfileStatKind.values) {
      if (k.name == raw) return k;
    }
    return null;
  }

  String get title => switch (this) {
        ProfileStatKind.connections => 'Connections',
        ProfileStatKind.vents => 'Vents',
        ProfileStatKind.comments => 'Comments',
        ProfileStatKind.reactions => 'Reactions received',
        ProfileStatKind.tribes => 'Tribes',
        ProfileStatKind.badges => 'Badges',
        ProfileStatKind.streak => 'Streak',
      };

  String get subtitle => switch (this) {
        ProfileStatKind.connections =>
          'Accepted friendships on Venttly',
        ProfileStatKind.vents => 'Anonymous posts shared',
        ProfileStatKind.comments => 'Replies that helped others',
        ProfileStatKind.reactions => 'Hugs and support received',
        ProfileStatKind.tribes => 'Communities joined',
        ProfileStatKind.badges => 'Milestones earned',
        ProfileStatKind.streak => 'Daily check-in consistency',
      };

  String get iconName => switch (this) {
        ProfileStatKind.connections => 'people',
        ProfileStatKind.vents => 'edit_note',
        ProfileStatKind.comments => 'chat_bubble',
        ProfileStatKind.reactions => 'favorite',
        ProfileStatKind.tribes => 'diversity_3',
        ProfileStatKind.badges => 'military_tech',
        ProfileStatKind.streak => 'local_fire_department',
      };
}
