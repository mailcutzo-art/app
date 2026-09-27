import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/shell.dart';
import '../../core/network/app_failure.dart';
import '../../core/utils/ids.dart';
import '../practice/data/practice_models.dart';
import '../practice/start_practice.dart';
import 'data/learn_models.dart';
import 'widgets/learn_widgets.dart';

/// Practice settings for one chapter. Creates the session and closes with
/// it, or null if dismissed; errors stay inline in the sheet.
Future<PracticeSession?> showChapterSheet(
  BuildContext context, {
  required CatalogSubject subject,
  required CatalogChapter chapter,
}) => showAppSheet<PracticeSession>(
  context,
  builder: (_) => ChapterSheet(subject: subject, chapter: chapter),
);

class ChapterSheet extends ConsumerStatefulWidget {
  const ChapterSheet({super.key, required this.subject, required this.chapter});

  final CatalogSubject subject;
  final CatalogChapter chapter;

  @override
  ConsumerState<ChapterSheet> createState() => _ChapterSheetState();
}

class _ChapterSheetState extends ConsumerState<ChapterSheet> {
  static const _counts = [10, 20, 30];

  /// Null practises the whole chapter.
  String? _topic;
  int _count = 10;
  Difficulty _difficulty = Difficulty.mixed;
  bool _timed = false;
  bool _starting = false;
  String? _error;

  /// A retry of the same settings reuses the key, so a request that timed
  /// out after the server created the session doesn't create a second one.
  String? _key;
  SessionSettings? _keyFor;

  SessionSettings get _settings => SessionSettings(
    mode: _topic == null ? PracticeMode.chapter : PracticeMode.topic,
    subject: widget.subject.slug,
    chapters: [if (_topic == null) widget.chapter.slug],
    topic: _topic,
    count: _count,
    difficulty: _difficulty,
    timed: _timed,
    perQuestionS: _timed ? SessionSettings.defaultPerQuestionS : null,
  );

  void _change(VoidCallback change) => setState(() {
    change();
    _error = null;
  });

  Future<void> _start() async {
    final settings = _settings;
    if (settings != _keyFor) {
      _keyFor = settings;
      _key = randomHexId();
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final session = await ref
          .read(practiceStarterProvider)
          .start(settings, idempotencyKey: _key!);
      if (mounted) Navigator.pop(context, session);
    } on AppFailure catch (failure) {
      if (mounted) setState(() => _error = practiceStartError(failure));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.chapter;
    return SheetScaffold(
      title: chapter.name,
      subtitle: '${widget.subject.name} · ${plural(chapter.questionCount, 'question')}',
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            _InlineError(message: _error!),
            const SizedBox(height: AppSpacing.md),
          ],
          AppButton(
            label: 'Start practice',
            trailingIcon: AppIcons.chevronRight,
            loading: _starting,
            onPressed: _start,
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Label('Topic'),
            SelectableRow(
              title: 'Whole chapter',
              subtitle: plural(chapter.questionCount, 'question'),
              icon: AppIcons.allChapters,
              selected: _topic == null,
              onTap: () => _change(() => _topic = null),
            ),
            for (final topic in chapter.topics)
              SelectableRow(
                title: topic.name,
                subtitle: plural(topic.questionCount, 'question'),
                selected: _topic == topic.slug,
                onTap: () => _change(() => _topic = topic.slug),
              ),
            const _Label('Questions'),
            Gutter(
              child: AppSegmentedControl<int>(
                segments: [for (final n in _counts) AppSegment(value: n, label: '$n')],
                selected: _count,
                onChanged: (n) => _change(() => _count = n),
              ),
            ),
            const _Label('Difficulty'),
            Gutter(
              child: Wrap(
                spacing: AppSpacing.sm,
                children: [
                  for (final difficulty in Difficulty.values)
                    _TallTapTarget(
                      onTap: () => _change(() => _difficulty = difficulty),
                      child: AppChip(
                        label: difficulty.label,
                        selected: _difficulty == difficulty,
                        onSelected: (_) => _change(() => _difficulty = difficulty),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            ToggleRow(
              title: 'Timed',
              subtitle: '${SessionSettings.defaultPerQuestionS} s per question',
              icon: AppIcons.timer,
              value: _timed,
              onChanged: (on) => _change(() => _timed = on),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.gutter,
      AppSpacing.lg,
      AppSpacing.gutter,
      AppSpacing.sm,
    ),
    child: Text(text.toUpperCase(), style: context.text.overline),
  );
}

/// Gives a 40 dp chip a 48 dp tall tap target without changing its look.
class _TallTapTarget extends StatelessWidget {
  const _TallTapTarget({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSizes.minTouch),
      child: Center(widthFactor: 1, child: child),
    ),
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: [
            HugeIcon(AppIcons.alert, size: 20, color: colors.onErrorContainer),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: context.text.labelMedium.copyWith(color: colors.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
