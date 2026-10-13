import 'package:flutter/material.dart';

import '../../api/models/models.dart';
import '../../theme/haro_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/haro_pressable.dart';
import '../../widgets/haro_tag.dart';
import '../../widgets/shell_icons.dart';
import '../new_workspace/creation_widgets.dart';
import 'notes_model.dart';

String fileSizeText(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// One file beside the notes: its kind as a Lucide icon, its name, where it is. Pressing it opens
/// it with the system's own app.
class NoteFileRow extends StatelessWidget {
  const NoteFileRow({
    super.key,
    required this.file,
    required this.onOpen,
    this.onMenu,
  });

  final NoteFile file;
  final VoidCallback onOpen;
  final ValueChanged<Offset>? onMenu;

  @override
  Widget build(BuildContext context) {
    final folder = file.path.contains('/')
        ? file.path.substring(0, file.path.lastIndexOf('/'))
        : '';
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: onMenu == null
          ? null
          : (d) => onMenu!(d.globalPosition),
      child: HaroPressable(
        onTap: onOpen,
        tooltip: 'Open ${file.name} with your default app',
        semanticLabel: 'Open ${file.name}',
        builder: (context, hovered) => Container(
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: hovered ? HaroTokens.raised : HaroTokens.transparent,
            borderRadius: BorderRadius.circular(HaroTokens.radius),
          ),
          child: Row(
            children: [
              ShellIconView(
                fileIconFor(file.kind),
                size: 16,
                color: hovered ? HaroTokens.ink : HaroTokens.ink66,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HaroText.ui(size: 13, color: HaroTokens.ink86),
                    ),
                    if (folder.isNotEmpty)
                      Text(
                        folder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HaroText.mono(
                          size: 10,
                          tracking: 0,
                          color: HaroTokens.ink42,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                fileSizeText(file.size),
                maxLines: 1,
                style: HaroText.mono(
                  size: 10,
                  tracking: 0,
                  color: HaroTokens.ink42,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The "Files" group under the note list: a header with the count that folds it, then a row per
/// file.
class NoteFilesSection extends StatelessWidget {
  const NoteFilesSection({
    super.key,
    required this.files,
    required this.open,
    required this.onToggle,
    required this.onOpen,
    this.onMenu,
  });

  final List<NoteFile> files;
  final bool open;
  final VoidCallback onToggle;
  final ValueChanged<NoteFile> onOpen;
  final void Function(NoteFile file, Offset at)? onMenu;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('notes-files'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      HaroPressable(
        key: const Key('notes-files-toggle'),
        onTap: onToggle,
        semanticLabel: open ? 'Hide the files' : 'Show the files',
        builder: (context, hovered) => Padding(
          padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
          child: Row(
            children: [
              ShellIconView(
                open ? ShellIcon.chevronDown : ShellIcon.chevronRight,
                size: 13,
                color: hovered ? HaroTokens.ink : HaroTokens.ink42,
              ),
              const SizedBox(width: 6),
              MonoCaption('FILES', count: files.length),
            ],
          ),
        ),
      ),
      if (open)
        for (final f in files)
          NoteFileRow(
            key: Key('notes-file-${f.path}'),
            file: f,
            onOpen: () => onOpen(f),
            onMenu: onMenu == null ? null : (at) => onMenu!(f, at),
          ),
    ],
  );
}

/// An Obsidian note's leading properties block, as a quiet key and value list above the text.
class NoteProperties extends StatelessWidget {
  const NoteProperties(this.props, {super.key});

  final List<(String, String)> props;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('notes-properties'),
    margin: const EdgeInsets.only(bottom: 18),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: HaroTokens.panel,
      border: Border.all(color: HaroTokens.line12),
      borderRadius: BorderRadius.circular(HaroTokens.radius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (k, v) in props)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 130, child: MonoCaption(k)),
                Expanded(
                  child: Text(
                    v,
                    style: HaroText.ui(size: 13, color: HaroTokens.ink86),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// The files the open note links or embeds, under its text, each a button that opens it.
class LinkedFilesPanel extends StatelessWidget {
  const LinkedFilesPanel({
    super.key,
    required this.files,
    required this.onOpen,
  });

  final List<NoteFile> files;
  final ValueChanged<NoteFile> onOpen;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('notes-linked-files'),
    margin: const EdgeInsets.only(top: 22),
    padding: const EdgeInsets.only(top: 14),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: HaroTokens.line08)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: MonoCaption('FILES IN THIS NOTE', count: files.length),
        ),
        const SizedBox(height: 6),
        for (final f in files)
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: NoteFileRow(
                key: Key('notes-linked-file-${f.path}'),
                file: f,
                onOpen: () => onOpen(f),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Inline `HaroTag` re-export so callers that only need a tag of a file kind do not import twice.
Widget fileKindTag(String kind) => HaroTag(kind);
