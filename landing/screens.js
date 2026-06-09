/* ============================================================
   HumTrack screenshots — app-screen builders (bilingual)
   Each returns an .app HTML string authored at 1180px width.
   t = 'ko' | 'en'
   ============================================================ */
(function () {
  const I = window.svgIcon;
  const EQ = window.eqGlyph;

  const TR = {
    ko: {
      sub: '탭으로 비트 만들기', newSong: '새 노래', save: '저장', export: '내보내기',
      playSong: '곡 재생', hum: '허밍 → MIDI', mixer: '믹서',
      melody: '멜로디', bass: '베이스', drums: '드럼', vocal: '보컬',
      hintLanes: '레인을 두드리면 박자에 맞춰 인키로 찍혀요',
      hintDrums: '좌우 패드를 두드리면 그리드에 기록돼요',
      lanesName: '멜로디 · 레인', drumsName: '드럼',
      humTitle: '허밍 → MIDI · 멜로디', humSub: '머릿속 멜로디를 흥얼거리면\n인키로 다듬어 트랙에 얹어줘요.',
      cancel: '취소', convert: '변환', listening: '듣는 중…',
      exTitle: '내보내기', exMeta: '2개 섹션 · 4마디 · 92 BPM',
      midi: 'MIDI 파일', midiS: '피아노 · 베이스 · 드럼 채널',
      wav: '오디오 (WAV)', wavS: '믹스 다운 · 스윙 반영',
      stems: '스템', stemsS: '트랙별 WAV 4개',
      share: '공유 링크', shareS: 'Pro 기능', done: '저장됨',
      exFoot: '섹션은 반복 횟수만큼 순서대로 렌더링되고, 믹서 볼륨과 스윙이 그대로 반영돼요.',
    },
    en: {
      sub: 'TAP TO MAKE BEATS', newSong: 'New song', save: 'Save', export: 'Export',
      playSong: 'Play song', hum: 'Hum to MIDI', mixer: 'Mixer',
      melody: 'Melody', bass: 'Bass', drums: 'Drums', vocal: 'Vocal',
      hintLanes: 'Tap the lanes — it lands in time, always in key',
      hintDrums: 'Tap the pads — hits print onto the grid',
      lanesName: 'Melody · Lanes', drumsName: 'Drums',
      humTitle: 'Hum to MIDI · Melody', humSub: 'Hum the melody in your head —\nwe tune it in-key and drop it on the track.',
      cancel: 'Cancel', convert: 'Convert', listening: 'Listening…',
      exTitle: 'Export', exMeta: '2 sections · 4 bars · 92 BPM',
      midi: 'MIDI file', midiS: 'Piano · bass · drums channels',
      wav: 'Audio (WAV)', wavS: 'Full mix · swing baked in',
      stems: 'Stems', stemsS: 'One WAV per track · 4',
      share: 'Share link', shareS: 'Pro feature', done: 'downloaded',
      exFoot: 'Sections render in order by repeat count, with mixer levels and swing baked in.',
    },
  };

  const C = { lime: 'var(--lime)', blue: 'var(--blue)', amber: 'var(--amber)', pink: 'var(--pink)' };

  /* ---- Songs (home) ---- */
  function bars(seed, hotEvery) {
    let h = '';
    for (let i = 0; i < 34; i++) {
      const v = 44 + Math.abs(Math.sin(seed + i * 0.9)) * 50;
      const hot = i % hotEvery === 0;
      h += `<i class="${hot ? 'hot' : ''}" style="height:${hot ? Math.min(99, v + 5) : v}%"></i>`;
    }
    return h;
  }
  function songCard(seed, hotEvery, title, meta) {
    return `<div class="scard">
      <div class="thumb">${bars(seed, hotEvery)}</div>
      <div class="ti">${title}</div>
      <div class="meta mono">${meta}</div>
    </div>`;
  }
  function songs(t) {
    const T = TR[t];
    const cards = [
      songCard(1.0, 5, 'Neon nightdrive', 'A minor · 92 BPM · 2 bars'),
      songCard(2.3, 4, 'Lo-fi study', 'C major · 78 BPM · 2 bars'),
      songCard(3.7, 2, 'Trap skeleton', 'F# minor · 140 BPM · 2 bars'),
      songCard(4.1, 3, 'Sunset drive', 'D minor · 100 BPM · 4 bars'),
      songCard(5.6, 5, 'First loop', 'G major · 88 BPM · 2 bars'),
    ];
    const add = `<div class="scard scard--add">
        ${I('add', { size: 26, color: 'var(--text-tertiary)' })}
        <div class="big">+</div><div class="t">${t === 'ko' ? '새 루프 시작' : 'Start a new loop'}</div>
      </div>`.replace('<div class="big">+</div>', '');
    return `<div class="songs">
      <div class="songs-head">
        <div class="logo">${EQ('var(--bg)', 26)}</div>
        <div class="wm">
          <div class="name">Hum<em>Track</em></div>
          <div class="sub">${T.sub}</div>
        </div>
        <div class="spacer"></div>
        <div class="rbtn">${I('settings', { size: 19, color: 'var(--text-secondary)' })}</div>
        <div class="rbtn">${I('user', { size: 19, color: 'var(--text-secondary)' })}</div>
        <div class="new">${I('plus', { size: 18, color: 'var(--bg)' })}${T.newSong}</div>
      </div>
      <div class="songs-grid">${cards.join('')}${add}</div>
    </div>`;
  }

  /* ---- Editor chrome ---- */
  function arrRow(name, color, laneHTML, vol, muted) {
    return `<div class="arr-row">
      <div class="arr-label" style="${color ? `border-color:${color}55;background:${color}1a` : ''}">
        ${I('volume', { size: 14, color: muted ? 'var(--text-tertiary)' : (color || 'var(--text-secondary)') })}
        <span class="nm" style="${color ? `color:${color}` : ''}">${name}</span>
        <span class="vol mono">${vol}</span>
      </div>
      <div class="arr-lane">${laneHTML}</div>
    </div>`;
  }
  function noteBlocks(color, specs) {
    return specs.map(([l, w, top]) => `<div class="arr-note" style="left:${l}%;width:${w}%;background:${color};box-shadow:0 0 6px ${color}99;top:${top}%"></div>`).join('');
  }
  function drumDots() {
    let h = '';
    const rows = [[2, 'var(--blue)', [0, 12.5, 25, 37.5, 50, 62.5, 75, 87.5]], [50, 'var(--lime)', [25, 75]], [86, 'var(--amber)', [0, 25, 50, 75]]];
    rows.forEach(([top, c, xs]) => xs.forEach((x) => { h += `<div class="arr-dot" style="left:${x + 4}%;top:${top}%;background:${c};box-shadow:0 0 5px ${c}"></div>`; }));
    return h;
  }
  function arrangement(t, active) {
    const T = TR[t];
    return `<div class="ed-arr">
      ${arrRow(T.melody, C.lime, noteBlocks(C.lime, [[3, 9, 30], [16, 7, 50], [27, 11, 20], [44, 8, 60], [58, 14, 38], [78, 9, 26]]), '85', false)}
      ${arrRow(T.bass, C.blue, noteBlocks(C.blue, [[2, 14, 55], [22, 14, 55], [48, 12, 40], [72, 18, 55]]), '85', false)}
      ${arrRow(T.drums, C.amber, drumDots(), '100', false)}
      ${arrRow(T.vocal, C.pink, '', '—', true)}
      <div class="playhead" style="left:calc(120px + 10px + 38%)"></div>
    </div>`;
  }
  function transport(t, recArmed) {
    return `<div class="ed-transport">
      <div class="tgrp">
        <div class="tbtn on">${I('metronome', { size: 18 })}</div>
        <div class="tbtn">${I('timer', { size: 18 })}</div>
        <div class="tbtn on">${I('repeat', { size: 18 })}</div>
        <div class="bpm"><div class="rbtn" style="width:30px;height:30px;border:none;background:transparent">${I('chevronLeft', { size: 16, color: 'var(--text-secondary)' })}</div><div class="n mono">92 <small>BPM</small></div><div class="rbtn" style="width:30px;height:30px;border:none;background:transparent;transform:scaleX(-1)">${I('chevronLeft', { size: 16, color: 'var(--text-secondary)' })}</div></div>
      </div>
      <div class="spacer"></div>
      <div class="tgrp" style="gap:14px">
        <div class="t-rbtn">${I('stop', { size: 18, fill: 'var(--text-primary)', color: 'var(--text-primary)' })}</div>
        <div class="t-play">${I('play', { size: 24, fill: 'var(--bg)', color: 'var(--bg)' })}</div>
        <div class="t-rec">${recArmed ? '<div class="dot" style="border-radius:5px"></div>' : '<div class="dot" style="border-radius:999px"></div>'}</div>
      </div>
      <div class="spacer"></div>
      <div class="tgrp" style="gap:14px">
        <div class="swing"><span class="ulabel" style="font-size:9px;color:var(--text-tertiary)">SWING</span><div class="track"><i style="width:32%"></i><b style="left:32%"></b></div><span class="mono" style="font-size:12px;color:var(--text-secondary)">18%</span></div>
        <div class="barsT"><b>2</b><b class="on">4</b></div>
        <div class="tbtn">${I('backspace', { size: 18 })}</div>
      </div>
    </div>`;
  }
  function topbar(t, title) {
    const T = TR[t];
    return `<div class="ed-top">
      <div class="rbtn">${I('arrowLeft', { size: 18, color: 'var(--text-secondary)' })}</div>
      <div class="ed-title">${I('edit', { size: 15 })}${title}</div>
      <div class="spacer"></div>
      <div class="pill">${I('sliders', { size: 15, color: 'var(--text-secondary)' })}${T.mixer}</div>
      <div class="pill pill--key">${I('musicNote', { size: 14, color: 'var(--lime)' })}<b>A</b> min</div>
      <div class="pill">${I('check', { size: 15, color: 'var(--text-secondary)' })}${T.save}</div>
      <div class="pill pill--lime">${I('share', { size: 15, color: 'var(--bg)' })}${T.export}</div>
    </div>`;
  }
  function songbar(t) {
    const T = TR[t];
    return `<div class="ed-song">
      <span class="ulabel" style="font-size:10px;color:var(--text-tertiary)">SONG</span>
      <div class="chip chip--active">${t === 'ko' ? '벌스' : 'Verse'} <span class="xn mono">×2</span></div>
      <div class="chip">${t === 'ko' ? '드롭' : 'Drop'} <span class="xn mono">×2</span></div>
      <div class="chip chip--add">${I('plus', { size: 15, color: 'var(--text-tertiary)' })}</div>
      <div class="spacer"></div>
      <div class="pill" style="height:30px;padding:0 13px;font-size:12px">${I('play', { size: 13, fill: 'var(--lime)', color: 'var(--lime)' })}${T.playSong}</div>
    </div>`;
  }
  function shead(t, name, color, opts) {
    const T = TR[t];
    opts = opts || {};
    return `<div class="ed-shead">
      <div class="titles">${I(opts.icon || 'musicNote', { size: 17, color })}<span style="color:${color}">${name}</span></div>
      ${opts.seg ? `<div class="seg"><b class="on">${t === 'ko' ? '레인' : 'Lanes'}</b><b>${t === 'ko' ? '그리드' : 'Grid'}</b><b>${t === 'ko' ? '패드' : 'Pads'}</b></div>` : ''}
      ${opts.oct ? `<div class="step">${I('chevronLeft', { size: 14, color: 'var(--text-secondary)' })}<span class="v">OCT 0</span>${I('chevronLeft', { size: 14, color: 'var(--text-secondary)' })}</div>` : ''}
      <div class="spacer"></div>
      <div class="hint">${opts.hint || ''}</div>
      ${opts.hum ? `<div class="pill" style="height:32px"><span style="color:var(--lime);display:grid;place-items:center">${I('mic', { size: 14, color: 'var(--lime)' })}</span>${T.hum}</div>` : ''}
    </div>`;
  }
  function editor(t, opts) {
    return `<div class="app" id="${opts.id}">
      ${topbar(t, opts.title)}
      ${songbar(t)}
      ${arrangement(t, opts.active)}
      ${opts.shead}
      <div class="ed-surface">${opts.surface}</div>
      ${transport(t, opts.recArmed)}
      ${opts.overlay || ''}
    </div>`;
  }

  /* ---- Drums surface ---- */
  function drumCol(litRow) {
    const pad = (cls, glyph, lab, color, lit) => `<div class="dpad ${cls}${lit ? ' lit' : ''}"><div class="stack"><div class="g" style="color:${color}">${glyph}</div><div class="lab" style="color:${color}">${lab}</div></div></div>`;
    return `<div class="dcol">
      ${pad('hh', 'HH', 'HI-HAT', 'var(--blue)', litRow === 'hh')}
      ${pad('sn', 'SN', 'SNARE', 'var(--lime)', litRow === 'sn')}
      ${pad('kk', 'KK', 'KICK', 'var(--amber)', litRow === 'kk')}
    </div>`;
  }
  function drumGrid(cur) {
    const rowDef = [['HH', 'hh', [0, 2, 4, 6, 8, 10, 12, 14]], ['SN', 'sn', [4, 12]], ['KK', 'kk', [0, 6, 10]]];
    const rows = rowDef.map(([rl, cls, on]) => {
      let cells = '';
      for (let s = 0; s < 16; s++) {
        const isOn = on.includes(s);
        const beat = s % 4 === 0;
        cells += `<div class="dcell ${isOn ? 'on ' + cls : (beat ? 'beat' : '')}${s === cur ? ' cur' : ''}"></div>`;
      }
      return `<div class="drow"><span class="rl">${rl}</span><div class="dcells">${cells}</div></div>`;
    }).join('');
    return `<div class="dgrid">${rows}</div>`;
  }
  function drumsSurface(litRow, cur) {
    return `<div class="drums">${drumCol(litRow)}${drumGrid(cur)}${drumCol(litRow)}</div>`;
  }

  /* ---- Melody lanes surface ---- */
  function melodyLanes(activeIdx) {
    const names = ['A', 'C', 'D', 'E', 'G', 'A', 'C', 'D'];
    const notesPer = [
      [[56, 12], [24, 9]], [[68, 13]], [[38, 12], [8, 9]], [[50, 16]],
      [[62, 10], [30, 12]], [[18, 12], [54, 18]], [[44, 14], [76, 9]], [[34, 12]],
    ];
    let h = '';
    for (let i = 0; i < 8; i++) {
      const on = i === activeIdx;
      const nb = (notesPer[i] || []).map(([top, ht]) => `<div class="nb" style="top:${top}%;height:${ht}%"></div>`).join('');
      h += `<div class="lane${on ? ' on' : ''}"><div class="col">${nb}</div><div class="nm">${names[i]}</div><div class="deg">deg ${i + 1}</div></div>`;
    }
    return `<div class="lanes">${h}</div>`;
  }

  /* ---- Hum-to-MIDI overlay ---- */
  function humOverlay(t) {
    const T = TR[t];
    const hs = [26, 40, 64, 48, 70, 36, 58, 44, 30, 52, 38];
    const bars = hs.map((v) => `<i style="height:${v}%"></i>`).join('');
    return `<div class="overlay"><div class="hum">
      <div class="mic">${I('mic', { size: 34, color: 'var(--lime)' })}</div>
      <div class="elabel ulabel" style="font-size:10px">${T.listening}</div>
      <h3>${T.humTitle}</h3>
      <p>${T.humSub.replace('\n', '<br>')}</p>
      <div class="bars">${bars}</div>
      <div class="acts">
        <button>${T.cancel}</button>
        <button class="lime">${I('sparkle', { size: 18, color: 'var(--bg)', fill: 'var(--bg)' })}${T.convert}</button>
      </div>
    </div></div>`;
  }

  /* ---- Export drawer ---- */
  function exportDrawer(t) {
    const T = TR[t];
    const row = (cls, icon, name, sub, status) => `<div class="erow ${cls}">
      <div class="ei">${icon}</div>
      <div class="em"><div class="n">${name}</div><div class="s">${sub}</div></div>
      ${status}
    </div>`;
    const done = `<div class="done">${I('checkCircle', { size: 14, color: 'var(--lime)' })}${T.done}</div>`;
    return `<div class="exdim"></div><div class="drawer">
      <div class="dh"><div class="t">${T.exTitle} · Neon nightdrive</div><div class="rbtn">${I('chevronLeft', { size: 16, color: 'var(--text-secondary)' })}</div></div>
      <div class="dmeta">${T.exMeta}</div>
      ${row('lime', I('file', { size: 20, color: 'var(--bg)' }), T.midi, T.midiS, done)}
      ${row('', I('musicNote', { size: 20, color: 'var(--text-secondary)' }), T.wav, T.wavS, `<div class="rbtn" style="border:none;background:transparent">${I('download', { size: 18, color: 'var(--text-secondary)' })}</div>`)}
      ${row('', I('layers', { size: 20, color: 'var(--text-secondary)' }), T.stems, T.stemsS, `<div class="rbtn" style="border:none;background:transparent">${I('download', { size: 18, color: 'var(--text-secondary)' })}</div>`)}
      ${row('locked', I('share', { size: 20, color: 'var(--text-secondary)' }), T.share, T.shareS, I('lock', { size: 17, color: 'var(--text-tertiary)' }))}
      <div class="dfoot">${T.exFoot}</div>
    </div>`;
  }

  /* ---- Public: screen registry ---- */
  window.Screens = {
    songs: (t) => songs(t),
    drums: (t) => editor(t, {
      id: 'drums', title: 'Neon nightdrive', active: 'drums',
      shead: shead(t, TR[t].drumsName, C.amber, { icon: 'waveform', hint: TR[t].hintDrums }),
      surface: drumsSurface('sn', 6), recArmed: true,
    }),
    melody: (t) => editor(t, {
      id: 'melody', title: 'Neon nightdrive', active: 'melody',
      shead: shead(t, TR[t].lanesName, C.lime, { seg: true, oct: true, hum: true, hint: TR[t].hintLanes }),
      surface: melodyLanes(5),
    }),
    hum: (t) => editor(t, {
      id: 'hum', title: 'Neon nightdrive', active: 'melody',
      shead: shead(t, TR[t].lanesName, C.lime, { seg: true, oct: true, hum: true, hint: TR[t].hintLanes }),
      surface: melodyLanes(-1), overlay: humOverlay(t),
    }),
    export: (t) => editor(t, {
      id: 'export', title: 'Neon nightdrive', active: 'drums',
      shead: shead(t, TR[t].drumsName, C.amber, { icon: 'waveform', hint: '' }),
      surface: drumsSurface(null, 6), overlay: exportDrawer(t),
    }),
  };
})();
