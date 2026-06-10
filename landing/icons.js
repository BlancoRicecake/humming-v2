/* HumTrack store screenshots — inline SVG icon set (Material-Symbols-like
   line icons). Inline SVG so it rasterizes reliably in capture (icon webfonts
   do not). currentColor drives stroke; filled glyphs pass fill via opts. */
(function () {
  // viewBox 0 0 24 24, 2px round stroke unless noted.
  const P = {
    settings: '<circle cx="12" cy="12" r="3.2"/><path d="M19.4 13.5a1.7 1.7 0 0 0 .34 1.87l.06.06a2.06 2.06 0 1 1-2.92 2.92l-.06-.06a1.7 1.7 0 0 0-1.87-.34 1.7 1.7 0 0 0-1.03 1.56V21a2.06 2.06 0 0 1-4.12 0v-.1A1.7 1.7 0 0 0 8.7 19.3a1.7 1.7 0 0 0-1.87.34l-.06.06a2.06 2.06 0 1 1-2.92-2.92l.06-.06a1.7 1.7 0 0 0 .34-1.87 1.7 1.7 0 0 0-1.56-1.03H2.6a2.06 2.06 0 0 1 0-4.12h.1A1.7 1.7 0 0 0 4.7 8.7a1.7 1.7 0 0 0-.34-1.87l-.06-.06a2.06 2.06 0 1 1 2.92-2.92l.06.06a1.7 1.7 0 0 0 1.87.34H9.3A1.7 1.7 0 0 0 10.3 2.8V2.6a2.06 2.06 0 0 1 4.12 0v.1a1.7 1.7 0 0 0 1.03 1.56 1.7 1.7 0 0 0 1.87-.34l.06-.06a2.06 2.06 0 1 1 2.92 2.92l-.06.06a1.7 1.7 0 0 0-.34 1.87v.04a1.7 1.7 0 0 0 1.56 1.03H21a2.06 2.06 0 0 1 0 4.12h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
    user: '<circle cx="12" cy="8" r="4"/><path d="M5.5 21a6.5 6.5 0 0 1 13 0"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    arrowLeft: '<path d="M19 12H5M12 19l-7-7 7-7"/>',
    chevronLeft: '<path d="M15 18l-6-6 6-6"/>',
    share: '<path d="M12 15V3M8 7l4-4 4 4"/><path d="M4 13v6a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-6"/>',
    download: '<path d="M12 3v12M7 10l5 5 5-5"/><path d="M5 21h14"/>',
    sliders: '<path d="M5 21v-7M5 10V3M12 21v-9M12 8V3M19 21v-5M19 12V3"/><circle cx="5" cy="12" r="2"/><circle cx="12" cy="6" r="2"/><circle cx="19" cy="14" r="2"/>',
    musicNote: '<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>',
    play: '<polygon points="6 4 20 12 6 20" __FILL__/>',
    pause: '<rect x="6" y="5" width="4" height="14" rx="1" __FILL__/><rect x="14" y="5" width="4" height="14" rx="1" __FILL__/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="2.5" __FILL__/>',
    mic: '<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
    layers: '<path d="M12 2 2 7l10 5 10-5-10-5Z"/><path d="M2 12l10 5 10-5M2 17l10 5 10-5"/>',
    check: '<path d="M20 6 9 17l-5-5"/>',
    checkCircle: '<circle cx="12" cy="12" r="9"/><path d="M8.5 12.5 11 15l4.5-5"/>',
    repeat: '<path d="M17 2l4 4-4 4"/><path d="M3 11V9a4 4 0 0 1 4-4h14M7 22l-4-4 4-4"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/>',
    volume: '<polygon points="4 9 8 9 13 5 13 19 8 15 4 15" __FILL__/><path d="M17 9a4 4 0 0 1 0 6"/>',
    file: '<path d="M14 2H7a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7Z"/><path d="M14 2v5h5"/>',
    lock: '<rect x="4.5" y="10" width="15" height="10" rx="2.2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
    metronome: '<path d="M8 3h8l3 18H5L8 3Z"/><path d="M12 21 16 7"/>',
    timer: '<circle cx="12" cy="13" r="8"/><path d="M12 13V8M9 2h6"/>',
    backspace: '<path d="M21 5H8L2 12l6 7h13a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1Z"/><path d="M16 9l-5 6M11 9l5 6"/>',
    edit: '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
    add: '<circle cx="12" cy="12" r="9"/><path d="M12 8v8M8 12h8"/>',
    headphones: '<path d="M4 14v-2a8 8 0 0 1 16 0v2"/><rect x="2.5" y="14" width="4.5" height="7" rx="2"/><rect x="17" y="14" width="4.5" height="7" rx="2"/>',
    sparkle: '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8L12 3Z" __FILL__/>',
    waveform: '<path d="M3 12h2M7 8v8M11 5v14M15 9v6M19 11v2M21 12h0"/>',
  };

  window.svgIcon = function (name, opts) {
    opts = opts || {};
    const size = opts.size || 24;
    const color = opts.color || 'currentColor';
    const sw = opts.stroke != null ? opts.stroke : 2;
    let body = P[name] || '';
    const fill = opts.fill || 'none';
    body = body.replace(/__FILL__/g, opts.fill ? `fill="${opts.fill}"` : 'fill="currentColor"');
    return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="${color}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round" style="display:block;flex:none">${body}</svg>`;
  };

  // Equalizer wordmark glyph (bars) — used in the app logo square.
  window.eqGlyph = function (color, size) {
    size = size || 24;
    const bars = [[5, 9, 14], [10, 5, 14], [15, 7, 10], [19.5, 11, 6]];
    const r = bars.map(([x, y, h]) => `<rect x="${x - 1.4}" y="${y}" width="2.8" height="${h}" rx="1.4" fill="${color}"/>`).join('');
    return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" style="display:block">${r}</svg>`;
  };
})();
