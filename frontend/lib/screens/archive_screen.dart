import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/file_item.dart';
import '../services/api_service.dart';

const _kAccentRed = Color(0xFFEC3713);

class ArchiveScreen extends StatefulWidget {
  final ApiService apiService;

  const ArchiveScreen({super.key, required this.apiService});

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  final List<FileItem> _files = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _totalCount = 0;
  String? _error;

  static const _pageSize = 50;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result =
          await widget.apiService.listArchive(offset: 0, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _files
          ..clear()
          ..addAll(result.files);
        _totalCount = result.totalCount;
        _hasMore = result.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load archived files';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);

    try {
      final result = await widget.apiService.listArchive(
        offset: _files.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _files.addAll(result.files);
        _totalCount = result.totalCount;
        _hasMore = result.hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  Future<void> _restoreFile(FileItem file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('RESTORE_FILE', style: GoogleFonts.spaceGrotesk(
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        )),
        content: Text(
          'Restore "${file.filename}" to active files?',
          style: GoogleFonts.spaceMono(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('CANCEL', style: GoogleFonts.spaceGrotesk(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            )),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _kAccentRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('RESTORE', style: GoogleFonts.spaceGrotesk(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            )),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await widget.apiService.restoreArchive(file.key);
      _loadFiles();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('File restored', style: GoogleFonts.spaceMono(fontSize: 13))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to restore: $e', style: GoogleFonts.spaceMono(fontSize: 13))),
      );
    }
  }

  Future<void> _deleteFile(FileItem file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('DELETE_PERMANENT', style: GoogleFonts.spaceGrotesk(
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        )),
        content: Text(
          'Permanently delete "${file.filename}"? This cannot be undone.',
          style: GoogleFonts.spaceMono(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('CANCEL', style: GoogleFonts.spaceGrotesk(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            )),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('DELETE', style: GoogleFonts.spaceGrotesk(
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: _kAccentRed,
            )),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await widget.apiService.deleteArchive(file.key);
      _loadFiles();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: $e', style: GoogleFonts.spaceMono(fontSize: 13))),
      );
    }
  }

  Future<void> _runArchival() async {
    try {
      await widget.apiService.runArchival();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Archival scan started', style: GoogleFonts.spaceMono(fontSize: 13))),
      );
      // Reload after a short delay to show new results.
      Future.delayed(const Duration(seconds: 2), _loadFiles);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start archival: $e', style: GoogleFonts.spaceMono(fontSize: 13))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _totalCount > 0
              ? 'ARCHIVE_BROWSER ($_totalCount)'
              : 'ARCHIVE_BROWSER',
          style: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.play_arrow, color: _kAccentRed),
            onPressed: _runArchival,
            tooltip: 'RUN_ARCHIVAL_NOW',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kAccentRed));
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: GoogleFonts.spaceMono()),
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kAccentRed),
              onPressed: _loadFiles,
              child: Text('RETRY', style: GoogleFonts.spaceGrotesk(
                fontWeight: FontWeight.w600,
                letterSpacing: 1.0,
              )),
            ),
          ],
        ),
      );
    }

    if (_files.isEmpty) {
      return Center(
        child: Text(
          'NO_ARCHIVED_FILES',
          style: GoogleFonts.spaceMono(
            fontSize: 13,
            letterSpacing: 1.0,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: _kAccentRed,
      onRefresh: _loadFiles,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification &&
              notification.metrics.extentAfter < 200) {
            _loadMore();
          }
          return false;
        },
        child: ListView.builder(
          itemCount: _files.length + (_hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= _files.length) {
              return const Center(
                  child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(color: _kAccentRed),
              ));
            }
            final file = _files[index];
            return Card(
              elevation: 0,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
                side: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: ListTile(
                leading: Icon(
                  _iconForContentType(file.contentType),
                  color: _kAccentRed.withValues(alpha: 0.7),
                ),
                title: Text(
                  file.filename,
                  style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${_formatSize(file.size)} // ${file.lastModified.toLocal().toString().split('.').first}',
                  style: GoogleFonts.spaceMono(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) {
                    if (action == 'restore') _restoreFile(file);
                    if (action == 'delete') _deleteFile(file);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'restore',
                      child: Text('RESTORE', style: GoogleFonts.spaceGrotesk(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                      )),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('DELETE', style: GoogleFonts.spaceGrotesk(
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                        color: _kAccentRed,
                      )),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  IconData _iconForContentType(String contentType) {
    if (contentType.startsWith('image/')) return Icons.image;
    if (contentType.startsWith('video/')) return Icons.videocam;
    if (contentType.startsWith('audio/')) return Icons.audiotrack;
    if (contentType.contains('pdf')) return Icons.picture_as_pdf;
    if (contentType.contains('zip') || contentType.contains('archive')) {
      return Icons.archive;
    }
    return Icons.insert_drive_file;
  }
}
