import 'dart:async';

import 'package:add_2_calendar/add_2_calendar.dart' as cal;
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

/// One notification scheduled on the phone, which fires even with the app closed and without
/// push. Tapping it opens [route].
@immutable
class LocalReminder {
  const LocalReminder({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
    required this.route,
  });

  /// Stable across app runs, so a later cancel finds it.
  final int id;
  final DateTime at;
  final String title;
  final String body;
  final String route;

  @override
  String toString() => 'LocalReminder($id at $at: $title)';
}

/// Whether the phone will show reminders.
enum ReminderPermission { granted, denied, unsupported }

/// Schedules local notifications. The app uses [DeviceReminderScheduler]; tests and platforms
/// without the plugin use [MemoryReminderScheduler].
abstract interface class ReminderScheduler {
  /// Asks for permission to notify (Android 13+ and iOS ask once; later calls answer at once).
  Future<ReminderPermission> ensurePermission();

  Future<void> schedule(LocalReminder reminder);

  Future<void> cancel(int id);

  /// Routes of reminders tapped while the app runs.
  Stream<String> get taps;

  /// The route of the reminder that launched the app, if one did.
  Future<String?> launchRoute();
}

/// `flutter_local_notifications` behind [ReminderScheduler].
///
/// - Scheduling is inexact but allowed while idle (`inexactAllowWhileIdle`), so no exact-alarm
///   permission is needed: Android may deliver a few minutes late, which suits "starts in 1
///   hour" and "check in now" (check-in stays open for 13 minutes).
/// - Times are absolute instants, so they are scheduled in UTC and the phone's time zone never
///   matters.
/// - A plugin that isn't there (tests, desktop) behaves like denied permission rather than
///   crashing a registration.
class DeviceReminderScheduler implements ReminderScheduler {
  DeviceReminderScheduler({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<String> _taps = StreamController.broadcast();
  Future<bool>? _ready;

  static const channelId = 'tournament_reminders';
  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      'Tournament reminders',
      channelDescription: 'Reminders you set by registering for a tournament',
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    ),
    iOS: DarwinNotificationDetails(),
  );

  Future<bool> _init() => _ready ??= () async {
    try {
      final ok = await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // Permission is asked at registration, where the reason is obvious.
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: (response) {
          final route = response.payload;
          if (route != null && route.startsWith('/')) _taps.add(route);
        },
      );
      return ok ?? false;
    } on Object catch (error) {
      debugPrint('Local notifications unavailable: $error');
      return false;
    }
  }();

  @override
  Future<ReminderPermission> ensurePermission() async {
    if (!await _init()) return ReminderPermission.unsupported;
    try {
      final bool? granted;
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          granted = await _plugin
              .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
              ?.requestNotificationsPermission();
        case TargetPlatform.iOS:
          granted = await _plugin
              .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(alert: true, sound: true);
        default:
          return ReminderPermission.unsupported;
      }
      // Android below 13 has no runtime permission and answers null.
      return granted ?? true ? ReminderPermission.granted : ReminderPermission.denied;
    } on Object catch (error) {
      debugPrint('Notification permission failed: $error');
      return ReminderPermission.unsupported;
    }
  }

  @override
  Future<void> schedule(LocalReminder reminder) async {
    if (!await _init()) return;
    try {
      await _plugin.zonedSchedule(
        id: reminder.id,
        scheduledDate: tz.TZDateTime.from(reminder.at.toUtc(), tz.UTC),
        notificationDetails: _details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        title: reminder.title,
        body: reminder.body,
        payload: reminder.route,
      );
    } on Object catch (error) {
      debugPrint('Couldn\'t schedule $reminder: $error');
    }
  }

  @override
  Future<void> cancel(int id) async {
    if (!await _init()) return;
    try {
      await _plugin.cancel(id: id);
    } on Object catch (error) {
      debugPrint('Couldn\'t cancel reminder $id: $error');
    }
  }

  @override
  Stream<String> get taps {
    unawaited(_init());
    return _taps.stream;
  }

  @override
  Future<String?> launchRoute() async {
    if (!await _init()) return null;
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) return null;
      final route = details.notificationResponse?.payload;
      return route != null && route.startsWith('/') ? route : null;
    } on Object {
      return null;
    }
  }
}

/// Keeps reminders in memory: for tests, and platforms without local notifications.
class MemoryReminderScheduler implements ReminderScheduler {
  MemoryReminderScheduler({this.permission = ReminderPermission.granted});

  ReminderPermission permission;
  final Map<int, LocalReminder> scheduled = {};
  final List<int> cancelled = [];
  final StreamController<String> _taps = StreamController.broadcast();
  String? launchedFrom;

  @override
  Future<ReminderPermission> ensurePermission() async => permission;

  @override
  Future<void> schedule(LocalReminder reminder) async {
    if (permission == ReminderPermission.granted) scheduled[reminder.id] = reminder;
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }

  /// Pretends the user tapped a reminder.
  void tap(String route) => _taps.add(route);

  @override
  Stream<String> get taps => _taps.stream;

  @override
  Future<String?> launchRoute() async => launchedFrom;
}

final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  final mobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  return mobile ? DeviceReminderScheduler() : MemoryReminderScheduler();
});

/// An event to add to the phone's calendar.
@immutable
class CalendarEvent {
  const CalendarEvent({
    required this.title,
    required this.start,
    required this.end,
    this.description,
  });

  final String title;
  final DateTime start;
  final DateTime end;
  final String? description;
}

/// Opens the phone's calendar with an event filled in, for the user to save.
abstract interface class CalendarExporter {
  /// Whether the calendar app opened.
  Future<bool> add(CalendarEvent event);
}

/// `add_2_calendar`: the system "new event" screen, so no calendar permission is needed.
class DeviceCalendarExporter implements CalendarExporter {
  @override
  Future<bool> add(CalendarEvent event) async {
    try {
      return await cal.Add2Calendar.addEvent2Cal(
        cal.Event(
          title: event.title,
          description: event.description,
          startDate: event.start.toLocal(),
          endDate: event.end.toLocal(),
        ),
      );
    } on Object catch (error) {
      debugPrint('Couldn\'t open the calendar: $error');
      return false;
    }
  }
}

/// Records events instead of opening a calendar (tests).
class MemoryCalendarExporter implements CalendarExporter {
  MemoryCalendarExporter({this.opens = true});

  bool opens;
  final List<CalendarEvent> added = [];

  @override
  Future<bool> add(CalendarEvent event) async {
    added.add(event);
    return opens;
  }
}

final calendarExporterProvider = Provider<CalendarExporter>((ref) => DeviceCalendarExporter());
