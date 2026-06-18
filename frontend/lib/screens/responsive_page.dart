import 'package:flutter/material.dart';

const double kDesktopBreakpoint = 1100;
const double kDesktopPageMaxWidth = 1440;
const double kDesktopFormMaxWidth = 720;

bool isDesktopWidth(BuildContext context) {
  return MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;
}

class DesktopPageHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const DesktopPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 32,
            height: 40 / 32,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.32,
            color: Color(0xFF191C1D),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 16,
            height: 24 / 16,
            letterSpacing: 0.16,
            color: Color(0xFF5F5E5E),
          ),
        ),
      ],
    );
  }
}

class DesktopPageFrame extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  const DesktopPageFrame({
    super.key,
    required this.child,
    this.maxWidth = kDesktopPageMaxWidth,
    this.padding = const EdgeInsets.fromLTRB(40, 32, 40, 40),
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class PageSectionCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const PageSectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
