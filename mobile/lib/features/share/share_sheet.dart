import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/env.dart';
import '../../core/network/app_failure.dart';
import '../../core/utils/ids.dart';
import 'share_card.dart';
import 'share_models.dart';
import 'share_providers.dart';

/// Opens the share sheet for [data]: a preview of the card, **Post to friends** (the in-app
/// activity feed) and **Share to other apps** (the system share sheet with the card as an
/// image). Resolves once the sheet is closed.
Future<void> showShareSheet(BuildContext context, {required ShareCardData data}) =>
    showAppSheet<void>(
      context,
      builder: (sheetContext) => _ShareSheet(data: data, host: context),
    );

class _ShareSheet extends ConsumerStatefulWidget {
  const _ShareSheet({required this.data, required this.host});

  final ShareCardData data;

  /// Where the "Posted" toast shows once the sheet has closed.
  final BuildContext host;

  @override
  ConsumerState<_ShareSheet> createState() => _ShareSheetState();
}

enum _Busy { none, posting, sharing }

class _ShareSheetState extends ConsumerState<_ShareSheet> {
  final _shareButtonKey = GlobalKey();
  _Busy _busy = _Busy.none;
  String? _error;

  /// Kept while a post may have reached the server, so a retry doesn't post twice.
  String? _postKey;

  Future<void> _post() async {
    setState(() {
      _busy = _Busy.posting;
      _error = null;
    });
    final key = _postKey ??= randomHexId();
    try {
      await ref.read(shareActionsProvider).postToFriends(widget.data.target, idempotencyKey: key);
    } on AppFailure catch (failure) {
      if (!failure.isRetryable) _postKey = null;
      if (!mounted) return;
      setState(() {
        _busy = _Busy.none;
        _error = _postError(failure);
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    if (widget.host.mounted) {
      showAppToast(widget.host, 'Posted to your friends', icon: AppIcons.checkCircle);
    }
  }

  String _postError(AppFailure failure) => switch (failure.code) {
    'LIMIT_REACHED' => 'You\'ve posted your progress 3 times today. Try again tomorrow.',
    'ALREADY_SHARED' => 'You\'ve already posted this battle to your friends.',
    'NOT_FOUND' => 'This battle can\'t be posted right now.',
    _ => failure.message,
  };

  Future<void> _shareToApps() async {
    setState(() {
      _busy = _Busy.sharing;
      _error = null;
    });
    final box = _shareButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
    final caption = widget.data.captionWithLink(ref.read(appEnvProvider).shareBaseUrl);
    try {
      final image = await ref.read(captureShareCardProvider)(context, widget.data);
      await ref.read(shareToAppsProvider)(image: image, text: caption, origin: origin);
    } on Object catch (error) {
      debugPrint('Sharing failed: $error');
      if (!mounted) return;
      setState(() {
        _busy = _Busy.none;
        _error = 'Couldn\'t share the image. Please try again.';
      });
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final data = widget.data;
    final idle = _busy == _Busy.none;
    return SheetScaffold(
      title: data is MatchShareData ? 'Share this battle' : 'Share your progress',
      subtitle: 'Post it to your friends, or send the card to other apps.',
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error case final error?) ...[
            Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  HugeIcon(AppIcons.alert, size: 18, color: colors.error),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(error, style: text.bodySmall.copyWith(color: colors.error)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          AppButton(
            label: 'Post to friends',
            leadingIcon: AppIcons.social,
            loading: _busy == _Busy.posting,
            onPressed: idle ? _post : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            key: _shareButtonKey,
            label: 'Share to other apps',
            leadingIcon: AppIcons.share,
            variant: AppButtonVariant.secondary,
            loading: _busy == _Busy.sharing,
            onPressed: idle ? _shareToApps : null,
          ),
        ],
      ),
      child: Center(child: SharePreview(data: data)),
    );
  }
}

/// The full card scaled down to [height], as it will look when shared (light theme).
class SharePreview extends StatelessWidget {
  const SharePreview({super.key, required this.data, this.height = 240});

  final ShareCardData data;
  final double height;

  @override
  Widget build(BuildContext context) {
    final width = height * shareCardSize.width / shareCardSize.height;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        boxShadow: AppShadows.floating(context.colors),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        child: FittedBox(
          child: MediaQuery.withNoTextScaling(
            child: Theme(
              data: AppTheme.light(),
              child: ShareCard(data: data),
            ),
          ),
        ),
      ),
    );
  }
}
