import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import 'data/home_models.dart';
import 'data/home_repository.dart';

/// `GET /v1/home`. Refreshing keeps the sections on screen until the new
/// answer arrives.
final homeProvider = FutureProvider.autoDispose<HomeFeed>((ref) {
  // Someone else signing in on this phone gets their own Home.
  ref.watch(currentUserIdProvider);
  return ref.watch(homeRepositoryProvider).home();
}, retry: (_, _) => null);
