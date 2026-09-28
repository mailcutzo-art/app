import 'package:design_system/design_system.dart' hide Presence;
import 'package:design_system/design_system.dart' as ds show Presence;
import 'package:flutter/material.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../battle/chapter_picker.dart';
import '../../battle/data/battle_models.dart';
import '../../battle/match/match_widgets.dart' show avatarOf;
import '../../learn/widgets/learn_widgets.dart' show subjectTone;
import '../data/room_models.dart';
import '../room_code.dart';
import '../room_text.dart';

/// Question counts offered for each kind of room; the defaults are 7 and 10.
List<int> questionChoices(RoomKind kind) =>
    kind == RoomKind.friend ? const [5, 7, 10] : const [5, 10, 15, 20];

const secondChoices = [10, 15, 20, 30];

/// The settings a new room starts from (docs/plan.md: **7** or **10** questions, **15** s, late
/// join until halfway, the leaderboard on, anyone with the code).
RoomSettings defaultRoomSettings(RoomKind kind, {String? subject, String? chapter}) =>
    switch (kind) {
      RoomKind.friend => RoomSettings(
        subject: subject,
        chapters: [?chapter],
        questions: 7,
        seconds: 15,
      ),
      RoomKind.group => RoomSettings(
        subject: subject,
        chapters: [?chapter],
        questions: 10,
        seconds: 15,
        difficulty: 'mixed',
        lateJoin: 'halfway',
        leaderboard: true,
        join: 'code',
      ),
    };

/// The settings in a few words each: "Physics", "All chapters", "7 questions", "15 s each", and
/// for groups the difficulty, late join, leaderboard and who can join.
List<String> settingsLines(RoomSettings settings, RoomKind kind, {BattleSetup? setup}) {
  final subject = setup?.subject(settings.subject);
  final chapters = settings.chapters;
  final chapterText = switch (chapters.length) {
    0 => 'All chapters',
    1 => subject?.chapter(chapters.single)?.name ?? RoomText.subject(chapters.single),
    _ => '${chapters.length} chapters',
  };
  return [
    subject?.name ?? RoomText.subject(settings.subject),
    chapterText,
    if (settings.questions != null) '${settings.questions} questions',
    if (settings.seconds != null) '${settings.seconds} s each',
    if (kind == RoomKind.group) ...[
      '${RoomText.difficulty(settings.difficulty)} difficulty',
      settings.lateJoin == 'off' ? 'No late joining' : 'Late join until halfway',
      settings.leaderboard == false ? 'No leaderboard' : 'Leaderboard between questions',
      settings.join == 'friends' ? 'Friends only' : 'Anyone with the code',
    ],
  ];
}

/// Subject, chapters, questions and time (plus the group options), as a controlled form.
class RoomSettingsForm extends StatelessWidget {
  const RoomSettingsForm({
    super.key,
    required this.kind,
    required this.setup,
    required this.settings,
    required this.onChanged,
  });

  final RoomKind kind;
  final BattleSetup setup;
  final RoomSettings settings;

  /// Null disables the form.
  final ValueChanged<RoomSettings>? onChanged;

  BattleSubject get _subject => setup.subject(settings.subject) ?? setup.subjects.first;

  Future<void> _pickChapters(BuildContext context) async {
    final subject = _subject;
    if (kind == RoomKind.friend) {
      final choice = await showChapterPicker(
        context,
        subject: subject,
        selected: settings.chapters.firstOrNull,
      );
      if (choice == null) return;
      onChanged?.call(settings.copyWith(chapters: [?choice.chapter]));
      return;
    }
    final chosen = await showAppSheet<List<String>>(
      context,
      builder: (_) => ChapterMultiPicker(subject: subject, selected: settings.chapters),
    );
    if (chosen != null) onChanged?.call(settings.copyWith(chapters: chosen));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final subject = _subject;
    final enabled = onChanged != null;
    final chapterName = switch (settings.chapters.length) {
      0 => 'All chapters',
      1 => subject.chapter(settings.chapters.single)?.name ?? settings.chapters.single,
      final n => '$n chapters',
    };
    void change(RoomSettings next) => onChanged?.call(next);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Label('Subject'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            children: [
              for (final (i, s) in setup.subjects.indexed) ...[
                if (i > 0) const SizedBox(width: AppSpacing.sm),
                AppChip(
                  label: s.name,
                  dotColor: colors.pastel(subjectTone(s.tone)).onContainer,
                  selected: s.slug == subject.slug,
                  onSelected: enabled
                      ? (_) => change(settings.copyWith(subject: s.slug, chapters: const []))
                      : null,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Pressable(
          onPressed: enabled ? () => _pickChapters(context) : null,
          semanticLabel: 'Chapters: $chapterName. Change',
          pressedScale: 0.98,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 14),
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: BorderRadius.circular(AppRadii.lg),
            ),
            child: Row(
              children: [
                HugeIcon(AppIcons.learn, size: 20, color: colors.inkMuted),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(kind == RoomKind.friend ? 'Chapter' : 'Chapters', style: text.caption),
                      Text(
                        chapterName,
                        style: text.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                HugeIcon(AppIcons.chevronDown, size: 20, color: colors.ink),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        const _Label('Questions'),
        AppSegmentedControl<int>(
          segments: [for (final n in questionChoices(kind)) AppSegment(value: n, label: '$n')],
          selected: settings.questions ?? questionChoices(kind)[1],
          onChanged: enabled ? (n) => change(settings.copyWith(questions: n)) : null,
        ),
        const SizedBox(height: AppSpacing.lg),
        const _Label('Time per question'),
        AppSegmentedControl<int>(
          segments: [for (final s in secondChoices) AppSegment(value: s, label: '$s s')],
          selected: settings.seconds ?? 15,
          onChanged: enabled ? (s) => change(settings.copyWith(seconds: s)) : null,
        ),
        if (kind == RoomKind.group) ...[
          const SizedBox(height: AppSpacing.lg),
          const _Label('Difficulty'),
          AppSegmentedControl<String>(
            segments: const [
              AppSegment(value: 'mixed', label: 'Mixed'),
              AppSegment(value: 'easy', label: 'Easy'),
              AppSegment(value: 'medium', label: 'Medium'),
              AppSegment(value: 'hard', label: 'Hard'),
            ],
            selected: settings.difficulty ?? 'mixed',
            onChanged: enabled ? (d) => change(settings.copyWith(difficulty: d)) : null,
          ),
          const SizedBox(height: AppSpacing.lg),
          const _Label('Late join'),
          AppSegmentedControl<String>(
            segments: const [
              AppSegment(value: 'off', label: 'Off'),
              AppSegment(value: 'halfway', label: 'Until halfway'),
            ],
            selected: settings.lateJoin ?? 'halfway',
            onChanged: enabled ? (v) => change(settings.copyWith(lateJoin: v)) : null,
          ),
          const SizedBox(height: AppSpacing.lg),
          const _Label('Who can join'),
          AppSegmentedControl<String>(
            segments: const [
              AppSegment(value: 'friends', label: 'Friends only'),
              AppSegment(value: 'code', label: 'Anyone with code'),
            ],
            selected: settings.join ?? 'code',
            onChanged: enabled ? (v) => change(settings.copyWith(join: v)) : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          ToggleRow(
            title: 'Leaderboard between questions',
            subtitle: 'The top 3 and your place after every question',
            icon: AppIcons.chart,
            margin: EdgeInsets.zero,
            value: settings.leaderboard ?? true,
            onChanged: enabled ? (v) => change(settings.copyWith(leaderboard: v)) : null,
          ),
        ],
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: AppSpacing.sm),
    child: Text(text, style: context.text.labelMedium),
  );
}

/// All chapters, or any number of battle-ready ones, for a group battle. Closes with the chosen
/// slugs (empty for all), or null when dismissed.
class ChapterMultiPicker extends StatefulWidget {
  const ChapterMultiPicker({super.key, required this.subject, required this.selected});

  final BattleSubject subject;
  final List<String> selected;

  @override
  State<ChapterMultiPicker> createState() => _ChapterMultiPickerState();
}

class _ChapterMultiPickerState extends State<ChapterMultiPicker> {
  late final Set<String> _chosen = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final subject = widget.subject;
    return SheetScaffold(
      title: 'Choose chapters',
      subtitle: '${subject.name} · pick one or more, or all',
      footer: AppButton(
        label: _chosen.isEmpty ? 'Use all chapters' : 'Use ${_chosen.length} chapters',
        onPressed: () => Navigator.pop(context, [
          for (final c in subject.chapters)
            if (_chosen.contains(c.slug)) c.slug,
        ]),
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: AppSpacing.lg),
        children: [
          SelectableRow(
            title: 'All chapters',
            subtitle: 'Mixed questions',
            icon: AppIcons.allChapters,
            iconBackground: colors.lemon.container,
            iconColor: colors.lemon.onContainer,
            selected: _chosen.isEmpty,
            onTap: () => setState(_chosen.clear),
          ),
          for (final chapter in subject.chapters)
            SelectableRow(
              title: chapter.name,
              subtitle: chapterSubtitle(chapter),
              selected: _chosen.contains(chapter.slug),
              enabled: chapter.battleReady,
              onTap: () => setState(() {
                if (!_chosen.remove(chapter.slug)) _chosen.add(chapter.slug);
              }),
            ),
        ],
      ),
    );
  }
}

/// The room code in big type, with Copy code and Share link.
class RoomCodeCard extends StatelessWidget {
  const RoomCodeCard({super.key, required this.code, required this.onCopy, required this.onShare});

  final String code;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final pair = colors.lavender;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xl),
      decoration: BoxDecoration(
        color: pair.container,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadii.xxl)),
      ),
      child: Column(
        children: [
          Text('ROOM CODE', style: text.overline.copyWith(color: pair.onContainer)),
          const SizedBox(height: AppSpacing.sm),
          Semantics(
            label: 'Room code ${code.split('').join(' ')}',
            excludeSemantics: true,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                RoomCode.spaced(code),
                style: text.numericLarge.copyWith(fontSize: 44, letterSpacing: 6, height: 1.1),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Copy code',
                  size: AppButtonSize.medium,
                  variant: AppButtonVariant.secondary,
                  leadingIcon: AppIcons.document,
                  onPressed: onCopy,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: 'Share link',
                  size: AppButtonSize.medium,
                  variant: AppButtonVariant.ink,
                  leadingIcon: AppIcons.share,
                  onPressed: onShare,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One member of the lobby: avatar with presence, name, and Host / Ready / Away badges.
class MemberTile extends StatelessWidget {
  const MemberTile({
    super.key,
    required this.member,
    required this.isMe,
    required this.isHost,
    this.onManage,
  });

  final RoomMember member;
  final bool isMe;
  final bool isHost;

  /// The host's menu for this member (make host, remove); null for everyone else.
  final VoidCallback? onManage;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final name = member.card.displayName ?? member.card.handle ?? 'Player';
    final present = member.connected && !member.away;
    final status = !member.connected
        ? 'Reconnecting…'
        : member.away
        ? 'Away'
        : (member.ready ? 'Ready' : 'Not ready');
    return Semantics(
      container: true,
      label: [name, if (isMe) 'you', if (isHost) 'host', status].join(', '),
      excludeSemantics: onManage == null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
        decoration: BoxDecoration(
          color: isMe ? colors.accentSoft : colors.surface,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(color: isMe ? colors.accent : colors.outline),
        ),
        child: Row(
          children: [
            AppAvatar(
              data: avatarOf(member.card),
              presence: present ? ds.Presence.online : ds.Presence.offline,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          isMe ? '$name (you)' : name,
                          style: text.titleMedium.copyWith(fontSize: 15),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isHost) ...[
                        const SizedBox(width: AppSpacing.xs),
                        HugeIcon(AppIcons.crown, size: 16, color: colors.coin),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      if (isHost) _Badge(label: 'Host', pair: colors.lemon),
                      _Badge(
                        label: status,
                        pair: !member.connected || member.away
                            ? colors.peach
                            : (member.ready ? colors.mint : colors.pastel(PastelTone.neutral)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (onManage != null)
              AppIconButton(
                icon: AppIcons.more,
                size: AppSizes.iconButtonSmall,
                variant: AppIconButtonVariant.ghost,
                semanticLabel: 'Manage $name',
                onPressed: onManage,
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.pair});

  final String label;
  final PastelPair pair;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
    decoration: BoxDecoration(color: pair.container, borderRadius: AppRadii.pillAll),
    child: Text(label, style: context.text.caption.copyWith(color: pair.onContainer)),
  );
}

/// An empty seat in a friend duel: "Waiting…".
class WaitingSeat extends StatelessWidget {
  const WaitingSeat({super.key, this.label = 'Waiting for your friend…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        border: Border.all(color: colors.outline),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: colors.surfaceMuted, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: HugeIcon(AppIcons.hourglass, size: 20, color: colors.inkMuted),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: Text(label, style: context.text.bodyMedium)),
        ],
      ),
    );
  }
}
