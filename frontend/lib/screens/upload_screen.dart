import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';

import '../models/upload_file.dart';
import '../services/api_service.dart';
import '../services/file_picker_service.dart' as picker;

const _kPrimary = Color(0xFFB7102A);
const _kSurfaceLow = Color(0xFFF3F4F5);
const _kCard = Color(0xFFFFFFFF);
const _kBorder = Color(0xFFE5E5E5);
const _kText = Color(0xFF191C1D);
const _kSecondary = Color(0xFF5F5E5E);
const _kSuccess = Color(0xFF006860);

class UploadScreen extends StatefulWidget {
  final ApiService apiService;

  const UploadScreen({super.key, required this.apiService});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  List<UploadFile> _selectedFiles = [];
  final Map<String, _UploadProgress> _progress = {};
  bool _uploading = false;

  Future<void> _pickFiles() async {
    try {
      final result = await picker.pickFiles(allowMultiple: true);
      if (result != null && result.isNotEmpty) {
        setState(() {
          _selectedFiles = result;
          _progress.clear();
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to pick files: $e')));
    }
  }

  Future<void> _pickFolder() async {
    try {
      final result = await picker.pickFolder();
      if (result != null && result.isNotEmpty) {
        setState(() {
          _selectedFiles = result;
          _progress.clear();
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to pick folder: $e')));
    }
  }

  Future<void> _uploadAll() async {
    if (_selectedFiles.isEmpty) return;

    setState(() => _uploading = true);

    for (final file in _selectedFiles) {
      final key = file.displayName;
      setState(() {
        _progress[key] = _UploadProgress(status: 'INITIATING...', fraction: 0);
      });

      try {
        final contentType =
            lookupMimeType(file.name) ?? 'application/octet-stream';

        List<int> bytes;
        if (file.bytes != null) {
          bytes = file.bytes!;
        } else if (!kIsWeb && file.filePath != null) {
          bytes = await File(file.filePath!).readAsBytes();
        } else {
          throw Exception('No file data available');
        }

        final result = await widget.apiService.uploadFile(
          file.name,
          bytes,
          contentType,
          relativePath: file.relativePath,
          onProgress: (sent, total) {
            if (total > 0) {
              setState(() {
                _progress[key] = _UploadProgress(
                  status: 'TRANSMITTING...',
                  fraction: sent / total,
                );
              });
            }
          },
        );

        setState(() {
          _progress[key] = _UploadProgress(
            status: result.duplicate ? 'DUPLICATE_SKIPPED' : 'PRESERVED',
            fraction: 1.0,
            done: true,
          );
        });
      } catch (e) {
        setState(() {
          _progress[key] = _UploadProgress(status: 'FAILED: $e', error: true);
        });
      }
    }

    setState(() => _uploading = false);
  }

  @override
  Widget build(BuildContext context) {
    final allDone =
        _progress.isNotEmpty && _progress.values.every((p) => p.done);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
      child: Material(
        color: _kCard,
        elevation: 0,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 24, 24, 24),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Upload Files',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 20,
                        height: 28 / 20,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        color: _kText,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, color: _kSecondary),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: _kBorder),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _UploadDropZone(
                      uploading: _uploading,
                      onPickFiles: _pickFiles,
                      onPickFolder: _pickFolder,
                    ),
                    if (_selectedFiles.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Text(
                        '${_selectedFiles.length} file(s) selected',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          height: 20 / 14,
                          color: _kSecondary,
                        ),
                      ),
                      const SizedBox(height: 24),
                      ..._selectedFiles.map((file) {
                        final key = file.displayName;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _UploadProgressRow(
                            file: file,
                            progress: _progress[key],
                            sizeLabel: _formatSize(file.size),
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(32, 20, 32, 20),
              decoration: const BoxDecoration(
                color: _kSurfaceLow,
                border: Border(top: BorderSide(color: _kBorder)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _uploading
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w600,
                        color: _kSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: _kPrimary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: _uploading || _selectedFiles.isEmpty
                        ? null
                        : _uploadAll,
                    child: Text(
                      _uploading ? 'Uploading...' : 'Upload All',
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (allDone) ...[
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                  ],
                ],
              ),
            ),
          ],
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

class _UploadDropZone extends StatelessWidget {
  final bool uploading;
  final VoidCallback onPickFiles;
  final VoidCallback onPickFolder;

  const _UploadDropZone({
    required this.uploading,
    required this.onPickFiles,
    required this.onPickFolder,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: uploading ? null : onPickFiles,
      child: Container(
        padding: const EdgeInsets.all(48),
        decoration: BoxDecoration(
          color: _kSurfaceLow.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kBorder, width: 2),
        ),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: _kPrimary.withValues(alpha: 0.06),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cloud_upload, color: _kPrimary, size: 36),
            ),
            const SizedBox(height: 16),
            const Text.rich(
              TextSpan(
                text: 'Drag and drop files here or ',
                children: [
                  TextSpan(
                    text: 'click to browse',
                    style: TextStyle(
                      color: _kPrimary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 16,
                height: 24 / 16,
                fontWeight: FontWeight.w600,
                color: _kText,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Choose individual files or import an entire folder.',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                height: 20 / 14,
                color: _kSecondary,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: uploading ? null : onPickFiles,
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('Select files'),
                ),
                OutlinedButton.icon(
                  onPressed: uploading ? null : onPickFolder,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Select folder'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UploadProgressRow extends StatelessWidget {
  final UploadFile file;
  final _UploadProgress? progress;
  final String sizeLabel;

  const _UploadProgressRow({
    required this.file,
    required this.progress,
    required this.sizeLabel,
  });

  @override
  Widget build(BuildContext context) {
    final done = progress?.done == true;
    final error = progress?.error == true;
    final color = error
        ? _kPrimary
        : done
        ? _kSuccess
        : _kPrimary;
    final status = progress?.status ?? 'Ready';
    final fraction = progress?.fraction;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: done ? _kSurfaceLow : _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              done
                  ? Icons.check_circle_outline
                  : error
                  ? Icons.error_outline
                  : file.relativePath != null
                  ? Icons.folder_outlined
                  : Icons.insert_drive_file_outlined,
              color: color,
              size: 22,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        file.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _kText,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      done ? 'Success' : status,
                      style: TextStyle(
                        fontFamily: 'Geist',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: fraction ?? (done ? 1 : 0),
                          minHeight: 6,
                          backgroundColor: _kBorder,
                          color: color,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      sizeLabel,
                      style: const TextStyle(
                        fontFamily: 'Geist',
                        fontSize: 12,
                        color: _kSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UploadProgress {
  final String status;
  final double? fraction;
  final bool done;
  final bool error;

  _UploadProgress({
    required this.status,
    this.fraction,
    this.done = false,
    this.error = false,
  });
}
