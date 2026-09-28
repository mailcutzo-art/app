import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/shell.dart';
import '../../core/network/app_failure.dart';
import '../../core/notifications/local_reminders.dart';
import '../../core/utils/ids.dart';
import '../learn/widgets/learn_widgets.dart' show InlineError;
import '../wallet/wallet_providers.dart';
import 'arena_providers.dart';
import 'arena_text.dart';
import 'data/tournament_models.dart';
import 'data/tournament_repository.dart';
import 'tournament_reminders.dart';

/// Opens the registration sheet for [tournament]: the fee (held, not spent), the balance, the
/// refund rules, then "You're in" with Add to calendar. Returns the updated card when the player
/// registered.
Future<Tournament?> showRegisterSheet(BuildContext context, Tournament tournament) =>
    showAppSheet<Tournament>(context, builder: (_) => RegisterSheet(tournament: tournament));

/// Asks before withdrawing, with the refund rule for this moment: a full refund before the start
/// (and for "Can't make it"), none after it. Returns true once withdrawn.
Future<bool> confirmWithdraw(
  BuildContext context,
  Tournament tournament, {
  bool cantMakeIt = false,
}) async {
  final done = await showAppSheet<bool>(
    context,
    builder: (_) => WithdrawSheet(tournament: tournament, cantMakeIt: cantMakeIt),
  );
  return done ?? false;
}

/// Checks in, with a toast either way. Returns true when checked in.
Future<bool> checkInNow(BuildContext context, WidgetRef ref, Tournament tournament) async {
  try {
    await ref.read(tournamentActionsProvider).checkIn(tournament.id);
    if (context.mounted) {
      showAppToast(
        context,
        'You\'re checked in. Stay close: round 1 starts soon.',
        icon: AppIcons.checkCircle,
      );
    }
    return true;
  } on AppFailure catch (failure) {
    if (context.mounted) {
      showAppToast(
        context,
        arenaErrorMessage(failure, tournament: tournament),
        icon: AppIcons.alert,
      );
    }
    return false;
  }
}

/// Opens the phone's calendar with the tournament filled in.
Future<void> addToCalendar(BuildContext context, WidgetRef ref, Tournament tournament) async {
  final opened = await ref
      .read(calendarExporterProvider)
      .add(TournamentReminders.calendarEvent(tournament));
  if (!opened && context.mounted) {
    showAppToast(context, 'Couldn\'t open your calendar.', icon: AppIcons.alert);
  }
}

/// `POST /v1/tournaments/{id}/register` behind a confirmation.
class RegisterSheet extends ConsumerStatefulWidget {
  const RegisterSheet({super.key, required this.tournament});

  final Tournament tournament;

  @override
  ConsumerState<RegisterSheet> createState() => _RegisterSheetState();
}

class _RegisterSheetState extends ConsumerState<RegisterSheet> {
  /// One key per sheet: retrying after a timeout never holds the fee twice.
  final String _key = randomHexId();
  bool _sending = false;
  String? _error;
  Tournament? _registered;
  ReminderOutcome? _reminders;

  Tournament get _t => widget.tournament;

  Future<void> _register() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final (updated, reminders) = await ref
          .read(tournamentActionsProvider)
          .register(_t, idempotencyKey: _key);
      if (mounted) {
        setState(() {
          _registered = updated;
          _reminders = reminders;
        });
      }
    } on AppFailure catch (failure) {
      if (mounted) setState(() => _error = arenaErrorMessage(failure, tournament: _t));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final registered = _registered;
    if (registered != null) return _done(context, registered);
    final wallet = ref.watch(walletProvider);
    final available = wallet.value == null
        ? null
        : (wallet.value!.balance - wallet.value!.held).clamp(0, wallet.value!.balance);
    final short = available != null && available < _t.entryFee;
    final text = context.text;
    return SheetScaffold(
      title: 'Register for ${_t.title}',
      subtitle: '${startDay(_t.startsAt, DateTime.now())} · ${subjectExamLine(_t)}',
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            InlineError(message: _error!),
            const SizedBox(height: AppSpacing.md),
          ],
          AppButton(
            label: _t.isFree ? 'Register · free' : 'Register · ${feeLabel(_t.entryFee)}',
            loading: _sending,
            onPressed: short ? null : _register,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Cancel',
            variant: AppButtonVariant.ghost,
            onPressed: _sending ? null : () => Navigator.pop(context),
          ),
        ],
      ),
      child: Gutter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _FactRow(
              label: 'Entry fee',
              value: _t.isFree
                  ? Text('Free', style: text.numericMedium)
                  : CoinAmount(amount: _t.entryFee),
            ),
            if (!_t.isFree)
              _FactRow(
                label: 'Your coins',
                value: switch (available) {
                  final coins? => CoinAmount(amount: coins),
                  null when wallet.hasError => Text('—', style: text.numericMedium),
                  null => const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                },
              ),
            _FactRow(label: 'Players', value: Text('${_t.players} of ${_t.capacity}')),
            const SizedBox(height: AppSpacing.md),
            if (short)
              InlineError(message: 'You need ${feeLabel(_t.entryFee)}. You have $available.')
            else
              Text(
                _t.isFree
                    ? 'Free to enter. Withdraw any time before the start.'
                    : 'The fee is held, not spent, until the start. Withdraw before the start '
                          'for a full refund; after the start there\'s no refund.',
                style: text.bodySmall,
              ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Check in 15 to 2 minutes before the start, or your place is refunded and '
              'dropped. We\'ll remind you 1 hour and 15 minutes before.',
              style: text.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _done(BuildContext context, Tournament registered) {
    final reminderLine = switch (_reminders) {
      ReminderOutcome.scheduled => 'Reminders are set for 1 hour and 15 minutes before the start.',
      ReminderOutcome.notificationsOff =>
        'Notifications are off, so reminders will only show in your inbox.',
      _ => 'Reminders will show in your inbox.',
    };
    return SheetScaffold(
      title: 'You\'re in!',
      subtitle: '${registered.title} · ${startDay(registered.startsAt, DateTime.now())}',
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppButton(
            label: 'Add to calendar',
            variant: AppButtonVariant.secondary,
            leadingIcon: AppIcons.calendar,
            onPressed: () => unawaited(addToCalendar(context, ref, registered)),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(label: 'Done', onPressed: () => Navigator.pop(context, registered)),
        ],
      ),
      child: Gutter(
        child: Semantics(
          liveRegion: true,
          child: Text(reminderLine, style: context.text.bodyMedium),
        ),
      ),
    );
  }
}

/// `DELETE /v1/tournaments/{id}/register` behind a confirmation that says what happens to the
/// fee.
class WithdrawSheet extends ConsumerStatefulWidget {
  const WithdrawSheet({super.key, required this.tournament, this.cantMakeIt = false});

  final Tournament tournament;
  final bool cantMakeIt;

  @override
  ConsumerState<WithdrawSheet> createState() => _WithdrawSheetState();
}

class _WithdrawSheetState extends ConsumerState<WithdrawSheet> {
  bool _sending = false;
  String? _error;

  Tournament get _t => widget.tournament;

  bool get _started => _t.status.isLive || _t.status.isOver;

  Future<void> _withdraw() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final result = await ref.read(tournamentActionsProvider).withdraw(_t.id);
      if (!mounted) return;
      final message = _started
          ? 'You left ${_t.title}.'
          : result.refunded > 0
          ? 'Withdrawn. Your ${feeLabel(result.refunded)} are back.'
          : 'Withdrawn from ${_t.title}.';
      showAppToast(context, message, icon: AppIcons.checkCircle);
      Navigator.pop(context, true);
    } on AppFailure catch (failure) {
      if (mounted) setState(() => _error = arenaErrorMessage(failure, tournament: _t));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (title, body, action) = switch ((_started, widget.cantMakeIt)) {
      (true, _) => (
        'Leave ${_t.title}?',
        'You keep your place in the standings, so tie-breaks stay fair, but you can\'t win a '
            'prize and the entry fee isn\'t refunded.',
        'Leave tournament',
      ),
      (false, true) => (
        'Can\'t make it?',
        _t.isFree
            ? 'We\'ll take you off the list. You can register for another tournament any time.'
            : 'We\'ll take you off the list and return your ${feeLabel(_t.entryFee)} in full.',
        'Withdraw',
      ),
      (false, false) => (
        'Withdraw from ${_t.title}?',
        _t.isFree
            ? 'You can register again while registration is open.'
            : 'Before the start you get your ${feeLabel(_t.entryFee)} back in full.',
        'Withdraw',
      ),
    };
    return SheetScaffold(
      title: title,
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            InlineError(message: _error!),
            const SizedBox(height: AppSpacing.md),
          ],
          AppButton(
            label: action,
            variant: AppButtonVariant.danger,
            loading: _sending,
            onPressed: _withdraw,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Stay in',
            variant: AppButtonVariant.ghost,
            onPressed: _sending ? null : () => Navigator.pop(context, false),
          ),
        ],
      ),
      child: Gutter(child: Text(body, style: context.text.bodyMedium)),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
    child: Row(
      children: [
        Expanded(child: Text(label, style: context.text.bodyMedium)),
        DefaultTextStyle.merge(style: context.text.numericMedium, child: value),
      ],
    ),
  );
}
