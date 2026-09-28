/// Tournament payloads for Arena tests (`docs/api-play.md` "Tournaments").
library;

/// A tournament card as the API sends it.
Map<String, Object?> card({
  String status = 'reg_open',
  Object? me,
  int players = 5,
  int capacity = 64,
  int fee = 25,
  String goal = 'neet',
  String startsAt = '2026-10-04T12:30:00Z',
}) => {
  'id': 't1',
  'title': 'Physics Sunday Cup',
  'goal': goal,
  'subject': 'physics',
  'tone': 'sky',
  'status': status,
  'reg_opens_at': '2026-10-01T12:30:00Z',
  'checkin_opens_at': '2026-10-04T12:15:00Z',
  'starts_at': startsAt,
  'ends_at_estimate': '2026-10-04T13:15:00Z',
  'rounds': 5,
  'entry_fee': fee,
  'prize_pool': 2500,
  'effective_pool': 390,
  'players': players,
  'min_players': 8,
  'capacity': capacity,
  'me': me,
};

/// A user card.
Map<String, Object?> user(String id) => {
  'id': id,
  'handle': '${id}_07',
  'display_name': 'Player $id',
  'avatar': {'tone': 'sky', 'symbol': 'atom'},
  'level': 7,
};
