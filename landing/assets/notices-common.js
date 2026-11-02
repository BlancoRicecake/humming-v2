// Shared by /notices and /admin/notices (2026-11-02).
// Reads the same app_announcements feed the apps read; ?demo=1 uses the
// sample rows below instead (no network) so the pages can be tried locally.
(function () {
  const COLUMNS =
    'id,revision,kind,title_ko,title_en,body_ko,body_en,starts_at,ends_at,' +
    'platforms,min_build,max_build,action_label_ko,action_label_en,action_url';

  const now = Date.now();
  const iso = (ms) => new Date(ms).toISOString();
  const DEMO = [
    {
      id: '2026-11-02-hum-track', revision: 1, kind: 'important', published: true,
      title_ko: '허밍으로 새 트랙을 추가할 수 있어요',
      title_en: 'Add a new track by humming',
      body_ko: '편집기 위쪽의 로고 버튼을 누르고 악기를 고른 뒤 흥얼거리면, 변환된 멜로디가 새 트랙으로 들어가요.\n녹음하는 동안 지금 곡이 함께 재생돼요.',
      body_en: 'Tap the logo button at the top of the editor, pick an instrument and hum — the melody becomes a new track.\nThe song plays while you record.',
      starts_at: iso(now - 864e5), ends_at: null, platforms: ['android', 'ios', 'windows', 'macos'],
      min_build: null, max_build: null, action_label_ko: null, action_label_en: null, action_url: null,
    },
    {
      id: '2026-11-01-maintenance', revision: 1, kind: 'critical', published: true,
      title_ko: '11월 5일 새벽 2시~3시 서버 점검',
      title_en: 'Server maintenance Nov 5, 2–3 AM KST',
      body_ko: '점검 중에는 허밍 변환과 클라우드 백업을 쓸 수 없어요. 곡 편집과 재생은 그대로 할 수 있어요.',
      body_en: 'Hum conversion and cloud backup are unavailable during maintenance. Editing and playback still work.',
      starts_at: iso(now - 2 * 864e5), ends_at: iso(now + 3 * 864e5), platforms: ['android', 'ios'],
      min_build: null, max_build: null,
      action_label_ko: '자세히 보기', action_label_en: 'Details', action_url: 'https://hum-track.com/notices',
    },
    {
      id: '2026-10-20-welcome', revision: 2, kind: 'info', published: true,
      title_ko: 'HumTrack 공지사항을 시작해요',
      title_en: 'HumTrack notices are here',
      body_ko: '새 기능, 점검, 중요한 안내를 이곳과 앱에서 알려 드릴게요.',
      body_en: 'New features, maintenance and important news will be posted here and in the app.',
      starts_at: iso(now - 13 * 864e5), ends_at: null, platforms: ['android', 'ios', 'windows', 'macos'],
      min_build: null, max_build: null, action_label_ko: null, action_label_en: null, action_url: null,
    },
  ];

  const demo = new URLSearchParams(location.search).has('demo');
  const cfg = window.HUMTRACK_SUPABASE || { url: '', anonKey: '' };

  async function fetchPublished() {
    if (demo) return DEMO.filter((r) => r.published).map((r) => ({ ...r }));
    if (!cfg.url || !cfg.anonKey) throw new Error('not configured');
    const q = new URLSearchParams({ select: COLUMNS, order: 'starts_at.desc', limit: '50' });
    const r = await fetch(`${cfg.url}/rest/v1/app_announcements?${q}`, {
      headers: { apikey: cfg.anonKey, Authorization: `Bearer ${cfg.anonKey}`, Accept: 'application/json' },
    });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r.json();
  }

  const KIND = {
    ko: { info: '소식', important: '중요', critical: '긴급' },
    en: { info: 'News', important: 'Important', critical: 'Urgent' },
  };

  function fmtDate(s, lang) {
    if (!s) return '';
    const d = new Date(s);
    return d.toLocaleDateString(lang === 'ko' ? 'ko-KR' : 'en-US', { year: 'numeric', month: 'long', day: 'numeric' });
  }

  // the same action rule as the apps and the table check
  function safeAction(url) {
    if (!url) return null;
    return /^(https:\/\/([a-z0-9-]+\.)*hum-track\.com(\/\S*)?|https:\/\/apps\.apple\.com\/\S*|https:\/\/play\.google\.com\/\S*|mailto:humtrack@gmail\.com)$/.test(url)
      ? url : null;
  }

  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  window.HumNotices = { demo, cfg, DEMO, fetchPublished, KIND, fmtDate, safeAction, esc, COLUMNS };
})();
