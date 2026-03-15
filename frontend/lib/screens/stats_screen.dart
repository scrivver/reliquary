import 'package:flutter/material.dart';

import '../services/api_service.dart';

class StatsScreen extends StatefulWidget {
  final ApiService apiService;

  const StatsScreen({super.key, required this.apiService});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  Map<String, dynamic>? _stats;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stats = await widget.apiService.getStats();
      if (mounted) setState(() { _stats = stats; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = 'Failed to load stats'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Storage Analytics')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 16),
                      FilledButton(
                          onPressed: _loadStats, child: const Text('Retry')),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadStats,
                  child: _buildStats(),
                ),
    );
  }

  Widget _buildStats() {
    final stats = _stats!;
    final totalSize = (stats['total_size'] as num).toInt();
    final fileCount = (stats['file_count'] as num).toInt();
    final archiveCount = (stats['archive_count'] as num).toInt();
    final archiveSize = (stats['archive_size'] as num).toInt();
    final byType = (stats['by_type'] as Map<String, dynamic>?) ?? {};
    final byMonth = (stats['by_month'] as Map<String, dynamic>?) ?? {};

    // Sort months in reverse chronological order.
    final sortedMonths = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Overview cards
        _SectionTitle(title: 'Overview'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StatCard(
              icon: Icons.folder,
              label: 'Active Files',
              value: '$fileCount',
              subtitle: _formatSize(totalSize),
            ),
            _StatCard(
              icon: Icons.archive,
              label: 'Archived',
              value: '$archiveCount',
              subtitle: _formatSize(archiveSize),
            ),
            _StatCard(
              icon: Icons.storage,
              label: 'Total Storage',
              value: _formatSize(totalSize + archiveSize),
              subtitle: '${fileCount + archiveCount} files',
            ),
          ],
        ),

        // By type
        if (byType.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionTitle(title: 'Files by Type'),
          const SizedBox(height: 8),
          ...byType.entries.map((e) => _TypeRow(
                type: e.key,
                count: (e.value as num).toInt(),
                total: fileCount,
              )),
        ],

        // By month
        if (sortedMonths.isNotEmpty) ...[
          const SizedBox(height: 24),
          _SectionTitle(title: 'Uploads by Month'),
          const SizedBox(height: 8),
          ...sortedMonths.map((month) => _MonthRow(
                month: month,
                count: (byMonth[month] as num).toInt(),
              )),
        ],
      ],
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(title, style: Theme.of(context).textTheme.titleMedium);
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String subtitle;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            Text(value,
                style: Theme.of(context).textTheme.headlineSmall),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            )),
          ],
        ),
      ),
    );
  }
}

class _TypeRow extends StatelessWidget {
  final String type;
  final int count;
  final int total;

  const _TypeRow({
    required this.type,
    required this.count,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = total > 0 ? count / total : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(_iconForType(type), size: 20, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Text(type),
          ),
          Expanded(
            flex: 3,
            child: LinearProgressIndicator(value: fraction),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 40,
            child: Text('$count', textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'image':
        return Icons.image;
      case 'video':
        return Icons.videocam;
      case 'audio':
        return Icons.audiotrack;
      case 'application':
        return Icons.insert_drive_file;
      default:
        return Icons.description;
    }
  }
}

class _MonthRow extends StatelessWidget {
  final String month;
  final int count;

  const _MonthRow({required this.month, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.calendar_month, size: 20, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(child: Text(month)),
          Text('$count files'),
        ],
      ),
    );
  }
}
