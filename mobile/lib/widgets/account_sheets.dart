// 계정/구독/프로젝트 옵션 관련 바텀시트 모음.
// 시안 launch-ui-p0.html: ③ Paywall, ⑤ Login, ⑱ Logout, ⑲ Restore Result, ⑳ Project Options,
// ㉑ Rename, ㉒ Delete.
//
// 디자인 토큰만 사용 (AppColors, T). IAP/OAuth 는 mockPurchase / mockLogin 으로 호출 —
// 실제 in_app_purchase / supabase 패키지는 다음 배치에서 도입.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../services/analytics_service.dart';
import '../services/auth_service.dart';
import '../services/iap_service.dart';
import '../state/local_storage.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import 'common.dart';

BoxDecoration _sheetDeco() => const BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    );

Widget _grabber() => Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(color: const Color(0xFF3F3F46), borderRadius: BorderRadius.circular(2)),
      ),
    );

// ─── ③ Paywall ─────────────────────────────────────────────────────────
/// trigger: 'export' | 'sync' | 'backup' — 진입 컨텍스트에 따라 헤더 카피 분기.
Future<bool> showPaywallSheet(BuildContext context, ProjectStore store, {required String trigger}) async {
  AnalyticsService.instance.paywallViewed(trigger: trigger);
  // 실제 IAP 가능하면 상품 정보 미리 로드 (실패해도 시트는 떠야 함).
  if (IapService.instance.enabled && IapService.instance.products.isEmpty) {
    unawaited(IapService.instance.loadProducts());
  }
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _PaywallBody(store: store, trigger: trigger),
  );
  return ok == true;
}

class _PaywallBody extends StatefulWidget {
  const _PaywallBody({required this.store, required this.trigger});
  final ProjectStore store;
  final String trigger;
  @override
  State<_PaywallBody> createState() => _PaywallBodyState();
}

class _PaywallBodyState extends State<_PaywallBody> {
  String _plan = 'yearly'; // yearly | monthly
  bool _purchasing = false;

  String get _headline {
    switch (widget.trigger) {
      case 'export': return '내보내려면 Pro 가 필요해요';
      case 'sync': return '다른 기기에서 보려면 Pro';
      case 'backup': return '보컬 영구 보관';
      default: return 'Humming Pro';
    }
  }

  String get _sub {
    switch (widget.trigger) {
      case 'export': return 'WAV · MIDI 파일로 저장하고 공유하세요';
      case 'sync': return '클라우드 동기화로 어디서든 이어서 작업';
      case 'backup': return '내 목소리를 잃지 않고 평생 보관';
      default: return '전체 기능 잠금 해제';
    }
  }

  Future<void> _purchase() async {
    final store = widget.store;
    // 로그인 안 되어 있으면 로그인 시트 먼저 — 시안 ③ → ⑤ 흐름.
    if (store.accountEmail == null) {
      final ok = await showLoginSheet(context, store);
      if (!ok) return;
    }
    setState(() => _purchasing = true);
    bool ok = false;
    // 실 IAP 가용 → 스토어 결제. purchaseStream 이 ProjectStore 를 갱신.
    if (IapService.instance.enabled) {
      final productId = _plan == 'yearly' ? kProductYearly : kProductMonthly;
      final completer = Completer<bool>();
      late StreamSubscription sub;
      sub = IapService.instance.onPurchaseResult.listen((r) {
        if (r.productId != productId) return;
        if (!completer.isCompleted) completer.complete(r.ok);
        sub.cancel();
      });
      final launched = await IapService.instance.buy(productId);
      if (!launched) {
        sub.cancel();
        ok = false;
      } else {
        // 최대 60초 대기 — 사용자가 결제 시트 취소해도 canceled 이벤트로 풀림.
        ok = await completer.future.timeout(
          const Duration(seconds: 60),
          onTimeout: () { sub.cancel(); return false; },
        );
      }
    } else {
      // 스토어 비가용(시뮬레이터/개발) → mockPurchase 폴백.
      ok = await store.mockPurchase(plan: _plan);
    }
    if (!mounted) return;
    setState(() => _purchasing = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  Widget _planTile(String key, String title, String price, String hint) {
    final active = _plan == key;
    return GestureDetector(
      onTap: () => setState(() => _plan = key),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: active ? AppColors.activeLane : AppColors.bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: active ? AppColors.lime : AppColors.border, width: active ? 1.5 : 1),
        ),
        child: Row(children: [
          Container(
            width: 20, height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? AppColors.lime : Colors.transparent,
              border: Border.all(color: active ? AppColors.lime : AppColors.border, width: 1.5),
            ),
            child: active ? const Icon(Symbols.check, color: AppColors.bg, size: 14) : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: T.body.copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(hint, style: T.sub.copyWith(fontSize: 11)),
              ],
            ),
          ),
          Text(price, style: T.body.copyWith(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.lime)),
        ]),
      ),
    );
  }

  Widget _feature(IconData ic, String t, String s) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 32, height: 32, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.activeLane,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(ic, color: AppColors.lime, size: 18),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: T.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 1),
        Text(s, style: T.sub.copyWith(fontSize: 11)),
      ])),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Container(
      decoration: _sheetDeco(),
      constraints: BoxConstraints(maxHeight: mq.size.height * 0.92),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _grabber(),
            Row(children: [
              Expanded(child: Text(_headline, style: T.h2.copyWith(fontSize: 20))),
              GestureDetector(
                onTap: () => Navigator.pop(context, false),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Symbols.close, color: AppColors.textSecondary, size: 22),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text(_sub, style: T.sub),
            const SizedBox(height: 18),
            _feature(Symbols.cloud_done, '클라우드 동기화', '다른 기기에서 그대로 이어서 작업'),
            _feature(Symbols.download, '무제한 내보내기', 'WAV · MIDI 파일 저장 · 공유'),
            _feature(Symbols.shield, '보컬 영구 보관', '원본 목소리 클라우드 백업'),
            _feature(Symbols.bolt, '우선 처리', '빠른 분석/렌더 서버'),
            const SizedBox(height: 8),
            _planTile('yearly', '연 구독', '₩69,000 / 년', '월 ₩5,750 · 33% 할인'),
            _planTile('monthly', '월 구독', '₩8,900 / 월', '언제든 해지'),
            const SizedBox(height: 4),
            LimeButton(
              label: _purchasing ? '결제 처리 중…' : '7일 무료로 시작하기',
              onTap: _purchasing ? null : _purchase,
            ),
            const SizedBox(height: 10),
            Center(child: Text('첫 결제 7일 전 알림 · 언제든 해지 가능',
                style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary))),
            const SizedBox(height: 8),
            Center(
              child: GestureDetector(
                onTap: () async {
                  if (IapService.instance.enabled) {
                    await IapService.instance.restore();
                    if (context.mounted) {
                      await showRestoreResult(context,
                          ok: widget.store.subscription.hasProAccess);
                    }
                  } else {
                    comingSoon(context, '구매 복원');
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('구매 복원', style: T.sub.copyWith(fontSize: 12, color: AppColors.textSecondary)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── ⑤ Login ──────────────────────────────────────────────────────────
Future<bool> showLoginSheet(BuildContext context, ProjectStore store) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _LoginBody(store: store),
  );
  return ok == true;
}

class _LoginBody extends StatelessWidget {
  const _LoginBody({required this.store});
  final ProjectStore store;

  Widget _btn(BuildContext context, {required IconData ic, required String label, required Color bg, required Color fg, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 52,
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: bg == Colors.transparent ? Border.all(color: AppColors.border) : null,
        ),
        alignment: Alignment.center,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(ic, color: fg, size: 20),
          const SizedBox(width: 10),
          Text(label, style: T.body.copyWith(color: fg, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  Future<void> _login(BuildContext context, String provider, String email) async {
    // 실제 Supabase OAuth 가능 → 브라우저 redirect 시작.
    // 세션은 AuthService.onSession 으로 비동기 도착 → ProjectStore 가 자동 갱신.
    if (AuthService.instance.enabled) {
      final launched = await AuthService.instance.signInWith(provider);
      if (launched) {
        if (context.mounted) Navigator.pop(context, true);
        return;
      }
    }
    // 비활성 환경 → mock 로그인 (시뮬레이터 / 개발 모드 / 키 미설정).
    store.mockLogin(provider: provider, email: email);
    if (context.mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Container(
      decoration: _sheetDeco(),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grabber(),
          Text('로그인', style: T.h2.copyWith(fontSize: 20), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text('구독 결제와 클라우드 동기화에 사용돼요',
              style: T.sub, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          _btn(context,
              ic: Symbols.devices, label: 'Apple 로 계속',
              bg: Colors.white, fg: AppColors.bg,
              onTap: () => _login(context, 'apple', 'me@privaterelay.appleid.com')),
          _btn(context,
              ic: Symbols.g_mobiledata, label: 'Google 로 계속',
              bg: Colors.transparent, fg: AppColors.textPrimary,
              onTap: () => _login(context, 'google', 'me@gmail.com')),
          const SizedBox(height: 8),
          Center(
            child: GestureDetector(
              onTap: () => Navigator.pop(context, false),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text('나중에', style: T.sub.copyWith(fontSize: 13, color: AppColors.textSecondary)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text('계속 진행하면 서비스 약관과 개인정보처리방침에 동의하는 것으로 간주됩니다.',
              style: T.sub.copyWith(fontSize: 10, color: AppColors.textTertiary, height: 1.5),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

// ─── ⑱ Logout 확인 ────────────────────────────────────────────────────
Future<void> showLogoutConfirm(BuildContext context, ProjectStore store) async {
  await showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (sheetCtx) => Container(
      decoration: _sheetDeco(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grabber(),
          Text('로그아웃 하시겠어요?', style: T.h2.copyWith(fontSize: 18), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text('이 기기의 로컬 프로젝트는 그대로 남아있어요. 다시 로그인하면 클라우드 작업물도 복원됩니다.',
              style: T.sub, textAlign: TextAlign.center),
          const SizedBox(height: 18),
          GestureDetector(
            onTap: () async {
              if (AuthService.instance.enabled) {
                await AuthService.instance.signOut();
              } else {
                store.mockLogout();
              }
              if (sheetCtx.mounted) Navigator.pop(sheetCtx);
            },
            child: Container(
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.15),
                border: Border.all(color: AppColors.dangerBorder),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('로그아웃',
                  style: T.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.danger)),
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => Navigator.pop(sheetCtx),
            child: Container(
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.bg,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('취소', style: T.body.copyWith(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    ),
  );
}

// ─── ⑲ 구매 복원 결과 ────────────────────────────────────────────────
Future<void> showRestoreResult(BuildContext context, {required bool ok, String? message}) async {
  await showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (sheetCtx) => Container(
      decoration: _sheetDeco(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _grabber(),
          Icon(ok ? Symbols.check_circle : Symbols.error,
              color: ok ? AppColors.lime : AppColors.danger, size: 48),
          const SizedBox(height: 12),
          Text(ok ? '복원 완료' : '복원할 구매가 없어요',
              style: T.h2.copyWith(fontSize: 18)),
          const SizedBox(height: 6),
          Text(message ?? (ok ? 'Pro 기능이 다시 활성화됐어요.' : '다른 계정으로 로그인했는지 확인해 주세요.'),
              style: T.sub, textAlign: TextAlign.center),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: LimeButton(label: '확인', onTap: () => Navigator.pop(sheetCtx)),
          ),
        ],
      ),
    ),
  );
}

// ─── ⑳ ㉑ ㉒ 프로젝트 옵션 ───────────────────────────────────────────
enum _ProjectAction { open, rename, duplicate, export, delete }

/// `onChanged` 는 옵션 시트 결과로 리스트를 갱신해야 할 때 호출 — songs screen 에서 setState.
Future<void> showProjectOptionsSheet(
  BuildContext context,
  ProjectStore store,
  ProjectMeta meta, {
  required VoidCallback onChanged,
  required Future<void> Function() onOpen,
}) async {
  final action = await showModalBottomSheet<_ProjectAction>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (sheetCtx) => _ProjectOptionsBody(meta: meta, store: store),
  );
  if (action == null) return;
  switch (action) {
    case _ProjectAction.open:
      await onOpen();
      break;
    case _ProjectAction.rename:
      // ignore: use_build_context_synchronously
      final newName = await _promptRename(context, meta.title);
      if (newName != null && newName.trim().isNotEmpty) {
        await LocalStorage.instance.renameProject(meta.id, newName.trim());
        onChanged();
      }
      break;
    case _ProjectAction.duplicate:
      await LocalStorage.instance.duplicateProject(meta);
      onChanged();
      break;
    case _ProjectAction.export:
      if (!store.subscription.hasProAccess) {
        // ignore: use_build_context_synchronously
        await showPaywallSheet(context, store, trigger: 'export');
      } else {
        // ignore: use_build_context_synchronously
        comingSoon(context, '내보내기');
      }
      break;
    case _ProjectAction.delete:
      // ignore: use_build_context_synchronously
      final ok = await _promptDelete(context, meta.title);
      if (ok == true) {
        await LocalStorage.instance.deleteProject(meta.id);
        onChanged();
      }
      break;
  }
}

class _ProjectOptionsBody extends StatelessWidget {
  const _ProjectOptionsBody({required this.meta, required this.store});
  final ProjectMeta meta;
  final ProjectStore store;

  Widget _row(BuildContext context, IconData ic, String title, String? sub, _ProjectAction action, {bool danger = false, bool pro = false}) {
    final color = danger ? AppColors.danger : AppColors.textPrimary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context, action),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: danger ? AppColors.dangerBorder : AppColors.border),
        ),
        child: Row(children: [
          Icon(ic, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(title, style: T.body.copyWith(fontWeight: FontWeight.w600, color: color)),
                  if (pro) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.lime.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('PRO', style: T.label.copyWith(color: AppColors.lime, fontSize: 9)),
                    ),
                  ],
                ]),
                if (sub != null) ...[
                  const SizedBox(height: 2),
                  Text(sub, style: T.sub.copyWith(fontSize: 11)),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Container(
      decoration: _sheetDeco(),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grabber(),
          _projectHeader(meta),
          const SizedBox(height: 16),
          _row(context, Symbols.folder_open, '열기', null, _ProjectAction.open),
          _row(context, Symbols.edit, '이름 바꾸기', null, _ProjectAction.rename),
          _row(context, Symbols.content_copy, '복제', null, _ProjectAction.duplicate),
          _row(context, Symbols.ios_share, '내보내기', 'WAV · MIDI', _ProjectAction.export, pro: !store.subscription.hasProAccess),
          _row(context, Symbols.delete, '삭제', '되돌릴 수 없어요', _ProjectAction.delete, danger: true),
        ],
      ),
    );
  }
}

Widget _projectHeader(ProjectMeta meta) {
  return Row(children: [
    _ProjectThumb(index: meta.thumbIndex, size: 56),
    const SizedBox(width: 12),
    Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(meta.title, style: T.h2.copyWith(fontSize: 17),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text('${meta.trackCount}개 트랙 · ${_fmtDur(meta.durationSec)} · ${_fmtAgo(meta.updatedAt)}',
              style: T.sub),
        ],
      ),
    ),
  ]);
}

class _ProjectThumb extends StatelessWidget {
  const _ProjectThumb({required this.index, this.size = 56});
  final int index;
  final double size;

  // 4 종 그라데이션 — 시안 ② 카드 썸네일과 유사.
  static const _palettes = <List<Color>>[
    [Color(0xFFA3E635), Color(0xFF65A30D)], // lime
    [Color(0xFF7C3AED), Color(0xFF4C1D95)], // violet
    [Color(0xFFF59E0B), Color(0xFFB45309)], // amber
    [Color(0xFF06B6D4), Color(0xFF0E7490)], // cyan
  ];

  @override
  Widget build(BuildContext context) {
    final pal = _palettes[index.clamp(0, _palettes.length - 1)];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: pal,
        ),
      ),
      child: const Icon(Symbols.graphic_eq, color: Colors.white, size: 24),
    );
  }
}

// ─── ㉑ Rename 다이얼로그 ────────────────────────────────────────────
Future<String?> _promptRename(BuildContext context, String initial) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (dctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('이름 바꾸기', style: T.h2.copyWith(fontSize: 17)),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: T.body,
              cursorColor: AppColors.lime,
              decoration: InputDecoration(
                filled: true,
                fillColor: AppColors.bg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lime, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx),
                  child: Container(
                    height: 44, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.bg, borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text('취소', style: T.body.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx, ctrl.text),
                  child: Container(
                    height: 44, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.lime, borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('저장', style: T.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.bg)),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    ),
  );
}

// ─── ㉒ Delete 확인 ────────────────────────────────────────────────────
Future<bool?> _promptDelete(BuildContext context, String title) {
  return showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    builder: (dctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 48, height: 48, alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Symbols.delete, color: AppColors.danger, size: 22),
              ),
            ),
            const SizedBox(height: 12),
            Text('"$title" 삭제', style: T.h2.copyWith(fontSize: 17), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('로컬 파일이 영구 삭제돼요. 이 작업은 되돌릴 수 없어요.',
                style: T.sub, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx, false),
                  child: Container(
                    height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.bg, borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text('취소', style: T.body.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx, true),
                  child: Container(
                    height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.danger, borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('삭제', style: T.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    ),
  );
}

// ─── 포맷 헬퍼 ────────────────────────────────────────────────────────
String _fmtDur(double s) {
  final m = (s ~/ 60), ss = (s % 60).round();
  return '$m분 ${ss.toString().padLeft(2, '0')}초';
}

String _fmtAgo(DateTime dt) {
  final d = DateTime.now().difference(dt);
  if (d.inMinutes < 1) return '방금 전';
  if (d.inHours < 1) return '${d.inMinutes}분 전';
  if (d.inDays < 1) return '${d.inHours}시간 전';
  if (d.inDays < 7) return '${d.inDays}일 전';
  return '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';
}

/// 외부에서 공개 — 카드 위젯에서도 같은 썸네일 색을 쓰기 위해.
class ProjectThumb extends StatelessWidget {
  const ProjectThumb({super.key, required this.index, this.size = 56});
  final int index;
  final double size;
  @override
  Widget build(BuildContext context) => _ProjectThumb(index: index, size: size);
}

/// fmt helpers 외부 공개.
String fmtProjectDuration(double s) => _fmtDur(s);
String fmtProjectAgo(DateTime dt) => _fmtAgo(dt);
