import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/shell.dart' show Gutter;
import '../../core/auth/session.dart';
import '../../core/auth/user.dart';
import '../../core/network/app_failure.dart';
import '../../core/utils/time_text.dart';
import '../onboarding/avatar_picker.dart';
import '../onboarding/onboarding_repository.dart';
import 'data/settings_models.dart';
import 'data/settings_repository.dart';
import 'widgets/settings_widgets.dart';

/// Edit profile (`/settings/profile`): name, avatar, goal, and the username, which can change
/// once every 30 days. Only what changed is sent.
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final Me _me = ref.read(meProvider);
  late final _name = TextEditingController(text: _me.displayName);
  late final _handle = TextEditingController(text: _me.handle ?? '');
  late Avatar _avatar = _me.avatar;
  late Goal? _goal = _me.goal;

  Timer? _debounce;
  bool _checkingHandle = false;
  HandleStatus? _handleStatus;
  String? _nameError;
  String? _handleError;
  bool _saving = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _handle.dispose();
    super.dispose();
  }

  String get _newName => _name.text.trim();
  String get _newHandle => _handle.text.trim();
  bool get _handleChanged => _newHandle != (_me.handle ?? '');

  ProfilePatch get _patch => ProfilePatch(
    displayName: _newName == _me.displayName ? null : _newName,
    handle: _handleChanged ? _newHandle : null,
    avatar: _avatar == _me.avatar ? null : _avatar,
    goal: _goal == _me.goal ? null : _goal,
  );

  bool get _canSave =>
      !_saving &&
      !_patch.isEmpty &&
      _newName.length >= 2 &&
      (!_handleChanged || _handleStatus == HandleStatus.available);

  void _onHandleChanged(String value) {
    _debounce?.cancel();
    final valid = handlePattern.hasMatch(value);
    setState(() {
      _handleStatus = null;
      _handleError = value.isNotEmpty && !valid ? '3–20 letters, numbers or _' : null;
      _checkingHandle = valid && _handleChanged;
    });
    if (!valid || !_handleChanged) return;
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final status = await ref.read(onboardingRepositoryProvider).checkHandle(value);
        if (!mounted || _handle.text != value) return;
        setState(() {
          _handleStatus = status;
          _checkingHandle = false;
          _handleError = switch (status) {
            HandleStatus.available => null,
            HandleStatus.taken => 'That username is taken',
            HandleStatus.reserved => 'That username isn\'t allowed',
            HandleStatus.invalid => '3–20 letters, numbers or _',
          };
        });
      } on AppFailure {
        if (mounted) setState(() => _checkingHandle = false);
      }
    });
  }

  Future<void> _save() async {
    if (_newName.length < 2) {
      setState(() => _nameError = 'Please enter at least 2 characters');
      return;
    }
    setState(() => _saving = true);
    try {
      final me = await ref.read(accountRepositoryProvider).updateProfile(_patch);
      await ref.read(sessionProvider.notifier).updateUser(me);
      if (!mounted) return;
      showAppToast(context, 'Profile saved', icon: AppIcons.check);
      if (context.canPop()) context.pop();
    } on AppFailure catch (failure) {
      if (!mounted) return;
      final handleProblem = _handleProblem(failure);
      if (handleProblem != null) {
        setState(() {
          _handleError = handleProblem;
          _handleStatus = HandleStatus.taken;
        });
      } else if (failure is ValidationFailure && failure.fields.isNotEmpty) {
        setState(() {
          _nameError = failure.fields['display_name'];
          _handleError = failure.fields['handle'];
        });
      } else {
        showAppToast(context, failure.message, icon: AppIcons.alert);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The inline message for a refused username, or null for other failures.
  static String? _handleProblem(AppFailure failure) => switch (failure.code) {
    'HANDLE_TAKEN' => 'That username was just taken',
    'HANDLE_CHANGE_TOO_SOON' => switch (failure.details['next_change_at']) {
      final String at when DateTime.tryParse(at) != null =>
        'You can change your username again on ${fullDate(DateTime.parse(at))}',
      _ => 'You can change your username once every 30 days',
    },
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final goalChanged = _goal != null && _goal != _me.goal;
    return SettingsPage(
      title: 'Edit profile',
      children: [
        Gutter(
          child: AvatarPicker(value: _avatar, onChanged: (a) => setState(() => _avatar = a)),
        ),
        const SizedBox(height: AppSpacing.xxl),
        Gutter(
          child: AppTextField(
            label: 'Name',
            controller: _name,
            maxLength: 30,
            error: _nameError,
            helper: _me.isMinor ? 'Shown to other players' : null,
            textInputAction: TextInputAction.next,
            onChanged: (_) => setState(() => _nameError = null),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Gutter(
          child: AppTextField(
            label: 'Username',
            controller: _handle,
            maxLength: 20,
            error: _handleError,
            helper: 'You can change your username once every 30 days.',
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9_]')),
              const _LowerCase(),
            ],
            suffix: _HandleIndicator(checking: _checkingHandle, status: _handleStatus),
            onChanged: _onHandleChanged,
          ),
        ),
        const SettingsHeader('Exam'),
        for (final goal in Goal.values)
          SelectableRow(
            title: goal.label,
            subtitle: goal.subjects,
            icon: goal == Goal.neet ? AppIcons.biology : AppIcons.maths,
            selected: _goal == goal,
            onTap: () => setState(() => _goal = goal),
          ),
        if (goalChanged)
          SettingsNote(
            'Boards, missions and tips switch to ${_goal!.label}. Your ratings in other '
            'subjects are kept under "Other subjects".',
          ),
        const SizedBox(height: AppSpacing.xxl),
        Gutter(
          child: AppButton(label: 'Save', loading: _saving, onPressed: _canSave ? _save : null),
        ),
      ],
    );
  }
}

class _HandleIndicator extends StatelessWidget {
  const _HandleIndicator({required this.checking, required this.status});

  final bool checking;
  final HandleStatus? status;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final Widget child;
    if (checking) {
      child = SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: colors.inkMuted),
      );
    } else if (status == HandleStatus.available) {
      child = HugeIcon(AppIcons.checkCircle, size: 22, color: colors.success);
    } else {
      child = const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: SizedBox(width: 22, height: 22, child: Center(child: child)),
    );
  }
}

class _LowerCase extends TextInputFormatter {
  const _LowerCase();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toLowerCase());
}
