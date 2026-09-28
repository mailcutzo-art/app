import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

/// Opens the system share sheet with [text]. Tests replace it.
final roomShareProvider = Provider<Future<void> Function(String text, {String? subject})>(
  (ref) =>
      (text, {subject}) => SharePlus.instance.share(ShareParams(text: text, subject: subject)),
);

/// Puts [text] on the clipboard. Tests replace it.
final roomClipboardProvider = Provider<Future<void> Function(String text)>(
  (ref) =>
      (text) => Clipboard.setData(ClipboardData(text: text)),
);

/// Reads text from the clipboard, for pasting a code. Tests replace it.
final roomPasteProvider = Provider<Future<String?> Function()>(
  (ref) =>
      () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text,
);
