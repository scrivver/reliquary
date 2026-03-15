import 'package:flutter/material.dart';

import '../models/file_item.dart';
import '../services/api_service.dart';

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
        title: const Text('Restore File'),
        content: Text('Restore "${file.filename}" to active files?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
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
        const SnackBar(content: Text('File restored')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to restore: $e')),
      );
    }
  }

  Future<void> _deleteFile(FileItem file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Permanently'),
        content: Text(
            'Permanently delete "${file.filename}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
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
        SnackBar(content: Text('Failed to delete: $e')),
      );
    }
  }

  Future<void> _runArchival() async {
    try {
      await widget.apiService.runArchival();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Archival scan started')),
      );
      // Reload after a short delay to show new results.
      Future.delayed(const Duration(seconds: 2), _loadFiles);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start archival: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_totalCount > 0
            ? 'Archive ($_totalCount files)'
            : 'Archive'),
        actions: [
          IconButton(
            icon: const Icon(Icons.play_arrow),
            onPressed: _runArchival,
            tooltip: 'Run Archival Now',
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 16),
            FilledButton(onPressed: _loadFiles, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_files.isEmpty) {
      return const Center(
        child: Text('No archived files.'),
      );
    }

    return RefreshIndicator(
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
                child: CircularProgressIndicator(),
              ));
            }
            final file = _files[index];
            return ListTile(
              leading: Icon(_iconForContentType(file.contentType)),
              title: Text(file.filename),
              subtitle: Text(
                  '${_formatSize(file.size)} - ${file.lastModified.toLocal().toString().split('.').first}'),
              trailing: PopupMenuButton<String>(
                onSelected: (action) {
                  if (action == 'restore') _restoreFile(file);
                  if (action == 'delete') _deleteFile(file);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'restore',
                    child: Text('Restore'),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child:
                        Text('Delete', style: TextStyle(color: Colors.red)),
                  ),
                ],
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
