import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../theme/tokens.dart';
import 'announcement.dart';

/// A contained, optional illustration. Loading/failure never blocks the body or
/// confirmation controls. No user/auth headers are sent with the image request.
class AnnouncementImage extends StatelessWidget {
  const AnnouncementImage({super.key, required this.announcement, this.maxHeight = 400});

  final Announcement announcement;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final uri = announcement.image;
    if (uri == null) return const SizedBox.shrink();
    final l = L10n.of(context);
    final lang = Localizations.localeOf(context).languageCode == 'ko' ? 'ko' : 'en';
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          uri.toString(),
          key: const ValueKey('ann-image'),
          width: double.infinity,
          fit: BoxFit.contain,
          cacheWidth: 1200,
          semanticLabel: announcement.imageAlt(lang) ?? announcement.title(lang),
          loadingBuilder:
              (context, child, progress) =>
                  progress == null
                      ? child
                      : AspectRatio(
                        aspectRatio: 3 / 2,
                        child: ColoredBox(
                          color: LT.surface2,
                          child: Center(
                            child: Text(l.annImageLoading, style: const TextStyle(color: LT.t2)),
                          ),
                        ),
                      ),
          errorBuilder:
              (context, error, stack) => Container(
                key: const ValueKey('ann-image-error'),
                width: double.infinity,
                color: LT.surface2,
                padding: const EdgeInsets.all(16),
                child: Text(l.annImageUnavailable, style: const TextStyle(color: LT.t2)),
              ),
        ),
      ),
    );
  }
}
