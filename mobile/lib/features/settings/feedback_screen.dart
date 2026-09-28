import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/shell.dart' show Gutter;
import '../../core/network/app_failure.dart';
import '../../core/utils/ids.dart';
import 'data/settings_models.dart';
import 'data/settings_repository.dart';
import 'widgets/settings_widgets.dart';

/// Send feedback (`/settings/feedback`): a problem, an idea, a coins question or an appeal.
/// A problem report can carry the reference of the last error, so support can find it.
class FeedbackScreen extends ConsumerStatefulWidget {
  const FeedbackScreen({super.key, this.initialKind = FeedbackKind.problem});

  final FeedbackKind initialKind;

  @override
  ConsumerState<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends ConsumerState<FeedbackScreen> {
  static const minLength = 10;
  static const maxLength = 2000;

  late FeedbackKind _kind = widget.initialKind;
  final _message = TextEditingController();

  /// The last failed request's id, read once so it can't change under the user.
  late final String? _reference = ref.read(lastErrorRequestIdProvider)();
  bool _attach = true;
  bool _sending = false;

  /// One key per message, so a retry after a lost response isn't sent twice.
  String _key = randomHexId();

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  bool get _valid => _message.text.trim().length >= minLength;

  Future<void> _send() async {
    setState(() => _sending = true);
    try {
      await ref
          .read(accountRepositoryProvider)
          .sendFeedback(
            kind: _kind,
            message: _message.text.trim(),
            idempotencyKey: _key,
            requestId: _attach ? _reference : null,
          );
      if (!mounted) return;
      showAppToast(context, 'Thanks! We got your message.', icon: AppIcons.check);
      if (context.canPop()) context.pop();
    } on AppFailure catch (failure) {
      if (!mounted) return;
      if (failure is ValidationFailure) _key = randomHexId();
      showAppToast(context, failure.message, icon: AppIcons.alert);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reference = _reference;
    return SettingsPage(
      title: 'Send feedback',
      children: [
        const SettingsHeader('What is it about?'),
        for (final kind in FeedbackKind.values)
          SelectableRow(
            title: kind.label,
            selected: _kind == kind,
            onTap: () => setState(() => _kind = kind),
          ),
        const SettingsHeader('Your message'),
        Gutter(
          child: TextField(
            controller: _message,
            minLines: 5,
            maxLines: 10,
            maxLength: maxLength,
            textCapitalization: TextCapitalization.sentences,
            style: context.text.bodyLarge,
            decoration: InputDecoration(
              hintText: switch (_kind) {
                FeedbackKind.problem => 'What happened, and what did you expect?',
                FeedbackKind.idea => 'What would make the app better for you?',
                FeedbackKind.coins => 'Which game or reward, and what went wrong?',
                FeedbackKind.banAppeal => 'Tell us why the restriction should be lifted.',
              },
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        if (reference != null)
          ToggleRow(
            title: 'Attach the last error\'s reference',
            subtitle: 'Reference $reference',
            icon: AppIcons.document,
            value: _attach,
            onChanged: (on) => setState(() => _attach = on),
          ),
        const SizedBox(height: AppSpacing.xl),
        Gutter(
          child: AppButton(
            label: 'Send',
            loading: _sending,
            onPressed: _valid && !_sending ? _send : null,
          ),
        ),
        if (!_valid) const SettingsNote('Write at least $minLength characters so we can help.'),
      ],
    );
  }
}
