import 'dart:async';
import 'dart:convert';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/env.dart';
import '../../core/auth/session.dart';
import '../../core/auth/user.dart';
import '../../core/network/app_failure.dart';
import '../debug/debug_screen.dart' show sharedPrefsProvider;
import 'avatar_picker.dart';
import 'onboarding_repository.dart';

/// Four short steps: name and handle, avatar, goal, birth year.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _steps = 4;

  late final PageController _pages;
  late final TextEditingController _name;
  final _handle = TextEditingController();
  final _birthYear = TextEditingController();

  int _step = 0;
  Avatar _avatar = Avatar.fallback;
  Goal? _goal;
  HandleStatus? _handleStatus;
  bool _checkingHandle = false;
  bool _submitting = false;
  String? _nameError;
  String? _handleError;
  String? _yearError;
  bool _underAge = false;
  Timer? _debounce;
  late final String _userId;

  /// Progress is kept on the phone, so an interrupted onboarding resumes.
  String get _draftKey => 'onboarding.draft.$_userId';

  SharedPreferences? get _prefs {
    try {
      return ref.read(sharedPrefsProvider);
    } on Object {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    final me = ref.read(meProvider);
    _userId = me.id;
    // Only the first name is pre-filled: it's shown to other players.
    _name = TextEditingController(text: me.displayName.trim().split(RegExp(r'\s+')).first);
    _goal = me.goal;
    _avatar = me.avatar;
    final restored = _restoreDraft();
    _pages = PageController(initialPage: _step);
    if (restored && _handle.text.isNotEmpty) {
      _onHandleChanged(_handle.text);
      return;
    }
    final suggestion = me.displayName.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    if (suggestion.length >= 3) {
      _handle.text = suggestion.substring(0, suggestion.length.clamp(3, 16));
      _onHandleChanged(_handle.text);
    }
  }

  bool _restoreDraft() {
    try {
      final raw = _prefs?.getString(_draftKey);
      if (raw == null) return false;
      if (jsonDecode(raw) case final Map<String, dynamic> draft) {
        _step = (draft['step'] as num? ?? 0).toInt().clamp(0, _steps - 1);
        if (draft['name'] case final String name when name.isNotEmpty) _name.text = name;
        if (draft['handle'] case final String handle) _handle.text = handle;
        if (draft['avatar'] != null) _avatar = Avatar.parse(draft['avatar']);
        _goal = Goal.parse(draft['goal']) ?? _goal;
        if (draft['birth_year'] case final String year) _birthYear.text = year;
        return true;
      }
    } on Object {
      // An unreadable draft just means starting over.
    }
    return false;
  }

  void _saveDraft() {
    final prefs = _prefs;
    if (prefs == null) return;
    unawaited(
      prefs.setString(
        _draftKey,
        jsonEncode({
          'step': _step,
          'name': _name.text,
          'handle': _handle.text,
          'avatar': _avatar.toJson(),
          'goal': _goal?.name,
          'birth_year': _birthYear.text,
        }),
      ),
    );
  }

  void _clearDraft() => unawaited(_prefs?.remove(_draftKey));

  Future<void> _switchAccount() async {
    _clearDraft();
    await ref.read(sessionProvider.notifier).signOut();
  }

  Future<void> _openLegal(String page) async {
    final base = ref.read(appEnvProvider).legalBaseUrl;
    try {
      await launchUrl(Uri.parse('$base/$page'), mode: LaunchMode.externalApplication);
    } on Object {
      if (mounted) showAppToast(context, 'Couldn\'t open that page.', icon: AppIcons.alert);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pages.dispose();
    _name.dispose();
    _handle.dispose();
    _birthYear.dispose();
    super.dispose();
  }

  void _onHandleChanged(String value) {
    _debounce?.cancel();
    setState(() {
      _handleStatus = null;
      _handleError = null;
      _checkingHandle = handlePattern.hasMatch(value);
    });
    if (!handlePattern.hasMatch(value)) {
      if (value.isNotEmpty) setState(() => _handleError = '3–20 letters, numbers or _');
      return;
    }
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

  int? get _parsedYear => int.tryParse(_birthYear.text.trim());

  bool get _stepValid => switch (_step) {
    0 => _name.text.trim().length >= 2 && _handleStatus == HandleStatus.available,
    1 => true,
    2 => _goal != null,
    _ => _parsedYear != null && _birthYear.text.trim().length == 4,
  };

  Future<void> _next() async {
    if (_step == 0 && _name.text.trim().length < 2) {
      setState(() => _nameError = 'Please enter at least 2 characters');
      return;
    }
    if (_step < _steps - 1) {
      _goTo(_step + 1);
      return;
    }
    final year = _parsedYear!;
    final now = DateTime.now().year;
    if (year > now - 10 && year <= now) {
      setState(() => _underAge = true);
      return;
    }
    if (year < now - 100 || year > now) {
      setState(() => _yearError = 'Please enter a year between ${now - 100} and ${now - 10}');
      return;
    }
    await _submit(year);
  }

  void _goTo(int step) {
    FocusScope.of(context).unfocus();
    setState(() => _step = step);
    _saveDraft();
    _pages.animateToPage(
      step,
      duration: AppMotion.of(context, AppMotion.page),
      curve: AppMotion.emphasized,
    );
  }

  Future<void> _submit(int year) async {
    setState(() => _submitting = true);
    try {
      final me = await ref
          .read(onboardingRepositoryProvider)
          .complete(
            displayName: _name.text.trim(),
            handle: _handle.text,
            avatar: _avatar,
            goal: _goal!,
            birthYear: year,
          );
      _clearDraft();
      await ref.read(sessionProvider.notifier).updateUser(me);
    } on ValidationFailure catch (failure) {
      if (!mounted) return;
      final fields = failure.fields;
      setState(() {
        _nameError = fields['display_name'];
        _handleError = fields['handle'];
        _yearError = fields['birth_year'];
        if (_handleError != null) _handleStatus = HandleStatus.taken;
      });
      if (_nameError != null || _handleError != null) _goTo(0);
      if (fields.isEmpty) showAppToast(context, failure.message, icon: AppIcons.alert);
    } on ConflictFailure catch (failure) {
      if (failure.code == 'ALREADY_ONBOARDED') {
        // An earlier attempt went through but its response was lost: carry on.
        _clearDraft();
        await ref.read(sessionProvider.notifier).refreshUser();
        return;
      }
      if (!mounted) return;
      setState(() {
        _handleStatus = HandleStatus.taken;
        _handleError = 'That username was just taken';
      });
      _goTo(0);
    } on AppFailure catch (failure) {
      if (mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.md,
                AppSpacing.gutter,
                0,
              ),
              child: Row(
                children: [
                  AnimatedOpacity(
                    opacity: _step > 0 ? 1 : 0,
                    duration: AppMotion.fast,
                    child: AppIconButton(
                      icon: AppIcons.back,
                      semanticLabel: 'Back',
                      onPressed: _step > 0 && !_submitting ? () => _goTo(_step - 1) : null,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: SegmentedProgress(total: _steps, completed: _step + 1),
                  ),
                  const SizedBox(width: AppSpacing.lg + AppSizes.iconButton),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _Step(
                    title: 'What should\nwe call you?',
                    subtitle: 'Friends find you by your username.',
                    child: Column(
                      children: [
                        AppTextField(
                          label: 'Name',
                          controller: _name,
                          maxLength: 30,
                          error: _nameError,
                          textInputAction: TextInputAction.next,
                          onChanged: (_) => setState(() => _nameError = null),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        AppTextField(
                          label: 'Username',
                          controller: _handle,
                          hint: 'e.g. aarav_27',
                          maxLength: 20,
                          error: _handleError,
                          helper: _handleStatus == HandleStatus.available
                              ? 'Nice — it\'s available'
                              : 'Letters, numbers and _',
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9_]')),
                            _LowerCaseFormatter(),
                          ],
                          onChanged: _onHandleChanged,
                          suffix: _HandleIndicator(
                            checking: _checkingHandle,
                            status: _handleStatus,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xl),
                        _SignedInAs(
                          email: ref.watch(meProvider).email,
                          onSwitch: _submitting ? null : _switchAccount,
                        ),
                      ],
                    ),
                  ),
                  _Step(
                    title: 'Pick your\navatar',
                    subtitle: 'You can change it any time.',
                    child: AvatarPicker(
                      value: _avatar,
                      onChanged: (a) => setState(() => _avatar = a),
                    ),
                  ),
                  _Step(
                    title: 'What are you\npreparing for?',
                    subtitle: 'We\'ll tailor subjects, battles and tournaments.',
                    child: Column(
                      children: [
                        for (final goal in Goal.values) ...[
                          _GoalTile(
                            goal: goal,
                            selected: _goal == goal,
                            onTap: () => setState(() => _goal = goal),
                          ),
                          const SizedBox(height: AppSpacing.md),
                        ],
                      ],
                    ),
                  ),
                  _Step(
                    title: 'When were\nyou born?',
                    subtitle: 'Only your birth year. We use it to keep younger players safe.',
                    child: _underAge
                        ? _UnderAge(
                            onEdit: () => setState(() {
                              _underAge = false;
                              _birthYear.clear();
                            }),
                            onSignOut: _switchAccount,
                          )
                        : AppTextField(
                            label: 'Birth year',
                            controller: _birthYear,
                            hint: 'e.g. 2008',
                            maxLength: 4,
                            error: _yearError,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.done,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            onChanged: (_) => setState(() => _yearError = null),
                          ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                0,
                AppSpacing.gutter,
                AppSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!_underAge)
                    AppButton(
                      label: _step == _steps - 1 ? 'Finish' : 'Continue',
                      trailingIcon: _step == _steps - 1 ? AppIcons.check : AppIcons.chevronRight,
                      loading: _submitting,
                      onPressed: _stepValid ? _next : null,
                    ),
                  if (_step == _steps - 1 && ref.watch(appEnvProvider).legalBaseUrl.isNotEmpty)
                    _LegalLinks(
                      onTerms: () => _openLegal('terms'),
                      onPrivacy: () => _openLegal('privacy'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignedInAs extends StatelessWidget {
  const _SignedInAs({required this.email, required this.onSwitch});

  final String? email;
  final VoidCallback? onSwitch;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return Row(
      children: [
        Expanded(
          child: Text(
            'Signed in as ${email ?? 'your Google account'}',
            style: text.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        AppButton(
          label: 'Switch account',
          variant: AppButtonVariant.ghost,
          size: AppButtonSize.small,
          expand: false,
          onPressed: onSwitch,
        ),
      ],
    );
  }
}

class _UnderAge extends StatelessWidget {
  const _UnderAge({required this.onEdit, required this.onSignOut});

  final VoidCallback onEdit;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      child: Column(
        children: [
          const EmptyState(
            icon: AppIcons.graduation,
            tone: PastelTone.lavender,
            title: 'Quiz Arena is for students aged 10 and up',
            message: 'Come back when you\'re a little older. Keep learning till then!',
          ),
          AppButton(label: 'Sign out', variant: AppButtonVariant.ink, onPressed: onSignOut),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'I typed the wrong year',
            variant: AppButtonVariant.ghost,
            onPressed: onEdit,
          ),
        ],
      ),
    );
  }
}

class _LegalLinks extends StatelessWidget {
  const _LegalLinks({required this.onTerms, required this.onPrivacy});

  final VoidCallback onTerms;
  final VoidCallback onPrivacy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('By finishing, you agree to the', style: context.text.caption),
          TextButton(onPressed: onTerms, child: const Text('Terms')),
          Text('and', style: context.text.caption),
          TextButton(onPressed: onPrivacy, child: const Text('Privacy policy')),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.title, required this.subtitle, required this.child});

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.xxxl,
        AppSpacing.gutter,
        AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.headlineLarge),
          const SizedBox(height: AppSpacing.sm),
          Text(subtitle, style: text.bodyMedium),
          const SizedBox(height: AppSpacing.xxl),
          child,
        ],
      ),
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

class _GoalTile extends StatelessWidget {
  const _GoalTile({required this.goal, required this.selected, required this.onTap});

  final Goal goal;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final pair = colors.pastel(goal == Goal.neet ? PastelTone.mint : PastelTone.peach);
    return Pressable(
      onPressed: onTap,
      selected: selected,
      semanticLabel: goal.label,
      pressedScale: 0.98,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: pair.container,
          borderRadius: AppRadii.tile,
          border: Border.all(color: selected ? colors.ink : Colors.transparent, width: 2),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: colors.isDark ? colors.surface : Colors.white,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: HugeIcon(
                goal == Goal.neet ? AppIcons.biology : AppIcons.maths,
                size: 26,
                color: pair.onContainer,
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(goal.label, style: text.titleLarge),
                  Text(goal.subjects, style: text.bodySmall.copyWith(color: pair.onContainer)),
                ],
              ),
            ),
            AnimatedOpacity(
              duration: AppMotion.fast,
              opacity: selected ? 1 : 0,
              child: HugeIcon(AppIcons.checkCircle, size: 26, color: colors.ink),
            ),
          ],
        ),
      ),
    );
  }
}

class _LowerCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toLowerCase());
}
