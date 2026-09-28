/// A leaderboard row as the server sends it.
Map<String, Object?> rowJson(
  int position, {
  String id = 'u9',
  String name = 'Rahul',
  int value = 1523,
  int? change,
}) => {
  'position': position,
  'user': {
    'id': id,
    'handle': '${name.toLowerCase()}_$position',
    'display_name': name,
    'avatar': {'tone': 'sky', 'symbol': 'atom'},
    'level': 7,
  },
  'value': value,
  'value_display': '$value',
  'change_1d': change,
};
