import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/workspace_store.dart';
import 'lsp_client.dart';
import 'lsp_diagnostics.dart';

/// The workspace's one language-server client. The backend spawns a server per socket, so
/// nothing else may open `/lsp`. Nothing connects until the first TS/JS buffer opens a
/// document; the client goes with the workspace.
final lspClientProvider = Provider.family<LspClient, String>((ref, id) {
  // Watching the path rebuilds an unusable client (no worktree known yet) once it exists.
  final root = ref.watch(
    workspaceStoreProvider.select(
      (s) =>
          s.all.where((w) => w.id == id).map((w) => w.worktreePath).firstOrNull,
    ),
  );
  final client = LspClient(
    connect: () => ref.read(haroWsProvider).lsp(id),
    rootPath: root ?? '',
  );
  ref.onDispose(client.dispose);
  return client;
});

/// The open TS/JS files' diagnostics for the Problems tab. Rebuilds on the client's debounced
/// feed; empty while the client is idle or unavailable.
final lspDiagnosticsProvider = Provider.autoDispose
    .family<List<FileDiagnostics>, String>((ref, id) {
      final client = ref.watch(lspClientProvider(id));
      void changed() => ref.invalidateSelf();
      client.diagnosticsFeed.addListener(changed);
      ref.onDispose(() => client.diagnosticsFeed.removeListener(changed));
      return client.diagnosticsByPath();
    });
