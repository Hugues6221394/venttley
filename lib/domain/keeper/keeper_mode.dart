/// Server-authoritative keeper mode from `is_keeper_mode` RPC.
class KeeperMode {
  final bool isKeeper;
  final String displayRole; // member | keeper | plug | super_admin
  final String? userRole;
  final int tribesKept;

  const KeeperMode({
    required this.isKeeper,
    required this.displayRole,
    this.userRole,
    this.tribesKept = 0,
  });

  factory KeeperMode.guest() => const KeeperMode(
        isKeeper: false,
        displayRole: 'guest',
      );

  factory KeeperMode.fromJson(Map<String, dynamic> json) {
    final role = json['display_role'];
    final userRole = json['user_role'];
    return KeeperMode(
      isKeeper: json['is_keeper'] == true,
      displayRole: role is String ? role : 'member',
      userRole: userRole is String ? userRole : userRole?.toString(),
      tribesKept: json['tribes_kept'] is int
          ? json['tribes_kept'] as int
          : int.tryParse('${json['tribes_kept']}') ?? 0,
    );
  }

  String get label {
    switch (displayRole) {
      case 'super_admin':
        return 'Super Admin';
      case 'plug':
        return 'Verified Plug';
      case 'keeper':
        return 'Plug';
      default:
        return 'Member';
    }
  }
}
