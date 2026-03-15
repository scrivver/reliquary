import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../models/file_item.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import 'login_screen.dart';
import 'upload_screen.dart';

class GalleryScreen extends StatefulWidget {
  final AuthService authService;
  final ApiService apiService;

  const GalleryScreen({
    super.key,
    required this.authService,
    required this.apiService,
  });

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final List<FileItem> _files = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _totalCount = 0;
  String? _error;
  String _username = '';

  static const _pageSize = 50;

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
    _loadFiles();
  }

  Future<void> _loadUserInfo() async {
    final username = await widget.authService.getUsername();
    if (mounted) setState(() => _username = username ?? '');
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
      final result =
          await widget.apiService.listFiles(offset: 0, limit: _pageSize);
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
      final result = await widget.apiService.listFiles(
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
        title: const Text('DELETE FILE'),
        content: Text('Permanently remove "${file.filename}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('DELETE',
                style: TextStyle(color: Color(0xFFEC3713))),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await widget.apiService.deleteFile(file.key);
      _loadFiles();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to delete file')),
      );
    }
  }

  Future<void> _downloadFile(FileItem file) async {
    try {
      final url = await widget.apiService.presignDownloadForSave(file.key);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to download file')),
      );
    }
  }

  void _showFileMenu(FileItem file) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(file.filename,
                  style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text('DETAILS', style: GoogleFonts.spaceGrotesk(
                  fontSize: 13, letterSpacing: 0.8)),
              onTap: () {
                Navigator.pop(ctx);
                _showFileDetails(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download),
              title: Text('DOWNLOAD', style: GoogleFonts.spaceGrotesk(
                  fontSize: 13, letterSpacing: 0.8)),
              onTap: () {
                Navigator.pop(ctx);
                _downloadFile(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Color(0xFFEC3713)),
              title: Text('DELETE', style: GoogleFonts.spaceGrotesk(
                  fontSize: 13, letterSpacing: 0.8, color: const Color(0xFFEC3713))),
              onTap: () {
                Navigator.pop(ctx);
                _deleteFile(file);
              },
            ),
          ],
        ),
      ),
    );
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
      final url = await widget.apiService.presignDownload(file.key);
      if (!mounted) return;

      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: Text(file.originalName ?? file.filename),
            actions: [
              IconButton(
                icon: const Icon(Icons.info_outline),
                onPressed: () => _showFileDetails(file),
                tooltip: 'DETAILS',
              ),
              IconButton(
                icon: const Icon(Icons.download),
                onPressed: () async {
                  final downloadUrl =
                      await widget.apiService.presignDownloadForSave(file.key);
                  launchUrl(Uri.parse(downloadUrl),
                      mode: LaunchMode.externalApplication);
                },
                tooltip: 'DOWNLOAD',
              ),
            ],
          ),
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
            _detailRow('TYPE', file.contentType),
            _detailRow('SIZE', _formatSize(file.size)),
            if (file.uploadDate != null) _detailRow('UPLOADED', file.uploadDate!),
            if (file.checksum != null)
              _detailRow('SHA-256', '${file.checksum!.substring(0, 16)}...'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _downloadFile(file);
            },
            child: const Text('DOWNLOAD'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CLOSE'),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: GoogleFonts.spaceMono(
                    fontSize: 10, color: Colors.grey, letterSpacing: 0.5)),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    await widget.authService.logout();
    _handleUnauthorized();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text('FILES_ROOT',
                style: GoogleFonts.spaceMono(
                    fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFEC3713).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _username.toUpperCase(),
                style: GoogleFonts.spaceMono(
                  fontSize: 10,
                  color: const Color(0xFFEC3713),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (_totalCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Text(
                  '$_totalCount ITEMS',
                  style: GoogleFonts.spaceMono(
                      fontSize: 10, color: Colors.grey),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.logout, size: 20),
            onPressed: _logout,
            tooltip: 'LOGOUT',
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        heroTag: 'upload_fab',
        backgroundColor: const Color(0xFFEC3713),
        foregroundColor: Colors.white,
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => UploadScreen(apiService: widget.apiService),
          ));
          _loadFiles();
        },
        child: const Icon(Icons.add),
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
            FilledButton(onPressed: _loadFiles, child: const Text('RETRY')),
          ],
        ),
      );
    }

    if (_files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('VAULT_EMPTY',
                style: GoogleFonts.spaceMono(color: Colors.grey)),
            const SizedBox(height: 4),
            Text('Tap + to deposit artifacts',
                style: TextStyle(color: Colors.grey[500], fontSize: 13)),
          ],
        ),
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
              apiService: widget.apiService,
              onTap: () => _openFile(file),
              onLongPress: () => _showFileMenu(file),
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
  final VoidCallback onLongPress;

  const _FileTile({
    required this.file,
    required this.apiService,
    required this.onTap,
    required this.onLongPress,
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
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            border: Border.all(color: const Color(0xFFE0E0E0)),
            borderRadius: BorderRadius.circular(8),
          ),
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
            size: 32,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              widget.file.filename,
              style: GoogleFonts.spaceMono(fontSize: 9, color: Colors.grey),
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
