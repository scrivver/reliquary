import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mime/mime.dart';

import '../services/api_service.dart';
import '../services/file_picker_service.dart' as picker;

class UploadScreen extends StatefulWidget {
  final ApiService apiService;

  const UploadScreen({super.key, required this.apiService});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  List<PlatformFile> _selectedFiles = [];
  final Map<String, _UploadProgress> _progress = {};
  bool _uploading = false;

  Future<void> _pickFiles() async {
    try {
      final result = await picker.pickFiles(allowMultiple: true);

      if (result != null && result.files.isNotEmpty) {
        setState(() {
          _selectedFiles = result.files;
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

  Future<void> _uploadAll() async {
    if (_selectedFiles.isEmpty) return;

    setState(() => _uploading = true);

    for (final file in _selectedFiles) {
      final filename = file.name;
      setState(() {
        _progress[filename] =
            _UploadProgress(status: 'INITIATING...', fraction: 0);
      });

      try {
        final contentType =
            lookupMimeType(filename) ?? 'application/octet-stream';

        List<int> bytes;
        if (kIsWeb) {
          bytes = file.bytes!;
        } else {
          bytes = await file.xFile.readAsBytes();
        }

        await widget.apiService.uploadFile(
          filename,
          bytes,
          contentType,
          onProgress: (sent, total) {
            if (total > 0) {
              setState(() {
                _progress[filename] = _UploadProgress(
                  status: 'TRANSMITTING...',
                  fraction: sent / total,
                );
              });
            }
          },
        );

        setState(() {
          _progress[filename] =
              _UploadProgress(status: 'PRESERVED', fraction: 1.0, done: true);
        });
      } catch (e) {
        setState(() {
          _progress[filename] =
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
            // Drop zone style button — must use Material button for web
            // file picker to work (browser requires trusted user gesture)
            SizedBox(
              height: 120,
              child: OutlinedButton(
                onPressed: _uploading ? null : _pickFiles,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFE0E0E0), width: 2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_upload_outlined,
                        size: 36, color: Colors.grey[400]),
                    const SizedBox(height: 8),
                    Text(
                      'SELECT_FILES',
                      style: GoogleFonts.spaceMono(
                          fontSize: 12, color: Colors.grey),
                    ),
                    Text(
                      '${_selectedFiles.length} selected',
                      style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                    ),
                  ],
                ),
              ),
            ),
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
                  final progress = _progress[file.name];
                  return ListTile(
                    leading: Icon(
                      progress?.done == true
                          ? Icons.check_circle
                          : progress?.error == true
                              ? Icons.error
                              : Icons.insert_drive_file,
                      color: progress?.done == true
                          ? Colors.green
                          : progress?.error == true
                              ? const Color(0xFFEC3713)
                              : Colors.grey,
                      size: 20,
                    ),
                    title: Text(file.name,
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
                                    backgroundColor: const Color(0xFFE0E0E0),
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
