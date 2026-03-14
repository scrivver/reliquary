import 'package:flutter/material.dart';

import '../main.dart';
import '../models/file_item.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import 'login_screen.dart';
import 'settings_screen.dart';
import 'upload_screen.dart';

class GalleryScreen extends StatefulWidget {
  final AuthService authService;

  const GalleryScreen({super.key, required this.authService});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late final ApiService _apiService;
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
    _apiService = ApiService(
      widget.authService,
      onUnauthorized: _handleUnauthorized,
    );
    _loadFiles();
  }

  void _handleUnauthorized() {
    final nav = navigatorKey.currentState;
    if (nav != null) {
      nav.pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => LoginScreen(authService: widget.authService),
        ),
        (_) => false,
      );
    }
  }

  Future<void> _loadFiles() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await _apiService.listFiles(offset: 0, limit: _pageSize);
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
        _error = 'Failed to load files';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;

    setState(() => _loadingMore = true);

    try {
      final result = await _apiService.listFiles(
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

  Future<void> _deleteFile(FileItem file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Delete "${file.filename}" from archive?'),
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
      await _apiService.deleteFile(file.key);
      _loadFiles();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to delete file')),
      );
    }
  }

  Future<void> _openFile(FileItem file) async {
    if (file.isImage) {
      _viewFullImage(file);
    } else {
      _showFileDetails(file);
    }
  }

  Future<void> _viewFullImage(FileItem file) async {
    try {
      final url = await _apiService.presignDownload(file.key);
      if (!mounted) return;

      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(file.filename)),
          body: Center(
            child: InteractiveViewer(
              child: Image.network(url),
            ),
          ),
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to load image')),
      );
    }
  }

  void _showFileDetails(FileItem file) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(file.originalName ?? file.filename),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Type: ${file.contentType}'),
            Text('Size: ${_formatSize(file.size)}'),
            if (file.uploadDate != null)
              Text('Uploaded: ${file.uploadDate}'),
            if (file.checksum != null)
              Text('SHA-256: ${file.checksum!.substring(0, 16)}...'),
            if (file.originalName != null && file.originalName != file.filename)
              Text('Stored as: ${file.filename}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    await widget.authService.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => LoginScreen(authService: widget.authService),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_totalCount > 0
            ? 'Reliquary ($_totalCount files)'
            : 'Reliquary'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
            tooltip: 'Settings',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
            tooltip: 'Logout',
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => UploadScreen(apiService: _apiService),
          ));
          _loadFiles();
        },
        child: const Icon(Icons.upload),
      ),
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
        child: Text('No files yet. Tap + to upload.'),
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
        child: GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 200,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: _files.length + (_hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= _files.length) {
              return const Center(child: CircularProgressIndicator());
            }
            final file = _files[index];
            return _FileTile(
              file: file,
              apiService: _apiService,
              onTap: () => _openFile(file),
              onDelete: () => _deleteFile(file),
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
}

class _FileTile extends StatefulWidget {
  final FileItem file;
  final ApiService apiService;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _FileTile({
    required this.file,
    required this.apiService,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_FileTile> createState() => _FileTileState();
}

class _FileTileState extends State<_FileTile> {
  String? _thumbUrl;

  @override
  void initState() {
    super.initState();
    if (widget.file.thumbnailKey != null) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    try {
      final url =
          await widget.apiService.presignDownload(widget.file.thumbnailKey!);
      if (mounted) setState(() => _thumbUrl = url);
    } catch (_) {
      // Thumbnail may not exist yet; ignore.
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onDelete,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: Colors.grey[200],
          child: _thumbUrl != null
              ? Image.network(
                  _thumbUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _placeholder(),
                )
              : _placeholder(),
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _iconForContentType(widget.file.contentType),
            size: 40,
            color: Colors.grey,
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              widget.file.filename,
              style: const TextStyle(fontSize: 10),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
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
