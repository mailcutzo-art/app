/// Short, friendly times for lists (inbox, wallet, history), in the phone's local time.
library;

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "12 Sep", or "12 Sep 2025" outside [now]'s year.
String shortDate(DateTime at, {DateTime? now}) {
  final local = at.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final day = '${local.day} ${_months[local.month - 1]}';
  return local.year == today.year ? day : '$day ${local.year}';
}

/// "12 Sep 2026", always with the year (end dates, deadlines).
String fullDate(DateTime at) {
  final local = at.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}

/// "16:05".
String clockTime(DateTime at) {
  final local = at.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}';
}

/// "Just now", "5 min ago", "3 h ago", "Yesterday", then [shortDate].
String relativeTime(DateTime at, {DateTime? now}) {
  final current = (now ?? DateTime.now()).toLocal();
  final local = at.toLocal();
  final age = current.difference(local);
  if (age.inMinutes < 1) return 'Just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  final startOfToday = DateTime(current.year, current.month, current.day);
  if (!local.isBefore(startOfToday)) return '${age.inHours} h ago';
  final startOfYesterday = DateTime(current.year, current.month, current.day - 1);
  if (!local.isBefore(startOfYesterday)) return 'Yesterday';
  return shortDate(local, now: current);
}

String _two(int value) => value.toString().padLeft(2, '0');
