import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../icons/app_icons.dart';
import '../icons/huge_icon.dart';
import '../theme/app_theme.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';
import 'pressable.dart';

/// Pill search field with a clear button (reference 2).
class AppSearchField extends StatefulWidget {
  const AppSearchField({
    super.key,
    this.controller,
    this.hint = 'Search',
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.trailing,
  });

  final TextEditingController? controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final Widget? trailing;

  @override
  State<AppSearchField> createState() => _AppSearchFieldState();
}

class _AppSearchFieldState extends State<AppSearchField> {
  TextEditingController? _owned;

  TextEditingController get _controller =>
      widget.controller ?? (_owned ??= TextEditingController());

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    return Container(
      height: AppSizes.buttonMedium + 4,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppRadii.pillAll,
        border: Border.all(color: colors.outline),
      ),
      padding: const EdgeInsets.only(left: 18, right: 6),
      child: Row(
        children: [
          HugeIcon(AppIcons.search, size: 20, color: colors.inkMuted),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: widget.autofocus,
              onChanged: (value) {
                setState(() {});
                widget.onChanged?.call(value);
              },
              onSubmitted: widget.onSubmitted,
              textInputAction: TextInputAction.search,
              style: text.bodyLarge,
              decoration: InputDecoration(
                hintText: widget.hint,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isCollapsed: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.fast),
            child: _controller.text.isEmpty
                ? (widget.trailing ?? const SizedBox(width: 12))
                : Pressable(
                    onPressed: () {
                      _controller.clear();
                      setState(() {});
                      widget.onChanged?.call('');
                    },
                    semanticLabel: 'Clear search',
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: HugeIcon(AppIcons.close, size: 20, color: colors.inkMuted),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Labeled text field with helper/error text below.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.helper,
    this.error,
    this.onChanged,
    this.maxLength,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.suffix,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? helper;
  final String? error;
  final ValueChanged<String>? onChanged;
  final int? maxLength;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final Widget? suffix;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: AppSpacing.sm),
          child: Text(label, style: text.labelMedium),
        ),
        TextField(
          controller: controller,
          onChanged: onChanged,
          maxLength: maxLength,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          inputFormatters: inputFormatters,
          autofocus: autofocus,
          style: text.bodyLarge,
          decoration: InputDecoration(
            hintText: hint,
            helperText: error == null ? helper : null,
            errorText: error,
            counterText: '',
            suffixIcon: suffix,
          ),
        ),
      ],
    );
  }
}

/// Fixed-length code entry (e.g. a 6-character room code). Accepts paste and
/// normalizes to uppercase letters and digits.
class CodeInput extends StatefulWidget {
  const CodeInput({
    super.key,
    this.length = 6,
    this.onCompleted,
    this.onChanged,
    this.error,
    this.autofocus = true,
  });

  final int length;
  final ValueChanged<String>? onCompleted;
  final ValueChanged<String>? onChanged;
  final String? error;
  final bool autofocus;

  @override
  State<CodeInput> createState() => _CodeInputState();
}

class _CodeInputState extends State<CodeInput> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() {});
    widget.onChanged?.call(value);
    if (value.length == widget.length) widget.onCompleted?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final value = _controller.text;
    final hasError = widget.error != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            Row(
              children: [
                for (var i = 0; i < widget.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AnimatedContainer(
                      duration: AppMotion.fast,
                      height: 60,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        border: Border.all(
                          width: 1.5,
                          color: hasError
                              ? colors.error
                              : (_focus.hasFocus && i == value.length.clamp(0, widget.length - 1))
                              ? colors.ink
                              : colors.outline,
                        ),
                      ),
                      child: Text(
                        i < value.length ? value[i] : '',
                        style: text.numericLarge.copyWith(fontSize: 24),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            Positioned.fill(
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  maxLength: widget.length,
                  showCursor: false,
                  enableInteractiveSelection: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  keyboardType: TextInputType.visiblePassword,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                    _UpperCaseFormatter(),
                  ],
                  onChanged: _onChanged,
                  decoration: const InputDecoration(counterText: ''),
                ),
              ),
            ),
          ],
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm, left: 4),
            child: Text(
              widget.error!,
              style: text.caption.copyWith(color: colors.onErrorContainer),
            ),
          ),
      ],
    );
  }
}

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}
