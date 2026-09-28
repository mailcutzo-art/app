import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import 'inbox_providers.dart';

/// The bell in tab headers: the unread count as a badge, a ring whenever it goes up, and the
/// inbox on tap.
class InboxBell extends ConsumerStatefulWidget {
  const InboxBell({super.key});

  @override
  ConsumerState<InboxBell> createState() => _InboxBellState();
}

class _InboxBellState extends ConsumerState<InboxBell> {
  /// Bumped on every increase; the icon rings when it changes.
  int _rings = 0;

  @override
  Widget build(BuildContext context) {
    ref.listen(unreadCountProvider, (previous, next) {
      if (next > (previous ?? 0)) setState(() => _rings++);
    });
    return AppIconButton(
      icon: AppIcons.notification,
      semanticLabel: 'Notifications',
      motion: IconMotions.bell,
      motionTrigger: _rings,
      badgeCount: ref.watch(unreadCountProvider),
      onPressed: () => unawaited(context.push(Routes.inbox)),
    );
  }
}
