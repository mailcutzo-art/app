import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../data/learn_models.dart';
import '../data/question_models.dart';

/// The subject's name from the catalog, or its slug made readable when the
/// catalog doesn't have it (another exam, or not loaded).
String subjectName(Catalog? catalog, String slug) {
  final name = catalog?.subject(slug)?.name;
  if (name != null) return name;
  if (slug.isEmpty) return slug;
  return slug[0].toUpperCase() + slug.substring(1).replaceAll('-', ' ');
}

/// "Physics · Motion in a Straight Line".
String questionPlace(QuestionSummary question, Catalog? catalog) =>
    [subjectName(catalog, question.subject), ?question.chapter?.name].join(' · ');

/// "All" plus one chip per subject, in a row that scrolls sideways.
class SubjectFilter extends StatelessWidget {
  const SubjectFilter({
    super.key,
    required this.subjects,
    required this.selected,
    required this.onChanged,
  });

  final List<CatalogSubject> subjects;

  /// Subject slug; null is "All".
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Row(
        children: [
          _chip('All', null),
          for (final subject in subjects) ...[
            const SizedBox(width: AppSpacing.sm),
            _chip(subject.name, subject.slug),
          ],
        ],
      ),
    );
  }

  Widget _chip(String label, String? slug) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: AppSizes.minTouch),
    child: Center(
      widthFactor: 1,
      child: AppChip(label: label, selected: selected == slug, onSelected: (_) => onChanged(slug)),
    ),
  );
}

/// A question in a list: its stem (quiz markup, up to three lines) and
/// where it lives. [trailing] is e.g. a bookmark button.
class QuestionRow extends StatelessWidget {
  const QuestionRow({
    super.key,
    required this.question,
    required this.place,
    required this.onTap,
    this.trailing,
  });

  final QuestionSummary question;

  /// "Physics · Motion in a Straight Line".
  final String place;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return SurfaceCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  QuizText(
                    question.stem,
                    style: text.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 3,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(place, style: text.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ),
          trailing ??
              Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: HugeIcon(AppIcons.chevronRight, size: 20, color: context.colors.inkMuted),
              ),
        ],
      ),
    );
  }
}

/// Loading placeholder shaped like a list of [QuestionRow]s.
class QuestionRowsSkeleton extends StatelessWidget {
  const QuestionRowsSkeleton({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) => Shimmer(
    child: Column(
      children: [
        for (var i = 0; i < rows; i++)
          const Padding(
            padding: EdgeInsets.only(bottom: AppSpacing.sm),
            child: SkeletonBox(height: 92, radius: AppRadii.xl),
          ),
      ],
    ),
  );
}
