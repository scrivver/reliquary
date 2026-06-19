import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../models/file_item.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/download_helper.dart' as dl;
import '../widgets/pdf_preview_frame.dart';
import 'responsive_page.dart';
import 'upload_screen.dart';

const _kPrimary = Color(0xFFB7102A);
const _kSurface = Color(0xFFF8F9FA);
const _kCard = Color(0xFFFFFFFF);
const _kBorder = Color(0xFFE5E5E5);
const _kText = Color(0xFF191C1D);
const _kSecondary = Color(0xFF5F5E5E);
const _kSurfaceLow = Color(0xFFF3F4F5);

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

enum _FilesSort {
  nameAsc('Name A-Z'),
  nameDesc('Name Z-A'),
  newest('Newest'),
  oldest('Oldest'),
  largest('Largest'),
  smallest('Smallest'),
  type('Type');

  final String label;

  const _FilesSort(this.label);
}

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
  bool _desktopGridView = true;
  _FilesSort _sort = _FilesSort.nameAsc;
  final Set<String> _selected = {};
  FileItem? _detailFile;

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
      if (_detailFile?.key == file.key) {
        setState(() => _detailFile = null);
      }
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
    if (isDesktopWidth(context)) {
      setState(() => _detailFile = file);
      return;
    }

    _showFileDetails(file);
  }

  Future<void> _previewFile(FileItem file) async {
    if (isDesktopWidth(context) || file.isPdf) {
      await _showPreviewModal(file);
      return;
    }

    if (file.isImage) {
      await _viewFullImage(file);
    }
  }

  Future<void> _showPreviewModal(FileItem file) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (dialogContext) {
        final size = MediaQuery.sizeOf(dialogContext);
        return Dialog(
          insetPadding: const EdgeInsets.all(40),
          backgroundColor: Colors.transparent,
          child: SizedBox(
            width: size.width * 0.82,
            height: size.height * 0.82,
            child: _PreviewModalContent(
              file: file,
              apiService: widget.apiService,
            ),
          ),
        );
      },
    );
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
          if (file.isPreviewable)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _previewFile(file);
              },
              child: const Text('PREVIEW'),
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
        body: Stack(
          children: [
            _buildDesktopBody(visibleFolders, visibleFiles, itemCount),
            _DesktopDetailsDrawer(
              file: _detailFile,
              size: _detailFile == null ? null : _formatSize(_detailFile!.size),
              apiService: widget.apiService,
              onClose: () => setState(() => _detailFile = null),
              onDownload: _detailFile == null
                  ? null
                  : () => _downloadFile(_detailFile!),
              onPreview: _detailFile == null || !_detailFile!.isPreviewable
                  ? null
                  : () => _previewFile(_detailFile!),
              onDelete: _detailFile == null
                  ? null
                  : () => _deleteFile(_detailFile!),
            ),
          ],
        ),
        floatingActionButton: _selectMode
            ? null
            : FloatingActionButton.extended(
                heroTag: 'desktop_upload_fab',
                backgroundColor: _kPrimary,
                foregroundColor: Colors.white,
                onPressed: _openUpload,
                icon: const Icon(Icons.upload),
                label: const Text('UPLOAD'),
              ),
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
                '${_selected.length} selected',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              )
            : _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search files...',
                  border: InputBorder.none,
                ),
                style: const TextStyle(fontFamily: 'Inter', fontSize: 16),
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
                      tooltip: 'Back',
                    ),
                  Expanded(
                    child: Text(
                      _currentPath.isEmpty
                          ? 'Files'
                          : _currentPath.split('/').last,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_username.isNotEmpty)
                    _MobileHeaderChip(label: _username, highlighted: true),
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
                        child: _MobileHeaderChip(label: '$_totalCount items'),
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
    return RefreshIndicator(
      color: _kPrimary,
      onRefresh: _loadFiles,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: DesktopPageFrame(
          maxWidth: 1440,
          padding: const EdgeInsets.fromLTRB(40, 40, 40, 96),
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
                      label: const Text('Back'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 24),
              _DesktopFilesSearchAndFilters(
                controller: _searchController,
                totalCount: _totalCount,
                onSearchChanged: (value) => setState(() {
                  _searching = value.isNotEmpty;
                  _searchQuery = value;
                }),
              ),
              const SizedBox(height: 24),
              _DesktopFilesControls(
                selectMode: _selectMode,
                selectedCount: _selected.length,
                canSelect: visibleFiles.isNotEmpty,
                onSelect: () => setState(() => _selectMode = true),
                onSelectAll: _selectAll,
                onDownload: _selected.isEmpty ? null : _downloadSelected,
                onDelete: _selected.isEmpty ? null : _deleteSelected,
                onClearSelection: _exitSelectMode,
                gridView: _desktopGridView,
                onToggleView: () =>
                    setState(() => _desktopGridView = !_desktopGridView),
                sort: _sort,
                onSortChanged: (sort) => setState(() => _sort = sort),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildDesktopList(
                      visibleFolders,
                      visibleFiles,
                      itemCount,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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

    if (_desktopGridView) {
      return _buildDesktopGrid(visibleFolders, visibleFiles);
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
              apiService: widget.apiService,
              selected: _selectMode ? _selected.contains(file.key) : null,
              highlighted: !_selectMode && _detailFile?.key == file.key,
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
              onPreview: file.isPreviewable ? () => _previewFile(file) : null,
              onDelete: () => _deleteFile(file),
            ),
        ],
      ),
    );
  }

  Widget _buildDesktopGrid(
    List<_FolderEntry> visibleFolders,
    List<FileItem> visibleFiles,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 1180
            ? 4
            : width >= 880
            ? 3
            : 2;

        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 24,
          mainAxisSpacing: 24,
          childAspectRatio: 1.08,
          children: [
            for (final folder in visibleFolders)
              _DesktopFolderCard(
                folder: folder,
                onTap: () => _openFolder(folder.path),
              ),
            for (final file in visibleFiles)
              _DesktopFileCard(
                file: file,
                label: _labelForFile(file),
                size: _formatSize(file.size),
                apiService: widget.apiService,
                selected: _selectMode ? _selected.contains(file.key) : null,
                highlighted: !_selectMode && _detailFile?.key == file.key,
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
                onPreview: file.isPreviewable ? () => _previewFile(file) : null,
                onDelete: () => _deleteFile(file),
              ),
          ],
        );
      },
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
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index < visibleFolders.length) {
            final folder = visibleFolders[index];
            return _MobileFolderRow(
              key: ValueKey('folder:${folder.path}'),
              folder: folder,
              onTap: () => _openFolder(folder.path),
            );
          }

          final file = visibleFiles[index - visibleFolders.length];
          final isSelected = _selected.contains(file.key);
          return _MobileFileRow(
            key: ValueKey('file:${file.key}'),
            file: file,
            label: _labelForFile(file),
            apiService: widget.apiService,
            size: _formatSize(file.size),
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
          ..sort(_compareFolders);
    return entries;
  }

  List<FileItem> _visibleFiles() {
    if (_isSearching) {
      final files = _files.where((file) {
        return _matchesSearch(file, _searchQuery);
      }).toList()..sort(_compareFiles);
      return files;
    }

    final prefix = _currentPath.isEmpty ? '' : '$_currentPath/';
    final files = _files.where((file) {
      final path = file.displayPath;
      if (!path.startsWith(prefix)) return false;
      return !path.substring(prefix.length).contains('/');
    }).toList()..sort(_compareFiles);
    return files;
  }

  int _compareFolders(_FolderEntry a, _FolderEntry b) {
    final result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return _sort == _FilesSort.nameDesc ? -result : result;
  }

  int _compareFiles(FileItem a, FileItem b) {
    int result;
    switch (_sort) {
      case _FilesSort.nameAsc:
        result = _labelForFile(
          a,
        ).toLowerCase().compareTo(_labelForFile(b).toLowerCase());
      case _FilesSort.nameDesc:
        result = _labelForFile(
          b,
        ).toLowerCase().compareTo(_labelForFile(a).toLowerCase());
      case _FilesSort.newest:
        result = b.lastModified.compareTo(a.lastModified);
      case _FilesSort.oldest:
        result = a.lastModified.compareTo(b.lastModified);
      case _FilesSort.largest:
        result = b.size.compareTo(a.size);
      case _FilesSort.smallest:
        result = a.size.compareTo(b.size);
      case _FilesSort.type:
        result = a.contentType.toLowerCase().compareTo(
          b.contentType.toLowerCase(),
        );
    }

    if (result != 0) return result;
    return a.displayPath.toLowerCase().compareTo(b.displayPath.toLowerCase());
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
      _detailFile = null;
    });
  }

  void _goUpFolder() {
    setState(() {
      final slash = _currentPath.lastIndexOf('/');
      _currentPath = slash == -1 ? '' : _currentPath.substring(0, slash);
      _selectMode = false;
      _selected.clear();
      _detailFile = null;
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

class _MobileHeaderChip extends StatelessWidget {
  final String label;
  final bool highlighted;

  const _MobileHeaderChip({required this.label, this.highlighted = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted ? _kPrimary.withValues(alpha: 0.1) : _kSurfaceLow,
        border: Border.all(color: highlighted ? _kPrimary : _kBorder),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          height: 16 / 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.88,
          color: highlighted ? _kPrimary : _kSecondary,
        ),
      ),
    );
  }
}

class _DesktopFilesSearchAndFilters extends StatelessWidget {
  final TextEditingController controller;
  final int totalCount;
  final ValueChanged<String> onSearchChanged;

  const _DesktopFilesSearchAndFilters({
    required this.controller,
    required this.totalCount,
    required this.onSearchChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
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
        const SizedBox(width: 16),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: _kSurfaceLow,
            border: Border.all(color: _kBorder),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            children: [
              _PillButton(label: 'All Files', selected: true, onPressed: () {}),
            ],
          ),
        ),
        if (totalCount > 0) ...[
          const SizedBox(width: 16),
          Text(
            '$totalCount ITEMS',
            style: const TextStyle(
              fontFamily: 'Geist',
              fontSize: 12,
              color: _kSecondary,
            ),
          ),
        ],
      ],
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
  final bool gridView;
  final VoidCallback onToggleView;
  final _FilesSort sort;
  final ValueChanged<_FilesSort> onSortChanged;

  const _DesktopFilesControls({
    required this.selectMode,
    required this.selectedCount,
    required this.canSelect,
    required this.onSelect,
    required this.onSelectAll,
    required this.onDownload,
    required this.onDelete,
    required this.onClearSelection,
    required this.gridView,
    required this.onToggleView,
    required this.sort,
    required this.onSortChanged,
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
        const Spacer(),
        _IconActionButton(
          icon: gridView ? Icons.view_list : Icons.grid_view,
          label: gridView ? 'List view' : 'Grid view',
          color: _kPrimary,
          onPressed: onToggleView,
        ),
        _IconActionButton(
          icon: Icons.checklist,
          label: 'Select',
          onPressed: canSelect ? onSelect : null,
        ),
        _SortMenuButton(sort: sort, onSortChanged: onSortChanged),
      ],
    );
  }
}

class _SortMenuButton extends StatelessWidget {
  final _FilesSort sort;
  final ValueChanged<_FilesSort> onSortChanged;

  const _SortMenuButton({required this.sort, required this.onSortChanged});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_FilesSort>(
      tooltip: 'Sort',
      initialValue: sort,
      onSelected: onSortChanged,
      itemBuilder: (_) => [
        for (final option in _FilesSort.values)
          PopupMenuItem(
            value: option,
            child: Row(
              children: [
                Icon(
                  option == sort ? Icons.check : Icons.sort,
                  size: 18,
                  color: option == sort ? _kPrimary : _kSecondary,
                ),
                const SizedBox(width: 10),
                Text(option.label),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sort, size: 20, color: _kPrimary),
            const SizedBox(width: 6),
            Text(
              sort.label,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _kPrimary,
              ),
            ),
          ],
        ),
      ),
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
  final ApiService apiService;
  final bool? selected;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onDownload;
  final VoidCallback? onPreview;
  final VoidCallback onDelete;

  const _DesktopFileRow({
    required this.file,
    required this.label,
    required this.size,
    required this.apiService,
    required this.selected,
    this.highlighted = false,
    required this.onTap,
    required this.onLongPress,
    required this.onDownload,
    required this.onPreview,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == true;
    final inSelectMode = selected != null;
    return _DesktopExplorerRow(
      onTap: onTap,
      onLongPress: onLongPress,
      selected: isSelected || highlighted,
      leading: Stack(
        children: [
          _DesktopFileThumbnail(
            file: file,
            apiService: apiService,
            size: 40,
            borderRadius: 8,
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
        width: onPreview == null ? 96 : 144,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (onPreview != null)
              IconButton(
                tooltip: 'Preview',
                onPressed: onPreview,
                icon: const Icon(Icons.visibility_outlined, size: 18),
              ),
            IconButton(
              tooltip: 'Download',
              onPressed: onDownload,
              icon: const Icon(Icons.download_outlined, size: 18),
            ),
            PopupMenuButton<String>(
              onSelected: (action) {
                if (action == 'details') onTap();
                if (action == 'preview') onPreview?.call();
                if (action == 'delete') onDelete();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'details', child: Text('Details')),
                if (onPreview != null)
                  const PopupMenuItem(value: 'preview', child: Text('Preview')),
                const PopupMenuItem(
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

class _DesktopFolderCard extends StatelessWidget {
  final _FolderEntry folder;
  final VoidCallback onTap;

  const _DesktopFolderCard({required this.folder, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _kCard,
            border: Border.all(color: _kBorder),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: _kSurfaceLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child: Icon(Icons.folder, size: 54, color: _kPrimary),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  height: 20 / 15,
                  fontWeight: FontWeight.w600,
                  color: _kText,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${folder.count} items',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  height: 18 / 13,
                  color: _kSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopFileCard extends StatelessWidget {
  final FileItem file;
  final String label;
  final String size;
  final ApiService apiService;
  final bool? selected;
  final bool highlighted;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onDownload;
  final VoidCallback? onPreview;
  final VoidCallback onDelete;

  const _DesktopFileCard({
    required this.file,
    required this.label,
    required this.size,
    required this.apiService,
    required this.selected,
    this.highlighted = false,
    required this.onTap,
    required this.onLongPress,
    required this.onDownload,
    required this.onPreview,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == true;
    final inSelectMode = selected != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _kCard,
            border: Border.all(
              color: isSelected || highlighted ? _kPrimary : _kBorder,
              width: isSelected || highlighted ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _DesktopFilePreview(
                        file: file,
                        apiService: apiService,
                        height: null,
                      ),
                    ),
                    if (inSelectMode)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Icon(
                          isSelected
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          size: 22,
                          color: isSelected ? _kPrimary : _kSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 15,
                            height: 20 / 15,
                            fontWeight: FontWeight.w600,
                            color: _kText,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$size - ${_formatDate(file.lastModified)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            height: 18 / 13,
                            color: _kSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.more_vert, color: _kSecondary),
                    onSelected: (action) {
                      if (action == 'details') onTap();
                      if (action == 'preview') onPreview?.call();
                      if (action == 'download') onDownload();
                      if (action == 'delete') onDelete();
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'details',
                        child: Text('Details'),
                      ),
                      if (onPreview != null)
                        const PopupMenuItem(
                          value: 'preview',
                          child: Text('Preview'),
                        ),
                      const PopupMenuItem(
                        value: 'download',
                        child: Text('Download'),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          'Delete',
                          style: TextStyle(color: _kPrimary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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

class _DesktopFileThumbnail extends StatefulWidget {
  final FileItem file;
  final ApiService apiService;
  final double size;
  final double borderRadius;

  const _DesktopFileThumbnail({
    required this.file,
    required this.apiService,
    required this.size,
    required this.borderRadius,
  });

  @override
  State<_DesktopFileThumbnail> createState() => _DesktopFileThumbnailState();
}

class _DesktopFileThumbnailState extends State<_DesktopFileThumbnail> {
  String? _url;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  @override
  void didUpdateWidget(covariant _DesktopFileThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.key != widget.file.key ||
        oldWidget.file.thumbnailKey != widget.file.thumbnailKey) {
      _loadPreview();
    }
  }

  Future<void> _loadPreview() async {
    final fileKey = widget.file.key;
    final previewKey =
        widget.file.thumbnailKey ?? (widget.file.isImage ? fileKey : null);
    if (previewKey == null) {
      if (mounted) setState(() => _url = null);
      return;
    }

    setState(() => _url = null);
    try {
      final url = await widget.apiService.presignDownload(previewKey);
      if (!mounted || widget.file.key != fileKey) return;
      setState(() => _url = url);
    } catch (_) {
      if (mounted && widget.file.key == fileKey) {
        setState(() => _url = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tint = _tintForContentType(widget.file.contentType);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
        child: _url == null
            ? Icon(
                _iconForContentType(widget.file.contentType),
                color: tint,
                size: widget.size * 0.55,
              )
            : Image.network(
                _url!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                  _iconForContentType(widget.file.contentType),
                  color: tint,
                  size: widget.size * 0.55,
                ),
              ),
      ),
    );
  }
}

class _DesktopFilePreview extends StatefulWidget {
  final FileItem file;
  final ApiService apiService;
  final double? height;

  const _DesktopFilePreview({
    required this.file,
    required this.apiService,
    this.height = 180,
  });

  @override
  State<_DesktopFilePreview> createState() => _DesktopFilePreviewState();
}

class _DesktopFilePreviewState extends State<_DesktopFilePreview> {
  String? _url;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  @override
  void didUpdateWidget(covariant _DesktopFilePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.key != widget.file.key ||
        oldWidget.file.thumbnailKey != widget.file.thumbnailKey) {
      _loadPreview();
    }
  }

  Future<void> _loadPreview() async {
    final fileKey = widget.file.key;
    final previewKey =
        widget.file.thumbnailKey ?? (widget.file.isImage ? fileKey : null);
    if (previewKey == null) {
      if (mounted) setState(() => _url = null);
      return;
    }

    setState(() => _url = null);
    try {
      final url = await widget.apiService.presignDownload(previewKey);
      if (!mounted || widget.file.key != fileKey) return;
      setState(() => _url = url);
    } catch (_) {
      if (mounted && widget.file.key == fileKey) {
        setState(() => _url = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tint = _tintForContentType(widget.file.contentType);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: _kSurfaceLow,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        child: _url == null
            ? Center(
                child: Icon(
                  _iconForContentType(widget.file.contentType),
                  size: 54,
                  color: tint,
                ),
              )
            : Image.network(
                _url!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Center(
                  child: Icon(
                    _iconForContentType(widget.file.contentType),
                    size: 54,
                    color: tint,
                  ),
                ),
              ),
      ),
    );
  }
}

class _PreviewModalContent extends StatefulWidget {
  final FileItem file;
  final ApiService apiService;

  const _PreviewModalContent({required this.file, required this.apiService});

  @override
  State<_PreviewModalContent> createState() => _PreviewModalContentState();
}

class _PreviewModalContentState extends State<_PreviewModalContent> {
  String? _url;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant _PreviewModalContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.key != widget.file.key) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    final fileKey = widget.file.key;
    setState(() {
      _url = null;
      _error = null;
    });

    try {
      final url = await widget.apiService.presignDownload(fileKey);
      if (!mounted || widget.file.key != fileKey) return;
      setState(() => _url = url);
    } catch (e) {
      if (!mounted || widget.file.key != fileKey) return;
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(child: _buildImage());
  }

  Widget _buildImage() {
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined, size: 56, color: _kPrimary),
          const SizedBox(height: 12),
          const Text(
            'Failed to load preview',
            style: TextStyle(fontFamily: 'Inter', color: _kText),
          ),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: _loadImage, child: const Text('Retry')),
        ],
      );
    }

    final url = _url;
    if (url == null) {
      return const CircularProgressIndicator(color: _kPrimary);
    }

    if (widget.file.isPdf) {
      return PdfPreviewFrame(url: url);
    }

    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 5,
      child: Image.network(
        url,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return const CircularProgressIndicator(color: _kPrimary);
        },
        errorBuilder: (_, _, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined, size: 56, color: _kPrimary),
            const SizedBox(height: 12),
            const Text(
              'Failed to load preview',
              style: TextStyle(fontFamily: 'Inter', color: _kText),
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _loadImage, child: const Text('Retry')),
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

class _DesktopDetailsDrawer extends StatelessWidget {
  final FileItem? file;
  final String? size;
  final ApiService apiService;
  final VoidCallback onClose;
  final VoidCallback? onDownload;
  final VoidCallback? onPreview;
  final VoidCallback? onDelete;

  const _DesktopDetailsDrawer({
    required this.file,
    required this.size,
    required this.apiService,
    required this.onClose,
    required this.onDownload,
    required this.onPreview,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final selectedFile = file;
    return IgnorePointer(
      ignoring: selectedFile == null,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        offset: selectedFile == null ? const Offset(1, 0) : Offset.zero,
        child: Align(
          alignment: Alignment.centerRight,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: selectedFile == null ? 0 : 1,
            child: SizedBox(
              width: 360,
              height: double.infinity,
              child: Material(
                color: _kCard,
                elevation: 16,
                shadowColor: Colors.black.withValues(alpha: 0.18),
                child: selectedFile == null
                    ? const SizedBox.shrink()
                    : _DesktopDetailsContent(
                        file: selectedFile,
                        size: size ?? '',
                        apiService: apiService,
                        onClose: onClose,
                        onDownload: onDownload,
                        onPreview: onPreview,
                        onDelete: onDelete,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopDetailsContent extends StatelessWidget {
  final FileItem file;
  final String size;
  final ApiService apiService;
  final VoidCallback onClose;
  final VoidCallback? onDownload;
  final VoidCallback? onPreview;
  final VoidCallback? onDelete;

  const _DesktopDetailsContent({
    required this.file,
    required this.size,
    required this.apiService,
    required this.onClose,
    required this.onDownload,
    required this.onPreview,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: _kBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 18),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'DETAILS',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      height: 16 / 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.96,
                      color: _kText,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close details',
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 20, color: _kSecondary),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _kBorder),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _DesktopFilePreview(file: file, apiService: apiService),
                  const SizedBox(height: 20),
                  Text(
                    file.filename,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 20,
                      height: 28 / 20,
                      fontWeight: FontWeight.w600,
                      color: _kText,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    runSpacing: 16,
                    spacing: 20,
                    children: [
                      _DetailField(
                        label: 'TYPE',
                        value: _displayType(file.contentType),
                      ),
                      _DetailField(label: 'SIZE', value: size),
                      _DetailField(
                        label: 'MODIFIED',
                        value: _formatDate(file.lastModified),
                      ),
                      _DetailField(label: 'LOCATION', value: file.displayPath),
                      if (file.uploadDate != null)
                        _DetailField(
                          label: 'UPLOADED',
                          value: file.uploadDate!,
                        ),
                      if (file.checksum != null)
                        _DetailField(
                          label: 'SHA-256',
                          value: '${file.checksum!.substring(0, 16)}...',
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: _kSurfaceLow,
              border: Border(top: BorderSide(color: _kBorder)),
            ),
            child: Row(
              children: [
                if (onPreview != null) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _kText,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: _kBorder),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: onPreview,
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      label: const Text('PREVIEW'),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _kText,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: onDownload,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('DOWNLOAD'),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Delete',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, color: _kPrimary),
                  style: IconButton.styleFrom(
                    backgroundColor: _kCard,
                    side: const BorderSide(color: _kBorder),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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

class _DetailField extends StatelessWidget {
  final String label;
  final String value;

  const _DetailField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              height: 16 / 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.96,
              color: _kSecondary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              height: 20 / 14,
              color: _kText,
            ),
          ),
        ],
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

class _MobileFolderRow extends StatelessWidget {
  final _FolderEntry folder;
  final VoidCallback onTap;

  const _MobileFolderRow({
    super.key,
    required this.folder,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: _kCard,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: _kBorder),
      ),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: const _ExplorerIcon(icon: Icons.folder, tint: _kPrimary),
        title: Text(
          folder.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: _kText,
          ),
        ),
        subtitle: Text(
          '${folder.count} items',
          style: const TextStyle(
            fontFamily: 'Geist',
            fontSize: 12,
            color: _kSecondary,
          ),
        ),
        trailing: const Icon(Icons.chevron_right, color: _kSecondary),
      ),
    );
  }
}

class _MobileFileRow extends StatelessWidget {
  final FileItem file;
  final String label;
  final ApiService apiService;
  final String size;
  final bool? selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _MobileFileRow({
    super.key,
    required this.file,
    required this.label,
    required this.apiService,
    required this.size,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == true;
    final inSelectMode = selected != null;
    return Card(
      elevation: 0,
      color: isSelected
          ? const Color(0xFFFFDAD8).withValues(alpha: 0.32)
          : _kCard,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: isSelected ? _kPrimary : _kBorder),
      ),
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: Stack(
          children: [
            _DesktopFileThumbnail(
              file: file,
              apiService: apiService,
              size: 42,
              borderRadius: 8,
            ),
            if (inSelectMode)
              Positioned(
                right: -1,
                bottom: -1,
                child: Icon(
                  isSelected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: isSelected ? _kPrimary : _kSecondary,
                ),
              ),
          ],
        ),
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: _kText,
          ),
        ),
        subtitle: Text(
          '$size - ${_displayType(file.contentType)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Geist',
            fontSize: 12,
            color: _kSecondary,
          ),
        ),
        trailing: inSelectMode
            ? null
            : const Icon(Icons.chevron_right, color: _kSecondary),
      ),
    );
  }

  String _displayType(String contentType) {
    final slash = contentType.indexOf('/');
    if (slash == -1) return contentType;
    return contentType.substring(0, slash).toUpperCase();
  }
}
