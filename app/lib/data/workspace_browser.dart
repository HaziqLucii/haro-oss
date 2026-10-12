import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/models.dart';
import 'workspace_store.dart';

/// The workspace's shared browser (a Playwright MCP server haro keeps up between agent runs). Read
/// when the rail shows it and again every few seconds while it is shown, since the server can end
/// on its own and no event says so. A read that fails shows it as off: the rail never claims a
/// browser it could not confirm.
final workspaceBrowserProvider = FutureProvider.autoDispose
    .family<BrowserState, String>((ref, id) async {
      final timer = Timer(const Duration(seconds: 8), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      try {
        return await ref.read(haroApiProvider).getBrowser(id);
      } catch (_) {
        return BrowserState.off;
      }
    });
