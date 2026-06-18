import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'responsive_page.dart';

const _kPrimary = Color(0xFFB7102A);
const _kSurface = Color(0xFFF8F9FA);
const _kCard = Color(0xFFFFFFFF);
const _kBorder = Color(0xFFE5E5E5);
const _kText = Color(0xFF191C1D);
const _kSecondary = Color(0xFF5F5E5E);

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
      if (mounted) {
        setState(() {
          _stats = stats;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load stats';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = isDesktopWidth(context);
    return Scaffold(
      appBar: isDesktop
          ? null
          : AppBar(
              title: Text(
                'Vault Status',
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ),
      backgroundColor: _kSurface,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _kPrimary))
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, style: const TextStyle(fontFamily: 'Inter')),
                  const SizedBox(height: 16),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: _kPrimary),
                    onPressed: _loadStats,
                    child: Text(
                      'RETRY',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              color: _kPrimary,
              onRefresh: _loadStats,
              child: _buildStats(),
            ),
    );
  }

  Widget _buildStats() {
    final stats = _stats!;
    final totalSize = (stats['total_size'] as num).toInt();
    final fileCount = (stats['file_count'] as num).toInt();
    final byType = (stats['by_type'] as Map<String, dynamic>?) ?? {};
    final byMonth = (stats['by_month'] as Map<String, dynamic>?) ?? {};

    // Sort months in reverse chronological order.
    final sortedMonths = byMonth.keys.toList()..sort((a, b) => b.compareTo(a));

    if (isDesktopWidth(context)) {
      return _buildDesktopStats(
        totalSize: totalSize,
        fileCount: fileCount,
        byType: byType,
        sortedMonths: sortedMonths,
        byMonth: byMonth,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StatusSummaryCard(
          icon: Icons.folder_zip_outlined,
          label: 'ACTIVE OBJECTS',
          value: _formatCount(fileCount),
          subtitle: 'Archived files across all containers',
          footerLabel: 'TOTAL SIZE',
          footerValue: _formatSize(totalSize),
        ),
        const SizedBox(height: 16),
        _StorageCard(totalSize: totalSize, fileCount: fileCount),
        const SizedBox(height: 16),
        _ArchiveHealthCard(
          byType: byType,
          sortedMonths: sortedMonths,
          byMonth: byMonth,
          fileCount: fileCount,
        ),
      ],
    );
  }

  Widget _buildDesktopStats({
    required int totalSize,
    required int fileCount,
    required Map<String, dynamic> byType,
    required List<String> sortedMonths,
    required Map<String, dynamic> byMonth,
  }) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: DesktopPageFrame(
        maxWidth: 1440,
        padding: const EdgeInsets.fromLTRB(40, 40, 40, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Vault Status',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 48,
                          height: 56 / 48,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.96,
                          color: _kText,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Comprehensive health and distribution report for the primary archive.',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 16,
                          height: 24 / 16,
                          letterSpacing: 0.16,
                          color: _kSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                OutlinedButton.icon(
                  onPressed: _loadStats,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh'),
                ),
              ],
            ),
            const SizedBox(height: 48),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SizedBox(
                    height: 320,
                    child: _StatusSummaryCard(
                      icon: Icons.folder_zip_outlined,
                      label: 'ACTIVE OBJECTS',
                      value: _formatCount(fileCount),
                      subtitle: 'Archived files across all containers',
                      footerLabel: 'TOTAL SIZE',
                      footerValue: _formatSize(totalSize),
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: SizedBox(
                    height: 320,
                    child: _StorageCard(
                      totalSize: totalSize,
                      fileCount: fileCount,
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: SizedBox(
                    height: 320,
                    child: _ArchiveHealthCard(
                      byType: byType,
                      sortedMonths: sortedMonths,
                      byMonth: byMonth,
                      fileCount: fileCount,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatCount(int count) {
    final value = count.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final remaining = value.length - i;
      buffer.write(value[i]);
      if (remaining > 1 && remaining % 3 == 1) buffer.write(',');
    }
    return buffer.toString();
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

class _StatusCard extends StatelessWidget {
  final Widget child;

  const _StatusCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(padding: const EdgeInsets.all(32), child: child),
    );
  }
}

class _StatusSummaryCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String subtitle;
  final String footerLabel;
  final String footerValue;

  const _StatusSummaryCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.subtitle,
    required this.footerLabel,
    required this.footerValue,
  });

  @override
  Widget build(BuildContext context) {
    return _StatusCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: _kPrimary, size: 24),
              _CapsLabel(label),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 32,
              height: 40 / 32,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.32,
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
              letterSpacing: 0.14,
              color: _kSecondary,
            ),
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.only(top: 24),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: _kBorder.withValues(alpha: 0.55)),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CapsLabel(footerLabel),
                    const SizedBox(height: 4),
                    Text(
                      footerValue,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 20,
                        height: 28 / 20,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        color: _kText,
                      ),
                    ),
                  ],
                ),
                Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    color: _kSurface,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.info_outline,
                    size: 20,
                    color: _kSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  final int totalSize;
  final int fileCount;

  const _StorageCard({required this.totalSize, required this.fileCount});

  @override
  Widget build(BuildContext context) {
    final density = fileCount == 0 ? 0.0 : (totalSize / fileCount);
    final fill = (density / (1024 * 1024 * 128)).clamp(0.08, 1.0);
    return _StatusCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(Icons.storage_outlined, color: _kPrimary, size: 24),
              _CapsLabel('STORAGE CAPACITY'),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _formatSize(totalSize),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 32,
                        height: 40 / 32,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.32,
                        color: _kText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Stored in the primary archive',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 14,
                        height: 20 / 14,
                        letterSpacing: 0.14,
                        color: _kSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _kSurface,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'TRACKED',
                  style: TextStyle(
                    fontFamily: 'Geist',
                    fontSize: 12,
                    height: 16 / 12,
                    color: _kSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: fill,
              minHeight: 4,
              backgroundColor: _kSurface,
              color: _kText,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [_CapsLabel('LIGHT'), _CapsLabel('DENSE')],
          ),
        ],
      ),
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

class _ArchiveHealthCard extends StatelessWidget {
  final Map<String, dynamic> byType;
  final List<String> sortedMonths;
  final Map<String, dynamic> byMonth;
  final int fileCount;

  const _ArchiveHealthCard({
    required this.byType,
    required this.sortedMonths,
    required this.byMonth,
    required this.fileCount,
  });

  @override
  Widget build(BuildContext context) {
    final latestMonth = sortedMonths.isEmpty ? null : sortedMonths.first;
    final latestCount = latestMonth == null
        ? 0
        : (byMonth[latestMonth] as num).toInt();
    final topTypes = byType.entries.toList()
      ..sort((a, b) => (b.value as num).compareTo(a.value as num));

    return _StatusCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(Icons.monitor_heart_outlined, color: _kPrimary, size: 24),
              _CapsLabel('PRIMARY NODE HEALTH'),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            latestMonth ?? 'No uploads',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 32,
              height: 40 / 32,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.32,
              color: _kText,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            latestMonth == null
                ? 'No recent archive activity'
                : '$latestCount files in latest archive window',
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              height: 20 / 14,
              letterSpacing: 0.14,
              color: _kSecondary,
            ),
          ),
          const SizedBox(height: 28),
          if (topTypes.isEmpty)
            const Text(
              'No file type distribution available',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                height: 20 / 14,
                color: _kSecondary,
              ),
            )
          else
            ...topTypes.take(2).map((entry) {
              final count = (entry.value as num).toInt();
              final fraction = fileCount > 0 ? count / fileCount : 0.0;
              return Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: _DistributionBar(
                  label: _displayType(entry.key),
                  detail: '$count files',
                  fraction: fraction,
                  color: entry == topTypes.first ? _kPrimary : _kSecondary,
                ),
              );
            }),
        ],
      ),
    );
  }

  String _displayType(String type) {
    if (type.isEmpty) return 'Unknown';
    return type[0].toUpperCase() + type.substring(1);
  }
}

class _DistributionBar extends StatelessWidget {
  final String label;
  final String detail;
  final double fraction;
  final Color color;

  const _DistributionBar({
    required this.label,
    required this.detail,
    required this.fraction,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 16,
                  height: 24 / 16,
                  letterSpacing: 0.16,
                  color: _kText,
                ),
              ),
            ),
            Text(
              detail,
              style: const TextStyle(
                fontFamily: 'Geist',
                fontSize: 12,
                height: 16 / 12,
                color: _kSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 4,
            backgroundColor: _kSurface,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _CapsLabel extends StatelessWidget {
  final String text;

  const _CapsLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
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
