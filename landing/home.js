(() => {
  const validLang = value => value === 'ko' || value === 'en';
  const meta = {
    ko: { title: 'HumTrack — 흥얼거림에서, 나만의 트랙으로', description: '떠오른 멜로디를 허밍으로 담고, 비트를 더하고, 나만의 곡으로. HumTrack 모바일 앱과 새롭게 만드는 Studio를 만나보세요.' },
    en: { title: 'HumTrack — Your idea. Your track.', description: 'Hum a melody, build a beat, and make it yours. Discover the HumTrack mobile app and the new Studio development preview.' }
  };
  function setLang(lang, persist = true) {
    if (!validLang(lang)) return;
    document.documentElement.lang = lang;
    document.querySelectorAll('[data-ko][data-en]').forEach(el => { el.textContent = el.dataset[lang]; });
    document.querySelectorAll('[data-lang]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.lang === lang)));
    document.title = meta[lang].title;
    [['name','description',meta[lang].description], ['property','og:title',meta[lang].title], ['property','og:description',meta[lang].description], ['name','twitter:title',meta[lang].title], ['name','twitter:description',meta[lang].description], ['property','og:locale',lang === 'ko' ? 'ko_KR' : 'en_US']].forEach(([attr,key,value]) => document.querySelector(`meta[${attr}="${key}"]`)?.setAttribute('content',value));
    document.querySelectorAll('[data-home-link]').forEach(link => { link.href = 'vision.html?lang=' + lang; });
    if (persist) {
      try { localStorage.setItem('ht_lang',lang); } catch (_) {}
      const url = new URL(location.href); url.searchParams.set('lang',lang);
      history.replaceState(null,'',url);
    }
  }
  let saved;
  try { saved = localStorage.getItem('ht_lang'); } catch (_) {}
  const query = new URLSearchParams(location.search).get('lang');
  setLang(validLang(query) ? query : validLang(saved) ? saved : navigator.language.toLowerCase().startsWith('ko') ? 'ko' : 'en', false);
  document.querySelectorAll('[data-lang]').forEach(button => button.addEventListener('click',() => setLang(button.dataset.lang)));
})();
