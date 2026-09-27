import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/auth/user.dart';
import '../../core/network/app_failure.dart';
import 'onboarding_repository.dart';

/// Four short steps: name and handle, avatar, goal, birth year.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _steps = 4;

  final _pages = PageController();
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
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final me = ref.read(meProvider);
    _name = TextEditingController(text: me.displayName);
    _goal = me.goal;
    _avatar = me.avatar;
    final suggestion = me.displayName.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    if (suggestion.length >= 3) {
      _handle.text = suggestion.substring(0, suggestion.length.clamp(3, 16));
      _onHandleChanged(_handle.text);
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
    if (year < now - 100 || year > now - 10) {
      setState(() => _yearError = 'Please enter a year between ${now - 100} and ${now - 10}');
      return;
    }
    await _submit(year);
  }

  void _goTo(int step) {
    FocusScope.of(context).unfocus();
    setState(() => _step = step);
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
    } on ConflictFailure {
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
                      ],
                    ),
                  ),
                  _Step(
                    title: 'Pick your\navatar',
                    subtitle: 'You can change it any time.',
                    child: _AvatarPicker(
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
                    child: AppTextField(
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
              child: AppButton(
                label: _step == _steps - 1 ? 'Finish' : 'Continue',
                trailingIcon: _step == _steps - 1 ? AppIcons.check : AppIcons.chevronRight,
                loading: _submitting,
                onPressed: _stepValid ? _next : null,
              ),
            ),
          ],
        ),
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

class _AvatarPicker extends StatelessWidget {
  const _AvatarPicker({required this.value, required this.onChanged});

  final Avatar value;
  final ValueChanged<Avatar> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      children: [
        AppAvatar(data: value.toData(), size: 112, ring: true),
        const SizedBox(height: AppSpacing.xl),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final tone in Avatar.tones)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: Pressable(
                    onPressed: () => onChanged(Avatar(tone: tone, symbol: value.symbol)),
                    semanticLabel: '$tone color',
                    selected: value.tone == tone,
                    child: AnimatedContainer(
                      duration: AppMotion.fast,
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colors.pastel(PastelTone.values.byName(tone)).container,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: value.tone == tone ? colors.ink : colors.outline,
                          width: value.tone == tone ? 2.5 : 1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        GridView.count(
          crossAxisCount: 6,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppSpacing.sm,
          crossAxisSpacing: AppSpacing.sm,
          children: [
            for (final MapEntry(key: symbol, value: icon) in Avatar.symbols.entries)
              Pressable(
                onPressed: () => onChanged(Avatar(tone: value.tone, symbol: symbol)),
                semanticLabel: symbol,
                selected: value.symbol == symbol,
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  decoration: BoxDecoration(
                    color: value.symbol == symbol ? colors.inverse : colors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.outline),
                  ),
                  alignment: Alignment.center,
                  child: HugeIcon(
                    icon,
                    size: 22,
                    color: value.symbol == symbol ? colors.onInverse : colors.ink,
                  ),
                ),
              ),
          ],
        ),
      ],
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
