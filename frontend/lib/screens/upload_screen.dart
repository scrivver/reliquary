import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';

import '../services/api_service.dart';

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
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
      withData: kIsWeb,
    );

    if (result != null) {
      setState(() {
        _selectedFiles = result.files;
        _progress.clear();
      });
    }
  }

  Future<void> _uploadAll() async {
    if (_selectedFiles.isEmpty) return;

    setState(() => _uploading = true);

    for (final file in _selectedFiles) {
      final filename = file.name;
      setState(() {
        _progress[filename] = _UploadProgress(status: 'Requesting URL...');
      });

      try {
        final contentType =
            lookupMimeType(filename) ?? 'application/octet-stream';

        setState(() {
          _progress[filename] =
              _UploadProgress(status: 'Uploading...', fraction: 0);
        });

        // Read file bytes
        List<int> bytes;
        if (kIsWeb) {
          bytes = file.bytes!;
        } else {
          bytes = await file.xFile.readAsBytes();
        }

        // Upload through backend
        await widget.apiService.uploadFile(
          filename,
          bytes,
          contentType,
          onProgress: (sent, total) {
            if (total > 0) {
              setState(() {
                _progress[filename] = _UploadProgress(
                  status: 'Uploading...',
                  fraction: sent / total,
                );
              });
            }
          },
        );

        setState(() {
          _progress[filename] =
              _UploadProgress(status: 'Done', fraction: 1.0, done: true);
        });
      } catch (e) {
        setState(() {
          _progress[filename] =
              _UploadProgress(status: 'Failed: $e', error: true);
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
      appBar: AppBar(title: const Text('Upload')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: _uploading ? null : _pickFiles,
              icon: const Icon(Icons.folder_open),
              label: const Text('Select Files'),
            ),
            const SizedBox(height: 8),
            Text('${_selectedFiles.length} file(s) selected'),
            const SizedBox(height: 16),
            if (_selectedFiles.isNotEmpty)
              FilledButton.icon(
                onPressed: _uploading ? null : _uploadAll,
                icon: const Icon(Icons.cloud_upload),
                label: Text(_uploading ? 'Uploading...' : 'Upload All'),
              ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: _selectedFiles.length,
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
                              ? Colors.red
                              : null,
                    ),
                    title: Text(file.name),
                    subtitle: progress != null
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(progress.status),
                              if (progress.fraction != null)
                                LinearProgressIndicator(
                                    value: progress.fraction),
                            ],
                          )
                        : Text(_formatSize(file.size)),
                  );
                },
              ),
            ),
            if (allDone)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back to Gallery'),
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
