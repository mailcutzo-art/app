import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';

/// Password-less login for local testing; only offered in dev builds, and the
/// server refuses it outside its dev environment.
Future<void> showDevLoginSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const _DevLoginSheet());

class _DevLoginSheet extends ConsumerStatefulWidget {
  const _DevLoginSheet();

  @override
  ConsumerState<_DevLoginSheet> createState() => _DevLoginSheetState();
}

class _DevLoginSheetState extends ConsumerState<_DevLoginSheet> {
  final _email = TextEditingController(text: 'player1@example.com');
  final _name = TextEditingController(text: 'Player One');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(sessionProvider.notifier)
          .devLogin(_email.text.trim(), displayName: _name.text.trim());
      if (mounted) Navigator.pop(context);
    } on AppFailure catch (failure) {
      setState(() => _error = failure.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetScaffold(
      title: 'Developer login',
      subtitle: 'Creates or reuses a test account on the dev server.',
      footer: AppButton(label: 'Sign in', loading: _busy, onPressed: _submit),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTextField(
              label: 'Email',
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              error: _error,
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(label: 'Display name', controller: _name),
          ],
        ),
      ),
    );
  }
}
