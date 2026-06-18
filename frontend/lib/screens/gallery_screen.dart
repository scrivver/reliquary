import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../models/file_item.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/download_helper.dart' as dl;
import 'responsive_page.dart';
import 'upload_screen.dart';

const _kPrimary = Color(0xFFB7102A);
const _kSurface = Color(0xFFF8F9FA);
const _kCard = Color(0xFFFFFFFF);
const _kBorder = Color(0xFFE5E5E5);
const _kText = Color(0xFF191C1D);
const _kSecondary = Color(0xFF5F5E5E);
const _kSurfaceLow = Color(0xFFF3F4F5);

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
            child: const Text('DELETE', style: TextStyle(color: _kPrimary)),
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
            child: const Text('DELETE', style: TextStyle(color: _kPrimary)),
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
            child: const Text('DELETE', style: TextStyle(color: _kPrimary)),
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
    final isDesktop = isDesktopWidth(context);

    if (isDesktop) {
      return Scaffold(
        backgroundColor: _kSurface,
        body: _buildDesktopBody(visibleFolders, visibleFiles, itemCount),
      );
    }

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
                      color: _kPrimary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _username.toUpperCase(),
                      style: TextStyle(
                        fontFamily: 'Space Mono',
                        fontSize: 10,
                        color: _kPrimary,
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
                    color: _kPrimary,
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
              backgroundColor: _kPrimary,
              foregroundColor: Colors.white,
              onPressed: _openUpload,
              child: const Icon(Icons.add),
            ),
    );
  }

  Future<void> _openUpload() async {
    await showDialog<void>(
      context: context,
      barrierColor: _kText.withValues(alpha: 0.4),
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        backgroundColor: Colors.transparent,
        child: UploadScreen(apiService: widget.apiService),
      ),
    );
    _loadFiles();
  }

  Widget _buildDesktopBody(
    List<_FolderEntry> visibleFolders,
    List<FileItem> visibleFiles,
    int itemCount,
  ) {
    return Column(
      children: [
        _DesktopFilesTopBar(
          controller: _searchController,
          searching: _searching,
          totalCount: _totalCount,
          username: _username,
          onSearchChanged: (value) => setState(() {
            _searching = value.isNotEmpty;
            _searchQuery = value;
          }),
          onUpload: _openUpload,
          onLogout: _logout,
        ),
        Expanded(
          child: RefreshIndicator(
            color: _kPrimary,
            onRefresh: _loadFiles,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: DesktopPageFrame(
                maxWidth: 1440,
                padding: const EdgeInsets.fromLTRB(40, 32, 40, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: DesktopPageHeader(
                            title: _currentPath.isEmpty
                                ? 'Files'
                                : _currentPath.split('/').last,
                            subtitle: _currentPath.isEmpty
                                ? 'Browse preserved files and folders in the primary vault.'
                                : _currentPath,
                          ),
                        ),
                        if (_currentPath.isNotEmpty) ...[
                          const SizedBox(width: 24),
                          OutlinedButton.icon(
                            onPressed: _goUpFolder,
                            icon: const Icon(Icons.arrow_back, size: 18),
                            label: const Text('UP FOLDER'),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 32),
                    _DesktopFilesControls(
                      selectMode: _selectMode,
                      selectedCount: _selected.length,
                      canSelect: visibleFiles.isNotEmpty,
                      onSelect: () => setState(() => _selectMode = true),
                      onSelectAll: _selectAll,
                      onDownload: _selected.isEmpty ? null : _downloadSelected,
                      onDelete: _selected.isEmpty ? null : _deleteSelected,
                      onClearSelection: _exitSelectMode,
                    ),
                    const SizedBox(height: 16),
                    _buildDesktopList(visibleFolders, visibleFiles, itemCount),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopList(
    List<_FolderEntry> visibleFolders,
    List<FileItem> visibleFiles,
    int itemCount,
  ) {
    if (_loading) {
      return const SizedBox(
        height: 360,
        child: Center(child: CircularProgressIndicator(color: _kPrimary)),
      );
    }

    if (_error != null) {
      return _DesktopEmptyState(
        icon: Icons.error_outline,
        title: _error!,
        subtitle: 'Refresh the vault and try again.',
        action: FilledButton(onPressed: _loadFiles, child: const Text('RETRY')),
      );
    }

    if (_files.isEmpty) {
      return _DesktopEmptyState(
        icon: Icons.folder_open,
        title: 'Vault empty',
        subtitle: 'Upload files to begin preserving artifacts.',
        action: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: _kPrimary),
          onPressed: _openUpload,
          icon: const Icon(Icons.upload),
          label: const Text('UPLOAD'),
        ),
      );
    }

    if (itemCount == 0) {
      return _DesktopEmptyState(
        icon: Icons.search_off,
        title: _searchQuery.trim().isEmpty ? 'Folder empty' : 'No matches',
        subtitle: _searchQuery.trim().isEmpty
            ? 'There are no files in this folder.'
            : 'Try a different search term.',
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          const _DesktopListHeader(),
          for (final folder in visibleFolders)
            _DesktopFolderRow(
              folder: folder,
              onTap: () => _openFolder(folder.path),
            ),
          for (final file in visibleFiles)
            _DesktopFileRow(
              file: file,
              label: _labelForFile(file),
              size: _formatSize(file.size),
              selected: _selectMode ? _selected.contains(file.key) : null,
              onTap: _selectMode
                  ? () => _toggleSelect(file)
                  : () => _openFile(file),
              onLongPress: _selectMode
                  ? null
                  : () {
                      setState(() => _selectMode = true);
                      _toggleSelect(file);
                    },
              onDownload: () => _downloadFile(file),
              onDelete: () => _deleteFile(file),
            ),
        ],
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

class _DesktopFilesTopBar extends StatelessWidget {
  final TextEditingController controller;
  final bool searching;
  final int totalCount;
  final String username;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onUpload;
  final VoidCallback onLogout;

  const _DesktopFilesTopBar({
    required this.controller,
    required this.searching,
    required this.totalCount,
    required this.username,
    required this.onSearchChanged,
    required this.onUpload,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: _kSurface,
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: Row(
        children: [
          const Text(
            'RELIQUARY',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              height: 16 / 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: _kText,
            ),
          ),
          const SizedBox(width: 32),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: TextField(
                controller: controller,
                onChanged: onSearchChanged,
                style: const TextStyle(fontFamily: 'Inter', fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search files, folders, or tags...',
                  prefixIcon: const Icon(
                    Icons.search,
                    color: _kSecondary,
                    size: 20,
                  ),
                  filled: true,
                  fillColor: _kSurfaceLow,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _kBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _kPrimary),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 24),
          if (totalCount > 0)
            Text(
              '$totalCount ITEMS',
              style: const TextStyle(
                fontFamily: 'Geist',
                fontSize: 12,
                color: _kSecondary,
              ),
            ),
          const SizedBox(width: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _kPrimary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: onUpload,
            icon: const Icon(Icons.upload, size: 18),
            label: const Text('UPLOAD'),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            tooltip: username.isEmpty ? 'Account' : username,
            onSelected: (value) {
              if (value == 'logout') onLogout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'logout', child: Text('Logout')),
            ],
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.account_circle_outlined, color: _kText),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopFilesControls extends StatelessWidget {
  final bool selectMode;
  final int selectedCount;
  final bool canSelect;
  final VoidCallback onSelect;
  final VoidCallback onSelectAll;
  final VoidCallback? onDownload;
  final VoidCallback? onDelete;
  final VoidCallback onClearSelection;

  const _DesktopFilesControls({
    required this.selectMode,
    required this.selectedCount,
    required this.canSelect,
    required this.onSelect,
    required this.onSelectAll,
    required this.onDownload,
    required this.onDelete,
    required this.onClearSelection,
  });

  @override
  Widget build(BuildContext context) {
    if (selectMode) {
      return Row(
        children: [
          _PillButton(
            label: '$selectedCount selected',
            selected: true,
            onPressed: onClearSelection,
          ),
          const SizedBox(width: 8),
          _IconActionButton(
            icon: Icons.select_all,
            label: 'Select all',
            onPressed: onSelectAll,
          ),
          _IconActionButton(
            icon: Icons.download,
            label: 'Download',
            onPressed: onDownload,
          ),
          _IconActionButton(
            icon: Icons.delete_outline,
            label: 'Delete',
            color: _kPrimary,
            onPressed: onDelete,
          ),
        ],
      );
    }

    return Row(
      children: [
        _PillButton(label: 'All Files', selected: true, onPressed: () {}),
        const SizedBox(width: 8),
        _PillButton(label: 'Current Folder', onPressed: () {}),
        const Spacer(),
        _IconActionButton(
          icon: Icons.checklist,
          label: 'Select',
          onPressed: canSelect ? onSelect : null,
        ),
        _IconActionButton(icon: Icons.sort, label: 'Sort', onPressed: () {}),
      ],
    );
  }
}

class _PillButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  const _PillButton({
    required this.label,
    this.selected = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: selected ? _kPrimary : Colors.transparent,
        foregroundColor: selected ? Colors.white : _kSecondary,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.96,
        ),
      ),
    );
  }
}

class _IconActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback? onPressed;

  const _IconActionButton({
    required this.icon,
    required this.label,
    this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: label,
      onPressed: onPressed,
      icon: Icon(icon, size: 20, color: onPressed == null ? null : color),
    );
  }
}

class _DesktopListHeader extends StatelessWidget {
  const _DesktopListHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(
        color: _kSurfaceLow,
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: const Row(
        children: [
          Expanded(flex: 6, child: _HeaderCell('NAME')),
          Expanded(flex: 2, child: _HeaderCell('SIZE')),
          Expanded(flex: 3, child: _HeaderCell('DATE MODIFIED')),
          SizedBox(width: 96),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String label;

  const _HeaderCell(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.96,
        color: _kSecondary,
      ),
    );
  }
}

class _DesktopFolderRow extends StatelessWidget {
  final _FolderEntry folder;
  final VoidCallback onTap;

  const _DesktopFolderRow({required this.folder, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return _DesktopExplorerRow(
      onTap: onTap,
      leading: const _ExplorerIcon(icon: Icons.folder, tint: _kPrimary),
      title: folder.name,
      subtitle: 'Folder',
      size: '${folder.count} items',
      date: '-',
      actions: const SizedBox(width: 96),
    );
  }
}

class _DesktopFileRow extends StatelessWidget {
  final FileItem file;
  final String label;
  final String size;
  final bool? selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  const _DesktopFileRow({
    required this.file,
    required this.label,
    required this.size,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onDownload,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == true;
    final inSelectMode = selected != null;
    return _DesktopExplorerRow(
      onTap: onTap,
      onLongPress: onLongPress,
      selected: isSelected,
      leading: Stack(
        children: [
          _ExplorerIcon(
            icon: _iconForContentType(file.contentType),
            tint: _tintForContentType(file.contentType),
          ),
          if (inSelectMode)
            Positioned(
              right: -1,
              bottom: -1,
              child: Icon(
                isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 18,
                color: isSelected ? _kPrimary : _kSecondary,
              ),
            ),
        ],
      ),
      title: label,
      subtitle: _displayType(file.contentType),
      size: size,
      date: _formatDate(file.lastModified),
      actions: SizedBox(
        width: 96,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Download',
              onPressed: onDownload,
              icon: const Icon(Icons.download_outlined, size: 18),
            ),
            PopupMenuButton<String>(
              onSelected: (action) {
                if (action == 'details') onTap();
                if (action == 'delete') onDelete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'details', child: Text('Details')),
                PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete', style: TextStyle(color: _kPrimary)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForContentType(String contentType) {
    if (contentType.startsWith('image/')) return Icons.image_outlined;
    if (contentType.startsWith('video/')) return Icons.videocam_outlined;
    if (contentType.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (contentType.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (contentType.contains('zip') || contentType.contains('archive')) {
      return Icons.archive_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  Color _tintForContentType(String contentType) {
    if (contentType.startsWith('video/') || contentType.startsWith('audio/')) {
      return const Color(0xFF006860);
    }
    return _kPrimary;
  }

  String _displayType(String contentType) {
    final slash = contentType.indexOf('/');
    if (slash == -1) return contentType;
    return contentType.substring(0, slash).toUpperCase();
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }
}

class _DesktopExplorerRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final String subtitle;
  final String size;
  final String date;
  final Widget actions;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _DesktopExplorerRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.size,
    required this.date,
    required this.actions,
    this.selected = false,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFFFDAD8).withValues(alpha: 0.32)
              : null,
          border: const Border(bottom: BorderSide(color: _kBorder)),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 6,
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 16,
                            height: 24 / 16,
                            color: _kText,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Geist',
                            fontSize: 12,
                            color: _kSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(flex: 2, child: _MetaText(size)),
            Expanded(flex: 3, child: _MetaText(date)),
            actions,
          ],
        ),
      ),
    );
  }
}

class _ExplorerIcon extends StatelessWidget {
  final IconData icon;
  final Color tint;

  const _ExplorerIcon({required this.icon, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: tint, size: 22),
    );
  }
}

class _MetaText extends StatelessWidget {
  final String value;

  const _MetaText(this.value);

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontFamily: 'Inter',
        fontSize: 14,
        height: 20 / 14,
        color: _kSecondary,
      ),
    );
  }
}

class _DesktopEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  const _DesktopEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 72),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, size: 56, color: _kSecondary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 20,
              height: 28 / 20,
              fontWeight: FontWeight.w600,
              color: _kText,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              height: 20 / 14,
              color: _kSecondary,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 24), action!],
        ],
      ),
    );
  }
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
                  color: isSelected ? _kPrimary : const Color(0xFFE0E0E0),
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
                        ? _kPrimary
                        : Colors.white.withValues(alpha: 0.8),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? _kPrimary : Colors.grey,
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
