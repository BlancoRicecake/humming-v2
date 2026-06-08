// LoopTap — My Page / Sign-in sheet (README §2). Logged out: 4 social buttons
// + continue as guest. Logged in: avatar, provider chip, account rows, sign out.
//
// NOTE: social buttons here use placeholder monogram badges + a local fake
// login. In production wire each provider's official SDK + brand asset.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/loop_store.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

class _Provider {
  const _Provider(this.id, this.label, this.bg, this.fg, this.bd, this.mark);
  final String id;
  final String label;
  final Color bg;
  final Color fg;
  final Color bd;
  final String mark;
}

// Apple + Google only — the backing AuthService supports just these two.
const _providers = [
  _Provider('apple', 'Apple', Color(0xFF000000), Color(0xFFFFFFFF), Color(0xFF3A3A3A), 'A'),
  _Provider('google', 'Google', Color(0xFFFFFFFF), Color(0xFF1F1F1F), Color(0xFFE3E3E3), 'G'),
];

Future<void> showAccountSheet(BuildContext context) {
  return showLtModal(context, width: 400, child: const _AccountSheet());
}

class _AccountSheet extends StatelessWidget {
  const _AccountSheet();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LoopStore>();
    final user = store.user;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('My page', style: LTType.inter(size: 17, weight: FontWeight.w800, color: LT.t1)),
            IconBtn(icon: LtIcons.close, tooltip: 'Close', onTap: () => Navigator.of(context).pop()),
          ],
        ),
        const SizedBox(height: 18),
        if (user != null) ..._signedIn(context, user) else ..._signedOut(context, store),
      ],
    );
  }

  List<Widget> _signedIn(BuildContext context, Map<String, String> user) {
    final name = user['name'] ?? 'User';
    final provider = user['provider'] ?? '';
    return [
      Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: const BoxDecoration(color: LT.lime, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(name.isNotEmpty ? name[0].toUpperCase() : 'U',
                style: LTType.inter(size: 22, weight: FontWeight.w900, color: LT.bg)),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: LTType.inter(size: 16, weight: FontWeight.w800, color: LT.t1)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: LT.surface2,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: LT.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 7, height: 7, decoration: const BoxDecoration(color: LT.lime, shape: BoxShape.circle)),
                    const SizedBox(width: 5),
                    Text('Signed in · $provider',
                        style: LTType.inter(size: 10, weight: FontWeight.w700, color: LT.t2)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: 18),
      const _AccRow(icon: LtIcons.cloudDone, title: 'Cloud backup', sub: 'Loops synced across devices'),
      const _AccRow(icon: LtIcons.workspacePremium, title: 'Upgrade to Pro', sub: 'Stems · unlimited cloud', lock: true),
      const _AccRow(icon: LtIcons.restore, title: 'Restore purchases', sub: '', lock: true),
      const SizedBox(height: 10),
      GestureDetector(
        onTap: () => context.read<LoopStore>().signOut(),
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LTRadius.control),
            border: Border.all(color: LT.border),
          ),
          child: Text('Sign out', style: LTType.inter(size: 14, weight: FontWeight.w700, color: LT.danger)),
        ),
      ),
    ];
  }

  List<Widget> _signedOut(BuildContext context, LoopStore store) {
    return [
      Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: LT.surface2,
              shape: BoxShape.circle,
              border: Border.all(color: LT.border),
            ),
            child: const Center(child: Ms(LtIcons.person, size: 30, color: LT.t2)),
          ),
          const SizedBox(height: 10),
          Text('Sign in to HumTrack', style: LTType.inter(size: 16, weight: FontWeight.w800, color: LT.t1)),
          const SizedBox(height: 4),
          Text('Back up your loops and sync across devices.',
              textAlign: TextAlign.center, style: LTType.inter(size: 12, color: LT.t2)),
        ],
      ),
      const SizedBox(height: 18),
      for (final p in _providers) ...[
        _SocialButton(provider: p, onTap: () => store.signIn(p.label)),
        const SizedBox(height: 9),
      ],
      const SizedBox(height: 3),
      GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          height: 42,
          alignment: Alignment.center,
          child: Text('Continue as guest', style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t3)),
        ),
      ),
    ];
  }
}

class _SocialButton extends StatelessWidget {
  const _SocialButton({required this.provider, required this.onTap});
  final _Provider provider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isGoogle = provider.id == 'google';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: provider.bg,
          borderRadius: BorderRadius.circular(LTRadius.control),
          border: Border.all(color: provider.bd),
        ),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: isGoogle ? Colors.white : Colors.white.withValues(alpha: 0.16),
                shape: BoxShape.circle,
                border: isGoogle ? Border.all(color: const Color(0xFFE3E3E3)) : null,
              ),
              alignment: Alignment.center,
              child: Text(provider.mark, style: LTType.inter(size: 13, weight: FontWeight.w900, color: provider.fg)),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 24),
                child: Text('Continue with ${provider.label}',
                    textAlign: TextAlign.center,
                    style: LTType.inter(size: 14, weight: FontWeight.w700, color: provider.fg)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccRow extends StatelessWidget {
  const _AccRow({required this.icon, required this.title, required this.sub, this.lock = false});
  final IconData icon;
  final String title;
  final String sub;
  final bool lock;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: lock ? 0.55 : 1,
      child: Container(
        height: 54,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: LT.surface2,
          borderRadius: BorderRadius.circular(LTRadius.control),
          border: Border.all(color: LT.border),
        ),
        child: Row(
          children: [
            Ms(icon, size: 20, color: lock ? LT.t2 : LT.lime),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t1)),
                  if (sub.isNotEmpty) Text(sub, style: LTType.inter(size: 11, color: LT.t3)),
                ],
              ),
            ),
            if (lock) const Ms(LtIcons.lock, size: 16, color: LT.t3),
          ],
        ),
      ),
    );
  }
}
