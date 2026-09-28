import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../social/data/social_models.dart';
import '../social/data/social_repository.dart';
import '../social/social_providers.dart';
import 'share_card.dart';
import 'share_models.dart';

/// Draws [data]'s card and returns it as a PNG.
typedef CaptureShareCard = Future<Uint8List> Function(BuildContext context, ShareCardData data);

/// Hands [image] and [text] to the system share sheet. [origin] anchors the sheet on tablets.
typedef ShareToApps = Future<void> Function({
  required Uint8List image,
  required String text,
  Rect? origin,
});

/// How share cards become images; tests swap it for a stand-in.
final captureShareCardProvider = Provider<CaptureShareCard>((ref) => captureShareCard);

/// How images reach other apps; tests swap it for a recorder.
final shareToAppsProvider = Provider<ShareToApps>((ref) => shareImageToApps);

/// Posts shares to the user's friends' activity.
final shareActionsProvider = Provider<ShareActions>(ShareActions.new);

class ShareActions {
  ShareActions(this._ref);

  final Ref _ref;

  /// `POST /v1/me/activity/shares`, then the feed reloads so the post shows.
  Future<ActivityItem> postToFriends(ShareTarget target, {required String idempotencyKey}) async {
    final item = await _ref
        .read(socialRepositoryProvider)
        .share(target, idempotencyKey: idempotencyKey);
    _ref.invalidate(activityProvider);
    return item;
  }
}

/// Renders [data]'s full card off-screen at [ShareCard.pixelRatio] (1080 × 1350) and encodes
/// it as PNG. The card is always drawn in the light theme, the brand's look.
///
/// It is laid out in the root overlay, out of sight to the left of the screen and hidden from
/// hit testing and screen readers, for one frame.
Future<Uint8List> captureShareCard(BuildContext context, ShareCardData data) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final media = MediaQuery.of(context);
  final boundaryKey = GlobalKey();
  final entry = OverlayEntry(
    builder: (_) => Positioned(
      left: -shareCardSize.width * 3,
      top: 0,
      width: shareCardSize.width,
      height: shareCardSize.height,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: MediaQuery(
            data: media.copyWith(
              size: shareCardSize,
              textScaler: TextScaler.noScaling,
              disableAnimations: true,
            ),
            child: Theme(
              data: AppTheme.light(),
              child: RepaintBoundary(
                key: boundaryKey,
                child: Material(
                  type: MaterialType.transparency,
                  child: ShareCard(data: data),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  try {
    await WidgetsBinding.instance.endOfFrame;
    final boundary = boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) throw StateError('share card was not laid out');
    final image = await boundary.toImage(pixelRatio: ShareCard.pixelRatio);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('share card could not be encoded');
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    entry.remove();
  }
}

/// Writes [image] to a temporary PNG and opens the system share sheet with it and [text].
Future<void> shareImageToApps({
  required Uint8List image,
  required String text,
  Rect? origin,
}) async {
  final directory = await getTemporaryDirectory();
  final file = File('${directory.path}/quiz-arena-${DateTime.now().millisecondsSinceEpoch}.png');
  await file.writeAsBytes(image, flush: true);
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'image/png', name: 'quiz-arena.png')],
      text: text,
      sharePositionOrigin: origin,
    ),
  );
}
