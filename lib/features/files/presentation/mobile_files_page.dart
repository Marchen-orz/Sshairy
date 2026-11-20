import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brand.dart';
import '../../../design/format.dart';
import '../../../design/theme.dart';
import '../../../foundation/file_system.dart';
import '../../../l10n/app_localizations.dart';
import '../../connections/api.dart';
import '../../hosts/api.dart';
import '../../settings/api.dart';
import '../adapters/desktop.dart';
import '../application/browser.dart';
import '../application/file_ops.dart';

const _maxInlineEditBytes = 512 * 1024;

/// Touch-first single-pane remote SFTP browser & built-in file viewer/editor for phones (docs/MOBILE.md §3.3).
class MobileFilesPage extends ConsumerStatefulWidget {
  const MobileFilesPage({super.key, required this.host, this.initialPath, this.onSendPathToTerminal, this.onAskAiry});

  final Host host;
  final String? initialPath;
  final ValueChanged<String>? onSendPathToTerminal;
  final ValueChanged<String>? onAskAiry;

  @override
  ConsumerState<MobileFilesPage> createState() => _MobileFilesPageState();
}

class _MobileFilesPageState extends ConsumerState<MobileFilesPage> {
  late final FileBrowser _browser;
  var _busy = false;
  String? _banner;

  @override
  void initState() {
    super.initState();
    final connections = ref.read(connectionManagerProvider);
    final hidden = ref.read(settingsProvider).get(SettingKeys.showHidden);
    _browser = FileBrowser(connections, showHidden: hidden);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_browser.open(widget.host, DialogPrompts(context), at: widget.initialPath));
    });
  }

  @override
  void dispose() {
    _browser.dispose();
    super.dispose();
  }

  void _flash(String text) {
    if (!mounted) return;
    setState(() => _banner = text);
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted && _banner == text) setState(() => _banner = null);
    });
  }

  Future<void> _uploadFiles() async {
    final fs = _browser.fs;
    if (fs == null || _busy) return;
    final picked = await pickUploadFiles();
    if (picked.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      for (final file in picked) {
        final dest = fs.style.join(_browser.path, file.name);
        await fs.create(dest, Stream.value(file.bytes));
      }
      await _browser.refresh();
      if (mounted) _flash(AppLocalizations.of(context).mobileFileSaved);
    } on FsError catch (e) {
      if (mounted) _flash(e.detail.isEmpty ? e.kind.name : e.detail);
    } on Object catch (e) {
      if (mounted) _flash('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createEntry({required bool folder}) async {
    final fs = _browser.fs;
    if (fs == null) return;
    final l = AppLocalizations.of(context);
    final controller = TextEditingController();
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, MediaQuery.viewInsetsOf(context).bottom + Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(folder ? l.mobileNewFolder : l.mobileNewFile, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Space.md),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: folder ? 'logs' : 'config.yaml'),
              onSubmitted: (v) => Navigator.pop(context, v.trim()),
            ),
            const SizedBox(height: Space.md),
            FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(l.save)),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final dest = fs.style.join(_browser.path, name);
      if (folder) {
        await fs.mkdir(dest);
      } else {
        await fs.create(dest, Stream.value(Uint8List(0)));
      }
      await _browser.refresh();
    } on FsError catch (e) {
      if (mounted) _flash(e.detail.isEmpty ? e.kind.name : e.detail);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openEditor(FileEntry entry) async {
    final fs = _browser.fs;
    if (fs == null) return;
    final l = AppLocalizations.of(context);
    if ((entry.size ?? 0) > _maxInlineEditBytes) {
      _flash(l.mobileFileTooLarge);
      return;
    }
    final remotePath = _browser.pathOf(entry);
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _MobileFileEditorPage(
          fs: fs,
          hostLabel: widget.host.title,
          remotePath: remotePath,
          fileName: entry.name,
          onAskAiry: widget.onAskAiry,
        ),
      ),
    );
    if (saved == true && mounted) {
      await _browser.refresh();
    }
  }

  Future<void> _rename(FileEntry entry) async {
    final fs = _browser.fs;
    if (fs == null) return;
    final l = AppLocalizations.of(context);
    final controller = TextEditingController(text: entry.name);
    final nextName = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, MediaQuery.viewInsetsOf(context).bottom + Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.rename, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Space.md),
            TextField(controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v.trim())),
            const SizedBox(height: Space.md),
            FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(l.save)),
          ],
        ),
      ),
    );
    controller.dispose();
    if (nextName == null || nextName.isEmpty || nextName == entry.name || !mounted) return;
    setState(() => _busy = true);
    try {
      await fs.rename(_browser.pathOf(entry), fs.style.join(_browser.path, nextName));
      await _browser.refresh();
    } on FsError catch (e) {
      if (mounted) _flash(e.detail.isEmpty ? e.kind.name : e.detail);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(FileEntry entry) async {
    final fs = _browser.fs;
    if (fs == null) return;
    final l = AppLocalizations.of(context);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.delete, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Space.sm),
            Text(entry.name, style: mono(context, Theme.of(context).textTheme.bodyMedium)),
            const SizedBox(height: Space.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(l.delete),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final path = _browser.pathOf(entry);
      if (entry.isDir) {
        await deleteTree(fs, path, entry);
      } else {
        await fs.delete(path);
      }
      await _browser.refresh();
    } on FsError catch (e) {
      if (mounted) _flash(e.detail.isEmpty ? e.kind.name : e.detail);
    } on OpFailure catch (e) {
      if (mounted) _flash(e.detail.isEmpty ? e.code : e.detail);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showEntryActions(FileEntry entry) {
    final l = AppLocalizations.of(context);
    final fullPath = _browser.pathOf(entry);
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(entry.browsable ? Icons.folder_outlined : Icons.description_outlined),
              title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(fullPath, style: mono(context, Theme.of(context).textTheme.bodySmall), maxLines: 1),
            ),
            const Divider(height: 1),
            if (!entry.browsable)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l.mobileFileEditor),
                onTap: () {
                  Navigator.pop(context);
                  unawaited(_openEditor(entry));
                },
              ),
            if (widget.onSendPathToTerminal != null)
              ListTile(
                leading: const Icon(Icons.terminal),
                title: Text(l.mobileSendPathToTerminal),
                onTap: () {
                  Navigator.pop(context);
                  widget.onSendPathToTerminal!(fullPath);
                  Navigator.of(this.context).maybePop();
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: Text(l.copy),
              onTap: () {
                Navigator.pop(context);
                unawaited(Clipboard.setData(ClipboardData(text: fullPath)));
                _flash(l.linkCopied);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: Text(l.rename),
              onTap: () {
                Navigator.pop(context);
                unawaited(_rename(entry));
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text(l.delete, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                unawaited(_delete(entry));
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAddSheet() {
    final l = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: Text(l.mobileUploadFile),
              onTap: () {
                Navigator.pop(context);
                unawaited(_uploadFiles());
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(l.mobileNewFolder),
              onTap: () {
                Navigator.pop(context);
                unawaited(_createEntry(folder: true));
              },
            ),
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: Text(l.mobileNewFile),
              onTap: () {
                Navigator.pop(context);
                unawaited(_createEntry(folder: false));
              },
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(FileEntry e) {
    if (e.browsable) return Icons.folder_rounded;
    final lower = e.name.toLowerCase();
    if (lower.endsWith('.log') || lower.endsWith('.txt') || lower.endsWith('.md')) return Icons.article_outlined;
    if (lower.endsWith('.json') || lower.endsWith('.yaml') || lower.endsWith('.yml') || lower.endsWith('.toml')) {
      return Icons.data_object_outlined;
    }
    if (lower.endsWith('.sh') || lower.endsWith('.py') || lower.endsWith('.dart') || lower.endsWith('.conf')) {
      return Icons.code_rounded;
    }
    if (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final palette = BrandPalette.of(context);

    return ListenableBuilder(
      listenable: _browser,
      builder: (context, _) {
        final crumbs = _browser.path.isEmpty ? const <(String, String)>[] : _browser.style.crumbs(_browser.path);
        final items = _browser.visible;
        return Scaffold(
          backgroundColor: palette.background,
          appBar: AppBar(
            backgroundColor: palette.surface,
            surfaceTintColor: Colors.transparent,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.host.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  widget.host.target,
                  style: mono(context, Theme.of(context).textTheme.labelSmall).copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: l.hiddenFiles,
                icon: Icon(_browser.showHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () {
                  final next = !_browser.showHidden;
                  _browser.showHidden = next;
                  ref.read(settingsProvider.notifier).set(SettingKeys.showHidden, next);
                  setState(() {});
                },
              ),
              IconButton(
                tooltip: l.refresh,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _browser.ready ? () => unawaited(_browser.refresh()) : null,
              ),
            ],
          ),
          floatingActionButton: _browser.ready
              ? FloatingActionButton(
                  key: const ValueKey('mobile-files-fab'),
                  onPressed: _busy ? null : _showAddSheet,
                  child: const Icon(Icons.add),
                )
              : null,
          body: Column(
            children: [
              if (_busy || _browser.loading) const LinearProgressIndicator(minHeight: 2),
              if (_banner != null)
                Container(
                  width: double.infinity,
                  color: scheme.primaryContainer,
                  padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
                  child: Text(
                    _banner!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer),
                  ),
                ),
              if (crumbs.isNotEmpty)
                Container(
                  height: 44,
                  color: palette.surface,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
                    itemCount: crumbs.length,
                    separatorBuilder: (_, _) => Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
                    itemBuilder: (context, index) {
                      final (label, target) = crumbs[index];
                      final last = index == crumbs.length - 1;
                      return ActionChip(
                        visualDensity: VisualDensity.compact,
                        backgroundColor: last ? scheme.primaryContainer : palette.raised,
                        side: BorderSide.none,
                        label: Text(
                          label,
                          style: mono(
                            context,
                            Theme.of(context).textTheme.labelMedium,
                          ).copyWith(color: last ? scheme.onPrimaryContainer : scheme.onSurface),
                        ),
                        onPressed: last ? null : () => unawaited(_browser.go(target)),
                      );
                    },
                  ),
                ),
              Expanded(
                child: switch (_browser.status) {
                  BrowserStatus.idle || BrowserStatus.connecting => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const BrandIllustration(pose: BrandPose.sftpTransfer, size: 140),
                        const SizedBox(height: Space.md),
                        const CircularProgressIndicator(),
                      ],
                    ),
                  ),
                  BrowserStatus.failed || BrowserStatus.lost => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.xl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const BrandIllustration(pose: BrandPose.sftpTransfer, size: 132),
                          const SizedBox(height: Space.md),
                          Text(
                            _browser.connectError == null ? l.disconnected : connectErrorText(l, _browser.connectError),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: Space.md),
                          FilledButton.icon(
                            onPressed: () => unawaited(_browser.reconnect(DialogPrompts(context))),
                            icon: const Icon(Icons.refresh),
                            label: Text(l.retry),
                          ),
                        ],
                      ),
                    ),
                  ),
                  BrowserStatus.ready =>
                    items.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const BrandIllustration(pose: BrandPose.sftpTransfer, size: 140),
                                const SizedBox(height: Space.sm),
                                Text(
                                  l.emptyFolder,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: () => _browser.refresh(),
                            child: ListView.separated(
                              padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 88),
                              itemCount: items.length,
                              separatorBuilder: (_, _) => const SizedBox(height: Space.xs),
                              itemBuilder: (context, index) {
                                final e = items[index];
                                return Material(
                                  color: palette.surface,
                                  borderRadius: BorderRadius.circular(14),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(14),
                                    onTap: () {
                                      if (e.browsable) {
                                        unawaited(_browser.enter(e));
                                      } else {
                                        unawaited(_openEditor(e));
                                      }
                                    },
                                    onLongPress: () => _showEntryActions(e),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.md),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              color: (e.browsable ? palette.primary : scheme.secondary).withValues(
                                                alpha: .12,
                                              ),
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: Icon(
                                              _iconFor(e),
                                              size: 20,
                                              color: e.browsable ? palette.primary : scheme.onSurfaceVariant,
                                            ),
                                          ),
                                          const SizedBox(width: Space.md),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  e.name,
                                                  style: Theme.of(context).textTheme.titleSmall,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  [
                                                    if (!e.browsable && e.size != null) formatFileSize(e.size!),
                                                    if (e.mode != null) _formatMode(e.mode!),
                                                  ].join(' · '),
                                                  style: mono(
                                                    context,
                                                    Theme.of(context).textTheme.labelSmall,
                                                  ).copyWith(color: scheme.onSurfaceVariant),
                                                ),
                                              ],
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.more_vert, size: 20),
                                            onPressed: () => _showEntryActions(e),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                },
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatMode(int mode) {
    final perm = mode & 0x1FF;
    const chars = 'rwxrwxrwx';
    final buf = StringBuffer();
    for (var i = 0; i < 9; i++) {
      buf.write((perm & (1 << (8 - i))) != 0 ? chars[i] : '-');
    }
    return buf.toString();
  }
}

class _MobileFileEditorPage extends StatefulWidget {
  const _MobileFileEditorPage({
    required this.fs,
    required this.hostLabel,
    required this.remotePath,
    required this.fileName,
    this.onAskAiry,
  });

  final FileSystem fs;
  final String hostLabel;
  final String remotePath;
  final String fileName;
  final ValueChanged<String>? onAskAiry;

  @override
  State<_MobileFileEditorPage> createState() => _MobileFileEditorPageState();
}

class _MobileFileEditorPageState extends State<_MobileFileEditorPage> {
  final _controller = TextEditingController();
  var _loading = true;
  var _saving = false;
  var _editing = false;
  var _dirty = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in widget.fs.read(widget.remotePath)) {
        buffer.add(chunk);
        if (buffer.length > _maxInlineEditBytes) {
          throw const FormatException('tooLarge');
        }
      }
      final bytes = buffer.takeBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      _controller.text = text;
      setState(() => _loading = false);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final bytes = Uint8List.fromList(utf8.encode(_controller.text));
      final dir = widget.fs.style.parent(widget.remotePath);
      final tmp = widget.fs.style.join(dir, '.${widget.fileName}.sshairy.tmp');
      try {
        await widget.fs.create(tmp, Stream.value(bytes));
        if (widget.fs.canReplace) {
          await widget.fs.replace(tmp, widget.remotePath);
        } else {
          await widget.fs.delete(widget.remotePath);
          await widget.fs.rename(tmp, widget.remotePath);
        }
      } on Object {
        await widget.fs.delete(tmp).catchError((Object _) {});
        rethrow;
      }
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
        _editing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context).mobileFileSaved)));
      Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _askAiry() {
    final cb = widget.onAskAiry;
    if (cb == null) return;
    final excerpt = _controller.text.length > 4000 ? _controller.text.substring(0, 4000) : _controller.text;
    cb('Analyze `${widget.remotePath}` on `${widget.hostLabel}`:\n```\n$excerpt\n```');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final palette = BrandPalette.of(context);
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        title: Text(widget.fileName, overflow: TextOverflow.ellipsis),
        actions: [
          if (widget.onAskAiry != null && !_loading && _error == null)
            IconButton(tooltip: l.mobileAskAiry, icon: const Icon(Icons.auto_awesome_outlined), onPressed: _askAiry),
          if (!_loading && _error == null)
            _editing
                ? TextButton(
                    onPressed: _saving || !_dirty ? null : () => unawaited(_save()),
                    child: _saving
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(l.save),
                  )
                : IconButton(
                    tooltip: l.mobileFileEditor,
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => setState(() => _editing = true),
                  ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(padding: const EdgeInsets.all(Space.xl), child: Text(_error!)),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
              child: TextField(
                controller: _controller,
                readOnly: !_editing,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: mono(context, Theme.of(context).textTheme.bodySmall),
                decoration: const InputDecoration(border: InputBorder.none),
                onChanged: (_) {
                  if (!_dirty) setState(() => _dirty = true);
                },
              ),
            ),
    );
  }
}
