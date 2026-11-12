import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../app/router.dart';
import '../../core/network/app_failure.dart';
import '../../core/network/connectivity.dart';
import 'data/room_models.dart';
import 'data/rooms_repository.dart';
import 'room_code.dart';
import 'room_share.dart';
import 'room_text.dart';
import 'rooms_controller.dart';

/// The room behind a code, before joining (`GET /v1/rooms/code/{code}`). No automatic retry:
/// wrong codes are rate-limited.
final roomPreviewProvider = FutureProvider.autoDispose.family<RoomPreview, String>(
  (ref, code) => ref.watch(roomsRepositoryProvider).preview(code),
  retry: (_, _) => null,
);

/// Joining a room by code (`/battle/join?code=`): six boxes with paste, then a preview of the
/// room (host, subject, players) with the reason when it can't be joined, then **Join**. A room
/// link (`/j/<code>`) opens here with the code filled in, also after sign-in and onboarding.
class JoinRoomScreen extends ConsumerStatefulWidget {
  const JoinRoomScreen({super.key, this.code});

  final String? code;

  @override
  ConsumerState<JoinRoomScreen> createState() => _JoinRoomScreenState();
}

class _JoinRoomScreenState extends ConsumerState<JoinRoomScreen> {
  late final TextEditingController _input;
  String? _code;
  String? _inputError;
  bool _joining = false;
  String? _joinError;

  @override
  void initState() {
    super.initState();
    final code = widget.code == null ? null : RoomCode.normalize(widget.code!);
    _input = TextEditingController(text: code ?? '');
    _code = code;
    if (widget.code != null && code == null) _inputError = RoomText.codeNotActive;
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final code = RoomCode.normalize(raw);
    setState(() {
      _joinError = null;
      if (code == null) {
        _code = null;
        _inputError = 'Codes are 6 letters and numbers, like K7M2QX';
      } else {
        _code = code;
        _inputError = null;
      }
    });
  }

  Future<void> _paste() async {
    final text = await ref.read(roomPasteProvider)();
    if (!mounted) return;
    final code = text == null ? null : RoomCode.normalize(text);
    if (code == null) {
      showAppToast(context, 'There\'s no room code to paste', icon: AppIcons.info);
      return;
    }
    _input.text = code;
    _submit(code);
  }

  Future<void> _join(String code) async {
    final rooms = ref.read(roomsControllerProvider);
    if (rooms == null) {
      showAppToast(context, 'Still connecting. Try again in a moment.', icon: AppIcons.info);
      return;
    }
    setState(() {
      _joining = true;
      _joinError = null;
    });
    try {
      final view = await rooms.joinCode(code);
      if (mounted) context.go(view.route);
    } on RealtimeError catch (error) {
      // BUSY shows "Go there" on the live layer.
      if (mounted && error.code != RealtimeErrorCode.busy) {
        setState(() => _joinError = RoomText.joinError(error));
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final code = _code;
    final online = ref.watch(isOnlineProvider);
    return Scaffold(
      appBar: AppTopBar(
        title: 'Join a room',
        onBack: () => context.canPop() ? context.pop() : context.go(Routes.battle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.sm,
          AppSpacing.gutter,
          AppSpacing.xxl,
        ),
        children: [
          Text('Enter the 6-character code your friend shared.', style: text.bodyMedium),
          const SizedBox(height: AppSpacing.lg),
          CodeInput(
            controller: _input,
            autofocus: widget.code == null,
            error: _inputError,
            onChanged: (_) {
              if (_code != null || _inputError != null) {
                setState(() {
                  _code = null;
                  _inputError = null;
                  _joinError = null;
                });
              }
            },
            onCompleted: _submit,
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              label: 'Paste',
              size: AppButtonSize.small,
              variant: AppButtonVariant.ghost,
              leadingIcon: AppIcons.document,
              expand: false,
              onPressed: _paste,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (!online)
            const OfflineBanner(
              visible: true,
              message: 'You\'re offline · joining needs a connection',
            )
          else if (code != null)
            _Preview(code: code, joining: _joining, error: _joinError, onJoin: () => _join(code)),
        ],
      ),
    );
  }
}

class _Preview extends ConsumerWidget {
  const _Preview({
    required this.code,
    required this.joining,
    required this.error,
    required this.onJoin,
  });

  final String code;
  final bool joining;
  final String? error;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(roomPreviewProvider(code));
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.medium),
      child: switch (preview) {
        AsyncValue(:final value?) => _PreviewCard(
          key: ValueKey(code),
          preview: value,
          joining: joining,
          error: error,
          onJoin: onJoin,
        ),
        AsyncValue(:final error?) => ErrorState(
          key: const ValueKey('error'),
          compact: true,
          title: error is NotFoundFailure ? 'No room with that code' : 'Couldn\'t check the code',
          message: error is AppFailure
              ? RoomText.failure(error)
              : 'Check your connection and try again.',
          retrying: preview.isLoading,
          onRetry: error is NotFoundFailure
              ? null
              : () => ref.invalidate(roomPreviewProvider(code)),
        ),
        _ => const Shimmer(
          key: ValueKey('loading'),
          child: SkeletonBox(height: 180, radius: AppRadii.lg),
        ),
      },
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    super.key,
    required this.preview,
    required this.joining,
    required this.error,
    required this.onJoin,
  });

  final RoomPreview preview;
  final bool joining;
  final String? error;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final host = preview.host;
    final chapters = preview.chapters.isEmpty ? 'All chapters' : preview.chapters.join(', ');
    final details = [
      if (preview.subject != null) RoomText.subject(preview.subject),
      chapters,
      if (preview.questions != null) '${preview.questions} questions',
      if (preview.seconds != null) '${preview.seconds} s each',
    ];
    final capacity = preview.capacity;
    final reason = preview.joinable ? null : (preview.reason ?? JoinBlock.unknown);
    return SurfaceCard(
      elevated: true,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppAvatar(data: host.avatar.toData(), size: 48),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${host.displayName}\'s room', style: text.titleLarge),
                    Text(
                      '${preview.kind.label} · ${capacity == null ? '${preview.members} in' : '${preview.members}/$capacity players'}',
                      style: text.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final detail in details)
                InfoChip(label: detail, background: colors.surfaceMuted),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (reason != null)
            Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: colors.warningContainer,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                ),
                child: Text(
                  reason.message,
                  style: text.labelMedium.copyWith(color: colors.onWarningContainer),
                ),
              ),
            )
          else ...[
            if (error case final error?) ...[
              Text(
                error,
                style: text.labelMedium.copyWith(color: colors.onErrorContainer),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            AppButton(
              label: 'Join room',
              trailingIcon: AppIcons.chevronRight,
              loading: joining,
              onPressed: joining ? null : onJoin,
            ),
          ],
        ],
      ),
    );
  }
}
