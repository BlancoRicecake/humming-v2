const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const context = { window: {}, location: { search: '?demo=1' }, URLSearchParams };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../assets/notices-common.js'), 'utf8'), context);
const N = context.window.HumNotices;
const valid = { image_url: 'https://hum-track.com/assets/notices/test-image.png', image_alt_ko: '둥지의 새', image_alt_en: 'A bird in a nest' };

test('legacy text notices have no image markup', () => {
  assert.equal(N.imageMarkup({ body_en: 'Still readable' }, 'en'), '');
  assert.equal(N.imageMarkup({ image_url: null }, 'ko'), '');
});

test('only curated static first-party images are accepted', () => {
  for (const url of [valid.image_url, 'https://www.hum-track.com/assets/notices/new_2.webp', 'https://hum-track.com/assets/notices/cover.jpeg']) {
    assert.equal(N.safeImage(url), url);
  }
  for (const url of [
    null, 42, {}, 'http://hum-track.com/assets/notices/a.png',
    'https://evil.example/assets/notices/a.png', 'https://hum-track.com.evil.io/assets/notices/a.png',
    'https://user@hum-track.com/assets/notices/a.png', 'https://hum-track.com:443/assets/notices/a.png',
    'https://hum-track.com/assets/notices/a.svg', 'https://hum-track.com/assets/notices/a.png?track=user',
    'https://hum-track.com/assets/notices/../private.png', 'https://hum-track.com/assets/notices/%2e%2e.png',
    'data:image/png;base64,x', 'javascript:alert(1)', valid.image_url + '\n',
  ]) assert.equal(N.safeImage(url), null, String(url));
});

test('partial, mistyped or oversized image metadata never renders a request', () => {
  for (const row of [
    { ...valid, image_alt_en: '' }, { ...valid, image_alt_ko: 42 },
    { ...valid, image_alt_en: ' '.repeat(5) }, { ...valid, image_alt_ko: 'a'.repeat(301) },
    { ...valid, image_url: 'https://evil.example/a.png' },
  ]) assert.equal(N.imageMarkup(row, 'ko'), '');
});

test('localized alt text is escaped and never becomes executable markup', () => {
  const ko = N.imageMarkup(valid, 'ko');
  const en = N.imageMarkup(valid, 'en');
  assert.match(ko, /alt="둥지의 새"/);
  assert.match(en, /alt="A bird in a nest"/);
  const crafted = N.imageMarkup({ ...valid, image_alt_en: '"><script>alert(1)</script>' }, 'en');
  assert.ok(!crafted.includes('<script>'));
  assert.ok(crafted.includes('&quot;&gt;&lt;script&gt;'));
  assert.match(en, /referrerpolicy="no-referrer"/);
  assert.ok(!en.includes('onerror='));
});

test('an image failure shows fallback without replacing or hiding the body', () => {
  let onError;
  const caption = { hidden: true };
  const image = { hidden: false, complete: false, naturalWidth: 0,
    addEventListener: (event, fn) => { assert.equal(event, 'error'); onError = fn; },
    parentElement: { querySelector: () => caption } };
  const root = { body: 'Important notice body', querySelectorAll: () => [image] };
  N.wireImages(root);
  onError();
  assert.equal(image.hidden, true);
  assert.equal(caption.hidden, false);
  assert.equal(root.body, 'Important notice body');
});

test('already cached image failures are handled too', () => {
  const caption = { hidden: true };
  const image = { hidden: false, complete: true, naturalWidth: 0, addEventListener() {}, parentElement: { querySelector: () => caption } };
  N.wireImages({ querySelectorAll: () => [image] });
  assert.equal(caption.hidden, false);
});

test('both pages and every inline script parse after image integration', () => {
  for (const file of ['../notices/index.html', '../admin/notices/index.html']) {
    const page = fs.readFileSync(path.join(__dirname, file), 'utf8');
    for (const [, script] of page.matchAll(/<script>([\s\S]*?)<\/script>/g)) new vm.Script(script, { filename: file });
  }
});
