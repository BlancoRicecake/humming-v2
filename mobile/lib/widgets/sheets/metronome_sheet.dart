// 메트로놈 시트 + BPM stepper + 시각 펄스. 박자보정과 분리(노트 정렬 ≠ 청각 클릭).
part of '../sheets.dart';

// ─── 메트로놈 시트 ─────────────────────────────────────────────────────
// 트랜스포트 메트로놈 버튼 → BPM stepper + on/off 토글. 박자보정 시트와 기능 분리:
// 박자보정 = 노트 정렬(그리드/강도) / 메트로놈 = 청각 클릭 + BPM 설정(공통 store.bpm).
void showMetronomeSheet(
  BuildContext context,
  ProjectStore store, {
  required Future<void> Function(bool on) onToggle,
  required Future<void> Function() onBpmChanged,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => _MetroSheetBody(store: store, onToggle: onToggle, onBpmChanged: onBpmChanged),
  );
}

class _MetroSheetBody extends StatefulWidget {
  const _MetroSheetBody({required this.store, required this.onToggle, required this.onBpmChanged});
  final ProjectStore store;
  final Future<void> Function(bool on) onToggle;
  final Future<void> Function() onBpmChanged;
  @override
  State<_MetroSheetBody> createState() => _MetroSheetBodyState();
}

class _MetroSheetBodyState extends State<_MetroSheetBody> {
  DateTime? _anchor;

  String _tempoHint(L10n l, int bpm) {
    if (bpm < 70) return l.tempoVerySlow;
    if (bpm < 95) return l.tempoBallad;
    if (bpm < 115) return l.tempoMidPop;
    if (bpm < 135) return l.tempoDance;
    if (bpm < 160) return l.tempoFast;
    return l.tempoVeryFast;
  }

  void _refreshAnchor() {
    // 메트로놈 켜진 동안엔 시각 펄스를 BPM 변경 시 매번 새로 anchor → drift 없는 sync.
    _anchor = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final mq = MediaQuery.of(context);
    return AnimatedBuilder(
      animation: widget.store,
      builder: (_, __) {
        final store = widget.store;
        return Container(
          decoration: _sheetDeco(),
          padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _grabber(),
              Row(children: [
                Text(l.metronomeTitle, style: T.h2.copyWith(fontSize: 18)),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(l.done,
                        style: T.body.copyWith(color: AppColors.lime, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              // BPM + 시각 펄스 (메트로놈 켜져 있을 때만 anchor 활성)
              Row(children: [
                _PulseLarge(bpm: store.bpm, anchor: store.metroOn ? _anchor : null),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('${store.bpm}',
                            style: T.h1.copyWith(fontSize: 38, fontFeatures: const [FontFeature.tabularFigures()])),
                        const SizedBox(width: 4),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('BPM', style: T.label.copyWith(color: AppColors.textSecondary)),
                        ),
                      ]),
                      Text(_tempoHint(l, store.bpm),
                          style: T.body.copyWith(fontSize: 12, color: AppColors.textSecondary)),
                      Text(l.metronomeBeatSec((60 / store.bpm).toStringAsFixed(2)),
                          style: T.label.copyWith(fontSize: 10, color: AppColors.textTertiary)),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                _metroStep(Symbols.fast_rewind, () async {
                  store.setBpm(store.bpm - 5);
                  await widget.onBpmChanged();
                  setState(_refreshAnchor);
                }),
                const SizedBox(width: 6),
                _metroStep(Symbols.remove, () async {
                  store.setBpm(store.bpm - 1);
                  await widget.onBpmChanged();
                  setState(_refreshAnchor);
                }),
                const Spacer(),
                _metroStep(Symbols.add, () async {
                  store.setBpm(store.bpm + 1);
                  await widget.onBpmChanged();
                  setState(_refreshAnchor);
                }),
                const SizedBox(width: 6),
                _metroStep(Symbols.fast_forward, () async {
                  store.setBpm(store.bpm + 5);
                  await widget.onBpmChanged();
                  setState(_refreshAnchor);
                }),
              ]),
              const SizedBox(height: 18),
              // 메트로놈 on/off 토글 — 큰 버튼.
              GestureDetector(
                onTap: () async {
                  final next = !store.metroOn;
                  await widget.onToggle(next);
                  if (next) {
                    setState(_refreshAnchor);
                  } else {
                    setState(() => _anchor = null);
                  }
                },
                child: Container(
                  width: double.infinity,
                  height: 52,
                  decoration: BoxDecoration(
                    color: store.metroOn ? AppColors.lime : Colors.transparent,
                    border: Border.all(
                      color: store.metroOn ? AppColors.lime : AppColors.border,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(
                      store.metroOn ? Symbols.stop : Symbols.play_arrow,
                      size: 20,
                      color: store.metroOn ? AppColors.bg : AppColors.textPrimary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      store.metroOn ? l.metronomeOff : l.metronomeOn,
                      style: T.body.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: store.metroOn ? AppColors.bg : AppColors.textPrimary,
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l.metronomeNote,
                style: T.body.copyWith(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _metroStep(IconData ic, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Icon(ic, size: 18, color: AppColors.textPrimary),
      ),
    );
  }
}

class _PulseLarge extends StatefulWidget {
  const _PulseLarge({required this.bpm, required this.anchor});
  final int bpm;
  final DateTime? anchor; // 메트로놈 첫 클릭 기준점 — 펄스 위상을 여기에 락.
  @override
  State<_PulseLarge> createState() => _PulseLargeState();
}

class _PulseLargeState extends State<_PulseLarge> with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  double _v = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration _) {
    final anchor = widget.anchor;
    if (anchor == null) {
      if (_v != 0) setState(() => _v = 0);
      return;
    }
    final periodMs = (60000 / widget.bpm).clamp(150.0, 2000.0);
    final elapsedMs = DateTime.now().difference(anchor).inMicroseconds / 1000.0;
    if (elapsedMs < 0) {
      if (_v != 0) setState(() => _v = 0);
      return;
    }
    final phase = (elapsedMs % periodMs) / periodMs; // 0..1
    // 비트 시작 시 1.0 피크, easeIn 으로 감쇠 → 다음 비트 직전 0.
    final next = (1.0 - phase) * (1.0 - phase); // easeIn 근사 (x→x^2 decay)
    if ((next - _v).abs() > 0.005) setState(() => _v = next);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: AppColors.lime.withValues(alpha: 0.15 + 0.6 * v),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: AppColors.lime.withValues(alpha: 0.45 * v),
            blurRadius: 20 * v,
            spreadRadius: 2 * v,
          ),
        ],
      ),
    );
  }
}
