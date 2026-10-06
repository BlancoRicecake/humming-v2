import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../music/export_library.dart';
import '../../theme/tokens.dart';

Future<void> showExportLibrary(BuildContext context) => Navigator.of(
  context,
).push<void>(MaterialPageRoute(builder: (_) => const ExportLibraryScreen()));

class ExportLibraryScreen extends StatefulWidget {
  const ExportLibraryScreen({super.key});
  @override
  State<ExportLibraryScreen> createState() => _ExportLibraryScreenState();
}

class _ExportLibraryScreenState extends State<ExportLibraryScreen> {
  late Future<List<ExportedFile>> _files = listExportedFiles();
  bool _busy = false;
  String? _status;

  Future<void> _act(ExportedFile item, {required bool save}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final l = L10n.of(context);
      if (save && Platform.isAndroid) {
        final saved = await const MethodChannel(
          'humtrack/exports',
        ).invokeMethod<bool>('saveExport', {
          'path': item.file.path,
          'name': item.name,
          'mime': item.mimeType,
        });
        if (mounted) {
          setState(
            () =>
                _status =
                    saved == true ? l.ltFilesSaved : l.ltFilesSaveCancelled,
          );
        }
      } else if (save) {
        final location = await getSaveLocation(suggestedName: item.name);
        if (location == null) {
          if (mounted) setState(() => _status = l.ltFilesSaveCancelled);
        } else {
          await XFile(
            item.file.path,
            mimeType: item.mimeType,
          ).saveTo(location.path);
          if (mounted) setState(() => _status = l.ltFilesSaved);
        }
      } else {
        final box = context.findRenderObject() as RenderBox?;
        final result = await SharePlus.instance.share(
          ShareParams(
            files: [XFile(item.file.path, mimeType: item.mimeType)],
            sharePositionOrigin:
                box == null ? null : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
        if (mounted) {
          setState(
            () =>
                _status = switch (result.status) {
                  ShareResultStatus.success => l.ltExportShared,
                  ShareResultStatus.dismissed => l.ltExportShareCancelled,
                  ShareResultStatus.unavailable => l.ltExportShareUnconfirmed,
                },
          );
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _status = L10n.of(context).ltFilesActionFailed);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _files = listExportedFiles();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final canSave =
        Platform.isAndroid ||
        Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isLinux;
    return Scaffold(
      backgroundColor: LT.bg,
      appBar: AppBar(
        title: Text(l.ltFilesTitle),
        actions: [
          IconButton(
            tooltip: l.retry,
            onPressed:
                _busy
                    ? null
                    : () => setState(() => _files = listExportedFiles()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(canSave ? l.ltFilesHint : l.ltFilesIosHint),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Semantics(liveRegion: true, child: Text(_status!)),
            ),
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: FutureBuilder<List<ExportedFile>>(
              future: _files,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text(l.ltFilesLoadFailed));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.data!.isEmpty) {
                  return Center(child: Text(l.ltFilesEmpty));
                }
                return ListView.separated(
                  itemCount: snapshot.data!.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = snapshot.data![index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${DateFormat.yMd(l.localeName).add_Hm().format(item.modified)} · ${(item.size / 1024).ceil()} KB',
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed:
                                    _busy
                                        ? null
                                        : () => _act(item, save: false),
                                icon: const Icon(Icons.share),
                                label: Text(l.ltFilesShare),
                              ),
                              if (canSave)
                                TextButton.icon(
                                  onPressed:
                                      _busy
                                          ? null
                                          : () => _act(item, save: true),
                                  icon: const Icon(Icons.save_alt),
                                  label: Text(l.ltFilesSave),
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
