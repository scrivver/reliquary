import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../models/file_item.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/download_helper.dart' as dl;
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
  int _totalCount = 0;
  String? _error;
  String _username = '';
  String _currentPath = '';
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _searching = false;
  bool _selectMode = false;
  final Set<String> _selected = {};

  static const _pageSize = 200;

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
    _loadFiles();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadUserInfo() async {
    final username = await widget.authService.getUsername();
    if (mounted) setState(() => _username = username ?? '');
  }

  void _handleUnauthorized() {
    final nav = navigatorKey.currentState;
    if (nav != null) {
      widget.authService.logout();
      nav.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AuthGate()),
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
      final files = <FileItem>[];
      var offset = 0;
      var totalCount = 0;
      var hasMore = true;

      while (hasMore) {
        final result = await widget.apiService.listFiles(
          offset: offset,
          limit: _pageSize,
        );
        files.addAll(result.files);
        totalCount = result.totalCount;
        offset += result.files.length;
        hasMore = result.hasMore && result.files.isNotEmpty;
      }

      if (!mounted) return;
      setState(() {
        _files
          ..clear()
          ..addAll(files);
        _totalCount = totalCount;
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
            child: const Text(
              'DELETE',
              style: TextStyle(color: Color(0xFFEC3713)),
            ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to delete file')));
    }
  }

  Future<void> _downloadFile(FileItem file) async {
    try {
      final url = await widget.apiService.presignDownloadForSave(file.key);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to download file')));
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
      final url = await widget.apiService.presignDownload(file.key);
      if (!mounted) return;

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(file.displayPath),
              actions: [
                IconButton(
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => _showFileDetails(file),
                  tooltip: 'DETAILS',
                ),
                IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: () async {
                    final downloadUrl = await widget.apiService
                        .presignDownloadForSave(file.key);
                    launchUrl(
                      Uri.parse(downloadUrl),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  tooltip: 'DOWNLOAD',
                ),
              ],
            ),
            body: Center(child: InteractiveViewer(child: Image.network(url))),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to load image')));
    }
  }

  void _showFileDetails(FileItem file) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(file.displayPath),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailRow('PATH', file.displayPath),
            _detailRow('TYPE', file.contentType),
            _detailRow('SIZE', _formatSize(file.size)),
            if (file.uploadDate != null)
              _detailRow('UPLOADED', file.uploadDate!),
            if (file.checksum != null)
              _detailRow('SHA-256', '${file.checksum!.substring(0, 16)}...'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteFile(file);
            },
            child: const Text(
              'DELETE',
              style: TextStyle(color: Color(0xFFEC3713)),
            ),
          ),
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
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Space Mono',
                fontSize: 10,
                color: Colors.grey,
                letterSpacing: 0.5,
              ),
            ),
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

  void _toggleSelect(FileItem file) {
    setState(() {
      if (_selected.contains(file.key)) {
        _selected.remove(file.key);
        if (_selected.isEmpty) _selectMode = false;
      } else {
        _selected.add(file.key);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selected.addAll(_visibleFiles().map((f) => f.key));
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selected.clear();
    });
  }

  Future<void> _deleteSelected() async {
    final count = _selected.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('DELETE FILES'),
        content: Text('Permanently remove $count file(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'DELETE',
              style: TextStyle(color: Color(0xFFEC3713)),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    for (final key in _selected.toList()) {
      try {
        await widget.apiService.deleteFile(key);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
        break;
      }
    }
    _exitSelectMode();
    _loadFiles();
  }

  Future<void> _downloadSelected() async {
    final keys = _selected.toList();

    if (kIsWeb) {
      if (keys.length == 1) {
        // Single file on web — direct download.
        try {
          final url = await widget.apiService.presignDownloadForSave(
            keys.first,
          );
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to download: $e')));
          return;
        }
      } else {
        // Multiple files on web — zip download.
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Preparing ${keys.length} files for download...',
              style: TextStyle(fontFamily: 'Space Mono', fontSize: 12),
            ),
          ),
        );
        try {
          final zipBytes = await widget.apiService.batchDownload(keys);
          if (!mounted) return;
          dl.triggerDownload(
            Uint8List.fromList(zipBytes),
            'reliquary-download.zip',
          );
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to download: $e')));
          return;
        }
      }
    } else {
      // Native — save individual files to a picked directory.
      try {
        await dl.triggerDownload(
          keys,
          (key) => widget.apiService.presignDownloadForSave(key),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to download: $e')));
        return;
      }
    }

    _exitSelectMode();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${keys.length} file(s) downloaded',
          style: TextStyle(fontFamily: 'Space Mono', fontSize: 12),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleFiles = _visibleFiles();
    final visibleFolders = _visibleFolders();
    final itemCount = visibleFolders.length + visibleFiles.length;

    return Scaffold(
      appBar: AppBar(
        leading: _selectMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectMode,
              )
            : null,
        title: _selectMode
            ? Text(
                '${_selected.length} SELECTED',
                style: TextStyle(
                  fontFamily: 'Space Mono',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              )
            : _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search artifacts...',
                  border: InputBorder.none,
                ),
                style: const TextStyle(fontFamily: 'Space Mono', fontSize: 14),
                textInputAction: TextInputAction.search,
                onChanged: (value) {
                  setState(() => _searchQuery = value);
                },
              )
            : Row(
                children: [
                  if (_currentPath.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.arrow_back, size: 20),
                      onPressed: _goUpFolder,
                      tooltip: 'UP_FOLDER',
                    ),
                  Expanded(
                    child: Text(
                      _currentPath.isEmpty ? 'FILES_ROOT' : _currentPath,
                      style: TextStyle(
                        fontFamily: 'Space Mono',
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC3713).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _username.toUpperCase(),
                      style: TextStyle(
                        fontFamily: 'Space Mono',
                        fontSize: 10,
                        color: const Color(0xFFEC3713),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
        actions: _selectMode
            ? [
                IconButton(
                  icon: const Icon(Icons.select_all, size: 20),
                  onPressed: _selectAll,
                  tooltip: 'SELECT_ALL',
                ),
                IconButton(
                  icon: const Icon(Icons.download, size: 20),
                  onPressed: _selected.isEmpty ? null : _downloadSelected,
                  tooltip: 'DOWNLOAD',
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: Color(0xFFEC3713),
                  ),
                  onPressed: _selected.isEmpty ? null : _deleteSelected,
                  tooltip: 'DELETE',
                ),
              ]
            : [
                if (_searching)
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: _stopSearch,
                    tooltip: 'CLEAR_SEARCH',
                  )
                else ...[
                  if (_totalCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Center(
                        child: Text(
                          '$_totalCount ITEMS',
                          style: TextStyle(
                            fontFamily: 'Space Mono',
                            fontSize: 10,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.search, size: 20),
                    onPressed: _startSearch,
                    tooltip: 'SEARCH',
                  ),
                ],
                if (visibleFiles.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.checklist, size: 20),
                    onPressed: () => setState(() => _selectMode = true),
                    tooltip: 'SELECT',
                  ),
                IconButton(
                  icon: const Icon(Icons.logout, size: 20),
                  onPressed: _logout,
                  tooltip: 'LOGOUT',
                ),
              ],
      ),
      body: _buildBody(visibleFolders, visibleFiles, itemCount),
      floatingActionButton: _selectMode
          ? null
          : FloatingActionButton(
              heroTag: 'upload_fab',
              backgroundColor: const Color(0xFFEC3713),
              foregroundColor: Colors.white,
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => UploadScreen(apiService: widget.apiService),
                  ),
                );
                _loadFiles();
              },
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildBody(
    List<_FolderEntry> visibleFolders,
    List<FileItem> visibleFiles,
    int itemCount,
  ) {
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
            Text(
              'VAULT_EMPTY',
              style: TextStyle(fontFamily: 'Space Mono', color: Colors.grey),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap + to deposit artifacts',
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (itemCount == 0) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              _searchQuery.trim().isEmpty ? 'FOLDER_EMPTY' : 'NO_MATCHES',
              style: TextStyle(fontFamily: 'Space Mono', color: Colors.grey),
            ),
            if (_searchQuery.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Try a different search term',
                style: TextStyle(color: Colors.grey[500], fontSize: 13),
              ),
            ],
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFiles,
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 200,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index < visibleFolders.length) {
            final folder = visibleFolders[index];
            return _FolderTile(
              key: ValueKey('folder:${folder.path}'),
              folder: folder,
              onTap: () => _openFolder(folder.path),
            );
          }

          final file = visibleFiles[index - visibleFolders.length];
          final isSelected = _selected.contains(file.key);
          return _FileTile(
            key: ValueKey('file:${file.key}'),
            file: file,
            label: _labelForFile(file),
            apiService: widget.apiService,
            selected: _selectMode ? isSelected : null,
            onTap: _selectMode
                ? () => _toggleSelect(file)
                : () => _openFile(file),
            onLongPress: _selectMode
                ? null
                : () {
                    setState(() => _selectMode = true);
                    _toggleSelect(file);
                  },
          );
        },
      ),
    );
  }

  List<_FolderEntry> _visibleFolders() {
    if (_isSearching) return [];

    final folders = <String, int>{};
    final prefix = _currentPath.isEmpty ? '' : '$_currentPath/';

    for (final file in _files) {
      final path = file.displayPath;
      if (!path.startsWith(prefix)) continue;
      final rest = path.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash == -1) continue;
      final name = rest.substring(0, slash);
      final folderPath = prefix + name;
      folders[folderPath] = (folders[folderPath] ?? 0) + 1;
    }

    final entries =
        folders.entries
            .map((entry) => _FolderEntry(path: entry.key, count: entry.value))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  List<FileItem> _visibleFiles() {
    if (_isSearching) {
      final files = _files.where((file) {
        return _matchesSearch(file, _searchQuery);
      }).toList()..sort((a, b) => a.displayPath.compareTo(b.displayPath));
      return files;
    }

    final prefix = _currentPath.isEmpty ? '' : '$_currentPath/';
    final files = _files.where((file) {
      final path = file.displayPath;
      if (!path.startsWith(prefix)) return false;
      return !path.substring(prefix.length).contains('/');
    }).toList()..sort((a, b) => a.displayPath.compareTo(b.displayPath));
    return files;
  }

  String _labelForFile(FileItem file) {
    if (_isSearching) return file.displayPath;
    if (_currentPath.isEmpty) return file.displayPath;
    final prefix = '$_currentPath/';
    if (!file.displayPath.startsWith(prefix)) return file.displayPath;
    return file.displayPath.substring(prefix.length);
  }

  bool get _isSearching => _searchQuery.trim().isNotEmpty;

  bool _matchesSearch(FileItem file, String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return true;

    return file.displayPath.toLowerCase().contains(normalized) ||
        file.filename.toLowerCase().contains(normalized) ||
        file.contentType.toLowerCase().contains(normalized) ||
        (file.originalName?.toLowerCase().contains(normalized) ?? false);
  }

  void _startSearch() {
    setState(() {
      _searching = true;
      _selectMode = false;
      _selected.clear();
    });
  }

  void _stopSearch() {
    setState(() {
      _searching = false;
      _searchQuery = '';
      _searchController.clear();
      _selectMode = false;
      _selected.clear();
    });
  }

  void _openFolder(String path) {
    setState(() {
      _currentPath = path;
      _selectMode = false;
      _selected.clear();
    });
  }

  void _goUpFolder() {
    setState(() {
      final slash = _currentPath.lastIndexOf('/');
      _currentPath = slash == -1 ? '' : _currentPath.substring(0, slash);
      _selectMode = false;
      _selected.clear();
    });
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _FolderEntry {
  final String path;
  final int count;

  const _FolderEntry({required this.path, required this.count});

  String get name => path.split('/').last;
}

class _FolderTile extends StatelessWidget {
  final _FolderEntry folder;
  final VoidCallback onTap;

  const _FolderTile({super.key, required this.folder, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          border: Border.all(color: const Color(0xFFE0E0E0)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.folder, size: 42, color: Colors.grey[500]),
                const SizedBox(height: 8),
                Text(
                  folder.name,
                  style: const TextStyle(
                    fontFamily: 'Space Mono',
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text(
                  '${folder.count} ITEMS',
                  style: TextStyle(
                    fontFamily: 'Space Mono',
                    fontSize: 9,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FileTile extends StatefulWidget {
  final FileItem file;
  final String label;
  final ApiService apiService;
  final bool? selected; // null = not in select mode
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _FileTile({
    super.key,
    required this.file,
    required this.label,
    required this.apiService,
    this.selected,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<_FileTile> createState() => _FileTileState();
}

class _FileTileState extends State<_FileTile> {
  String? _thumbUrl;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant _FileTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.key != widget.file.key ||
        oldWidget.file.thumbnailKey != widget.file.thumbnailKey) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    final thumbnailKey = widget.file.thumbnailKey;
    if (thumbnailKey == null) {
      if (mounted) setState(() => _thumbUrl = null);
      return;
    }

    setState(() => _thumbUrl = null);
    try {
      final url = await widget.apiService.presignDownload(thumbnailKey);
      if (!mounted || widget.file.thumbnailKey != thumbnailKey) return;
      setState(() => _thumbUrl = url);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.selected == true;
    final inSelectMode = widget.selected != null;

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFFEC3713)
                      : const Color(0xFFE0E0E0),
                  width: isSelected ? 2 : 1,
                ),
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
            if (_thumbUrl != null) _labelOverlay(),
            if (inSelectMode)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFFEC3713)
                        : Colors.white.withValues(alpha: 0.8),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? const Color(0xFFEC3713) : Colors.grey,
                    ),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : null,
                ),
              ),
          ],
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
              widget.label,
              style: TextStyle(
                fontFamily: 'Space Mono',
                fontSize: 9,
                color: Colors.grey,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _labelOverlay() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: 0.72),
              Colors.black.withValues(alpha: 0.0),
            ],
          ),
        ),
        child: Text(
          widget.label,
          style: const TextStyle(
            fontFamily: 'Space Mono',
            fontSize: 9,
            color: Colors.white,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
          textAlign: TextAlign.center,
        ),
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
