import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/shell.dart';
import '../../core/network/app_failure.dart';
import 'data/learn_repository.dart';
import 'data/question_models.dart';
import 'widgets/learn_widgets.dart';

/// Asks why [questionRef] looks wrong and reports it. Thanks the user with
/// a toast and returns true once sent; null if dismissed.
Future<bool?> showReportSheet(BuildContext context, {required String questionRef}) async {
  final sent = await showAppSheet<bool>(
    context,
    builder: (_) => ReportQuestionSheet(questionRef: questionRef),
  );
  if ((sent ?? false) && context.mounted) {
    showAppToast(context, 'Thanks! We\'ll check this question.', icon: AppIcons.checkCircle);
  }
  return sent;
}

/// `POST /v1/questions/{ref}/reports`: a reason (required) and a note.
class ReportQuestionSheet extends ConsumerStatefulWidget {
  const ReportQuestionSheet({super.key, required this.questionRef});

  final String questionRef;

  @override
  ConsumerState<ReportQuestionSheet> createState() => _ReportQuestionSheetState();
}

class _ReportQuestionSheetState extends ConsumerState<ReportQuestionSheet> {
  static const maxNote = 500;

  final _note = TextEditingController();
  ReportReason? _reason;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref
          .read(learnRepositoryProvider)
          .reportQuestion(widget.questionRef, reason, note: _note.text);
      if (mounted) Navigator.pop(context, true);
    } on AppFailure catch (failure) {
      if (mounted) setState(() => _error = reportErrorMessage(failure));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetScaffold(
      title: 'Report question',
      subtitle: 'What looks wrong? Our team checks every report.',
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            InlineError(message: _error!),
            const SizedBox(height: AppSpacing.md),
          ],
          AppButton(
            label: 'Send report',
            loading: _sending,
            onPressed: _reason == null ? null : _send,
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final reason in ReportReason.values)
              SelectableRow(
                title: reason.label,
                subtitle: reason.hint,
                selected: _reason == reason,
                onTap: () => setState(() {
                  _reason = reason;
                  _error = null;
                }),
              ),
            const SizedBox(height: AppSpacing.md),
            Gutter(
              child: AppTextField(
                label: 'Note (optional)',
                controller: _note,
                hint: 'e.g. Option C should be 25 m',
                maxLength: maxNote,
                textInputAction: TextInputAction.done,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What to say when a report couldn't be sent.
String reportErrorMessage(AppFailure failure) => switch (failure) {
  RateLimitedFailure() => 'You\'ve sent the most reports allowed today. Thank you for helping!',
  NotFoundFailure() => 'This question has been removed, so there\'s nothing to report.',
  _ => failure.message,
};
