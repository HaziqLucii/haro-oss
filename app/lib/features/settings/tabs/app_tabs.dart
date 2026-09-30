import 'dart:io';

import 'package:flutter/material.dart';

import '../../../api/models/models.dart';
import '../../../overlays/xp_rules_popover.dart';
import '../../../shortcuts/app_commands.dart';
import '../../open_in/editors_provider.dart' show availableEditors;
import '../../../theme/haro_theme.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/haro_button.dart';
import '../controls/code_font_preview.dart';
import '../controls/density_preview.dart';
import '../controls/grain_preview.dart';
import '../controls/meter.dart';
import '../controls/segmented.dart';
import '../controls/select.dart';
import '../controls/toggle.dart';
import '../device_prefs.dart';
import '../settings_controller.dart';
import '../settings_logic.dart';
import '../settings_scope.dart';
import '../settings_section.dart';
import '../settings_tab_spec.dart';

SettingsTabSpec displayTab(SettingsController c) {
  final s = c.config<DisplayPrefs>(SettingsTab.display);
  void set(DisplayPrefs Function(DisplayPrefs) f) => s.edit(f);
  return SettingsTabSpec(
    tab: SettingsTab.display,
    title: 'Display',
    intro: 'One theme, dark only. These change type, density and texture; code may use a muted syntax palette.',
    scope: SettingsScope.device,
    rows: [
      SettingRowSpec(
        id: 'coding_font',
        label: 'Coding font',
        help: 'Editor, diff and terminal',
        control: (_) => SettingSegmented<String>(
          options: [for (final f in DisplayPrefs.fontOptions) (f, f)],
          value: s.draft.codingFont,
          onChanged: (v) => set((d) => d.copyWith(codingFont: v)),
        ),
      ),
      SettingRowSpec(
        id: 'syntax_colour',
        label: 'Syntax colours',
        help: 'Muted colours in code, never green, red or lilac',
        control: (_) => SettingSegmented<bool>(
          options: const [(true, 'Colour'), (false, 'Monochrome')],
          value: s.draft.syntaxColour,
          onChanged: (v) => set((d) => d.copyWith(syntaxColour: v)),
        ),
      ),
      SettingRowSpec(
        id: 'coding_font_preview',
        label: 'Preview',
        help: 'Follows your font and colour pick before you save',
        stacked: true,
        control: (_) => CodeFontPreview(
          font: s.draft.codingFont,
          syntaxColour: s.draft.syntaxColour,
        ),
      ),
      SettingRowSpec(
        id: 'density',
        label: 'Density',
        help: 'Row height in lists and triage',
        control: (_) => SettingSegmented<String>(
          options: [for (final d in DisplayPrefs.densityOptions) (d, cap(d))],
          value: s.draft.density,
          onChanged: (v) => set((d) => d.copyWith(density: v)),
        ),
      ),
      SettingRowSpec(
        id: 'density_preview',
        label: 'Preview',
        help: 'Sidebar rows at this density',
        stacked: true,
        control: (_) => DensityPreview(density: s.draft.density),
      ),
      SettingRowSpec(
        id: 'film_grain',
        label: 'Film grain',
        help: 'The subtle texture on the canvas',
        control: (_) => SettingToggle(
          value: s.draft.filmGrain,
          semanticLabel: 'Film grain',
          onChanged: (v) => set((d) => d.copyWith(filmGrain: v)),
        ),
      ),
      SettingRowSpec(
        id: 'film_grain_preview',
        label: 'Preview',
        help: 'The canvas texture, on or off',
        stacked: true,
        control: (_) => GrainPreview(on: s.draft.filmGrain),
      ),
      _editorRow(c, () => s.draft.preferredEditor, (id) {
        set((d) => d.copyWith(preferredEditor: id));
      }),
    ],
  );
}

SettingsTabSpec editorTab(SettingsController c) {
  final s = c.config<EditorPrefs>(SettingsTab.editor);
  void set(EditorPrefs Function(EditorPrefs) f) => s.edit(f);
  return SettingsTabSpec(
    tab: SettingsTab.editor,
    title: 'Editor',
    intro: 'How the code step draws a file. The font itself is under Display.',
    scope: SettingsScope.device,
    rows: [
      SettingRowSpec(
        id: 'editor_font_size',
        label: 'Font size',
        help: 'Code editor text, in pixels',
        control: (_) => SettingSegmented<int>(
          options: [for (final n in EditorPrefs.fontSizes) (n, '$n')],
          value: s.draft.fontSize,
          onChanged: (v) => set((d) => d.copyWith(fontSize: v)),
        ),
      ),
      SettingRowSpec(
        id: 'editor_minimap',
        label: 'Minimap',
        help: 'Overview of the file on the right edge',
        control: (_) => SettingToggle(
          value: s.draft.minimap,
          semanticLabel: 'Minimap',
          onChanged: (v) => set((d) => d.copyWith(minimap: v)),
        ),
      ),
    ],
  );
}

SettingRowSpec _editorRow(
  SettingsController c,
  String Function() value,
  ValueChanged<String> onPick,
) {
  final editors = c.editors;
  final found = availableEditors(editors.original ?? const []);
  final String help;
  if (editors.state == SectionLoad.error) {
    help = editors.loadError ?? 'Could not detect editors';
  } else if (!editors.loaded) {
    help = 'Detecting editors…';
  } else if (found.isEmpty) {
    help = 'No editors found on this machine';
  } else {
    help = 'Used by Open in…';
  }
  final usable = editors.loaded && found.isNotEmpty;
  return SettingRowSpec(
    id: 'editor',
    label: 'Preferred editor',
    help: help,
    control: (_) {
      final current = value();
      return SettingSelect<String>(
        options: [
          (DisplayPrefs.askEditor, 'Ask every time'),
          if (usable)
            for (final e in found) (e.id, e.label),
        ],
        value: current,
        fallbackLabel: current == DisplayPrefs.askEditor
            ? null
            : usable
            ? '$current (not found)'
            : current,
        onChanged: usable ? onPick : null,
      );
    },
  );
}

SettingsTabSpec xpTab(SettingsController c) {
  final s = c.config<XpPrefs>(SettingsTab.xp);
  void set(XpPrefs Function(XpPrefs) f) => s.edit(f);
  return SettingsTabSpec(
    tab: SettingsTab.xp,
    title: 'XP',
    intro: 'A rank, a streak and small rewards for using haro. Turning it off only hides it; the backend still keeps score.',
    scope: SettingsScope.device,
    rows: [
      SettingRowSpec(
        id: 'show_xp',
        label: 'Show XP',
        help: 'Sidebar footer, level badge, reward toasts and the triage nudge',
        control: (_) => SettingToggle(
          value: s.draft.showXp,
          semanticLabel: 'Show XP',
          onChanged: (v) => set((d) => d.copyWith(showXp: v)),
        ),
      ),
      SettingRowSpec(
        id: 'streak_reminder',
        label: 'Streak reminder',
        help: 'A nudge in triage when today has no merge written by hand',
        control: (_) => SettingToggle(
          value: s.draft.streakReminder,
          semanticLabel: 'Streak reminder',
          onChanged: (v) => set((d) => d.copyWith(streakReminder: v)),
        ),
      ),
      SettingRowSpec(
        id: 'how_xp_works',
        label: 'How XP works',
        help: 'What earns XP in each mode, and what never does',
        control: (context) => HaroButton(
          key: const ValueKey('xp-how'),
          label: 'Open',
          height: 30,
          onPressed: () => showHowXpWorks(context, loadRules: c.api.getXpRules),
        ),
      ),
    ],
  );
}

SettingsTabSpec notificationsTab(SettingsController c) {
  final s = c.config<NotificationPrefs>(SettingsTab.notifications);
  void set(NotificationPrefs Function(NotificationPrefs) f) => s.edit(f);
  return SettingsTabSpec(
    tab: SettingsTab.notifications,
    title: 'Notifications',
    intro: 'How haro gets your attention when a workspace changes state.',
    scope: SettingsScope.device,
    rows: [
      SettingRowSpec(
        id: 'sound_on_finish',
        label: 'Sound when an agent finishes',
        help: 'Any workspace, not just the open one',
        control: (_) => SettingToggle(
          value: s.draft.soundOnFinish,
          semanticLabel: 'Sound when an agent finishes',
          onChanged: (v) => set((d) => d.copyWith(soundOnFinish: v)),
        ),
      ),
      SettingRowSpec(
        id: 'sound',
        label: 'Sound',
        help: 'The tone that plays',
        control: (_) => SettingSegmented<String>(
          options: [for (final v in NotificationPrefs.soundOptions) (v, v)],
          value: s.draft.sound,
          onChanged: (v) => set((d) => d.copyWith(sound: v)),
        ),
      ),
      SettingRowSpec(
        id: 'desktop',
        label: 'Desktop notification',
        help: 'Gate result and agent done, even when haro is in the background',
        control: (_) => SettingToggle(
          value: s.draft.desktop,
          semanticLabel: 'Desktop notification',
          onChanged: (v) => set((d) => d.copyWith(desktop: v)),
        ),
      ),
      SettingRowSpec(
        id: 'quiet_on_green',
        label: 'Stay quiet on green',
        help: 'Only interrupt for red gates and plans to approve',
        control: (_) => SettingToggle(
          value: s.draft.quietOnGreen,
          semanticLabel: 'Stay quiet on green',
          onChanged: (v) => set((d) => d.copyWith(quietOnGreen: v)),
        ),
      ),
      SettingRowSpec(
        id: 'toast_position',
        label: 'Toast position',
        help: 'Where messages appear',
        control: (_) => SettingSelect<String>(
          options: [
            for (final e in NotificationPrefs.toastPositions.entries)
              (e.key, e.value),
          ],
          value: s.draft.toastPosition,
          onChanged: (v) => set((d) => d.copyWith(toastPosition: v)),
        ),
      ),
      SettingRowSpec(
        id: 'toast_seconds',
        label: 'Toast duration',
        help: 'How long a message stays before it fades out',
        control: (_) => SettingSelect<int>(
          options: [
            for (final n in {
              ...NotificationPrefs.toastDurations,
              s.draft.toastSeconds,
            }.toList()..sort())
              (n, '${n}s'),
          ],
          value: s.draft.toastSeconds,
          onChanged: (v) => set((d) => d.copyWith(toastSeconds: v)),
        ),
      ),
    ],
  );
}

SettingsTabSpec usageTab(SettingsController c) {
  final s = c.loadable<UsageResponse>(SettingsTab.usage);
  final data = s.original;
  final rows = <SettingRowSpec>[];
  Widget? banner;

  if (s.loaded && data != null) {
    if (!data.available) {
      banner = _RetryNotice(
        message: usageUnavailable(data.reason),
        onRetry: () => s.load(force: true),
      );
    } else {
      final acct = data.account;
      final who = [
        acct?.plan,
        acct?.org,
        acct?.email,
      ].whereType<String>().where((e) => e.isNotEmpty).join(' · ');
      if (who.isNotEmpty) {
        rows.add(
          SettingRowSpec(
            id: 'account',
            label: 'Account',
            help: 'From your local Claude Code login',
            control: (_) => SettingValue(who),
          ),
        );
      }
      for (final l in data.limits) {
        final reset = resetLabel(l.resetsAt);
        rows.add(
          SettingRowSpec(
            id: 'limit_${l.kind}_${l.label}',
            label: l.label,
            help: [
              ?reset,
              if (l.isActive) 'Currently limiting you',
            ].join(' · '),
            control: (_) => SettingMeter(percent: l.percent ?? 0),
          ),
        );
      }
      final spend = data.spend;
      if (spend != null) {
        rows.add(
          SettingRowSpec(
            id: 'spend',
            label: 'Extra-usage credits',
            help: spend.disclaimer ?? '',
            control: (_) => Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SettingValue(
                  [
                    ?spend.usedLabel,
                    if (spend.limitLabel != null) '/ ${spend.limitLabel}',
                  ].join(' '),
                ),
                if (spend.percent != null) ...[
                  const SizedBox(height: 8),
                  SettingMeter(percent: spend.percent!),
                ],
              ],
            ),
          ),
        );
      }
    }
  }

  return SettingsTabSpec(
    tab: SettingsTab.usage,
    title: 'Usage',
    intro: 'Your Claude plan limits, read from your local Claude Code login. haro never changes your sign-in.',
    scope: SettingsScope.readOnly,
    rows: rows,
    banner: banner,
    footer: s.loaded && (data?.available ?? false)
        ? Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: IntrinsicWidth(
                child: HaroButton(
                  label: 'Refresh',
                  onPressed: () => s.load(force: true),
                ),
              ),
            ),
          )
        : null,
  );
}

class _RetryNotice extends StatelessWidget {
  const _RetryNotice({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            message,
            style: HaroText.ui(size: 14, color: HaroTokens.ink66, height: 1.5),
          ),
        ),
        const SizedBox(width: 24),
        HaroButton(label: 'Retry', onPressed: onRetry),
      ],
    ),
  );
}

/// `~/.haro` unless HOME says otherwise; the backend keeps its database, logs and worktrees
/// there.
String dataFolderLabel() => '~/.haro';

SettingsTabSpec systemTab(SettingsController c) {
  final s = c.loadable<UpdateStatus>(SettingsTab.system);
  final u = s.original;
  final shell = Platform.environment['SHELL'] ?? 'unknown';
  final update = u == null
      ? (s.state == SectionLoad.error ? 'Unknown' : 'Checking…')
      : !u.supported
      ? 'Running from source, self-update unavailable'
      : [
          u.available
              ? 'Update available (${u.buildSha} to ${u.headSha})'
              : 'Up to date (${u.buildSha})',
          '${u.mode} updates',
        ].join(' · ');
  return SettingsTabSpec(
    tab: SettingsTab.system,
    title: 'System',
    intro: 'Where haro keeps its state and how it talks to your machine.',
    scope: SettingsScope.readOnly,
    rows: [
      SettingRowSpec(
        id: 'data_folder',
        label: 'Data folder',
        help: 'Worktrees, logs and gate history',
        control: (_) => SettingValue(dataFolderLabel()),
      ),
      SettingRowSpec(
        id: 'shell',
        label: 'Shell',
        help: 'Terminal and setup scripts',
        control: (_) => SettingValue(shell),
      ),
      SettingRowSpec(
        id: 'launch_at_login',
        label: 'Launch at login',
        help: 'Not available yet',
        control: (_) => const SettingToggle(value: false, onChanged: null),
      ),
      SettingRowSpec(
        id: 'updates',
        label: 'Updates',
        help: 'Build and update status',
        control: (_) => SettingValue(update),
      ),
    ],
  );
}
