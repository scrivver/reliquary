import 'dart:io' show File;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mime/mime.dart';

import '../models/upload_file.dart';
import '../services/api_service.dart';
import '../services/file_picker_service.dart' as picker;

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pick files: $e')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pick folder: $e')),
      );
    }
  }

  Future<void> _uploadAll() async {
    if (_selectedFiles.isEmpty) return;

    setState(() => _uploading = true);

    for (final file in _selectedFiles) {
      final key = file.displayName;
      setState(() {
        _progress[key] =
            _UploadProgress(status: 'INITIATING...', fraction: 0);
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
          _progress[key] =
              _UploadProgress(status: 'FAILED: $e', error: true);
        });
      }
    }

    setState(() => _uploading = false);
  }

  @override
  Widget build(BuildContext context) {
    final allDone =
        _progress.isNotEmpty && _progress.values.every((p) => p.done);

    return Scaffold(
      appBar: AppBar(
        title: Text('DEPOSIT_ARTIFACTS',
            style: GoogleFonts.spaceMono(
                fontSize: 14, fontWeight: FontWeight.w700)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 100,
                    child: OutlinedButton(
                      onPressed: _uploading ? null : _pickFiles,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(
                            color: Color(0xFFE0E0E0), width: 2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.upload_file,
                              size: 28, color: Colors.grey[400]),
                          const SizedBox(height: 6),
                          Text('SELECT_FILES',
                              style: GoogleFonts.spaceMono(
                                  fontSize: 10, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 100,
                    child: OutlinedButton(
                      onPressed: _uploading ? null : _pickFolder,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(
                            color: Color(0xFFE0E0E0), width: 2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.folder_open,
                              size: 28, color: Colors.grey[400]),
                          const SizedBox(height: 6),
                          Text('SELECT_FOLDER',
                              style: GoogleFonts.spaceMono(
                                  fontSize: 10, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_selectedFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '${_selectedFiles.length} file(s) selected',
                style:
                    GoogleFonts.spaceMono(fontSize: 11, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 16),
            if (_selectedFiles.isNotEmpty)
              SizedBox(
                height: 48,
                child: FilledButton(
                  onPressed: _uploading ? null : _uploadAll,
                  child: Text(_uploading
                      ? 'TRANSMITTING...'
                      : 'INITIATE_DEPOSIT (${_selectedFiles.length})'),
                ),
              ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.separated(
                itemCount: _selectedFiles.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final file = _selectedFiles[index];
                  final key = file.displayName;
                  final progress = _progress[key];
                  return ListTile(
                    leading: Icon(
                      progress?.done == true
                          ? Icons.check_circle
                          : progress?.error == true
                              ? Icons.error
                              : file.relativePath != null
                                  ? Icons.folder
                                  : Icons.insert_drive_file,
                      color: progress?.done == true
                          ? Colors.green
                          : progress?.error == true
                              ? const Color(0xFFEC3713)
                              : Colors.grey,
                      size: 20,
                    ),
                    title: Text(file.displayName,
                        style: const TextStyle(fontSize: 13)),
                    subtitle: progress != null
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(progress.status,
                                  style: GoogleFonts.spaceMono(
                                      fontSize: 10, color: Colors.grey)),
                              if (progress.fraction != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: LinearProgressIndicator(
                                    value: progress.fraction,
                                    backgroundColor:
                                        const Color(0xFFE0E0E0),
                                    color: const Color(0xFFEC3713),
                                  ),
                                ),
                            ],
                          )
                        : Text(_formatSize(file.size),
                            style: GoogleFonts.spaceMono(
                                fontSize: 10, color: Colors.grey)),
                  );
                },
              ),
            ),
            if (allDone)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('RETURN_TO_VAULT'),
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
