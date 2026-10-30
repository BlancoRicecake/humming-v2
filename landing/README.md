# HumTrack homepage — October 2026

Static bilingual Korean/English site for https://hum-track.com.

- Entry: index.html (semantic HTML, bilingual data-ko/data-en text), home.css, home.js.
- Language selection: KO/EN buttons, persistent preference and shareable ?lang=ko|en URLs.
- Structure: introduction → creative flow → Studio preview → Free/Pro → FAQ → downloads/contact.
- Existing mobile demonstration assets are retained but are no longer loaded by the homepage.
- Desktop image: assets/studio-editor-20261030.webp, from the current UI-005 Windows QA capture.
- Updates cover arrangement/edit views, playback and section/loop controls, collapsible inspector, note/track controls and in-key filter. These describe the development version, not the public mobile release.
- Platform status distinguishes store apps, locally validated Windows development preview and unverified macOS work. No desktop binary is published by this update.
- Legal pages and store download links are preserved.

Preview: python -m http.server 5501 --bind 127.0.0.1 --directory landing
Deployment: .github/workflows/deploy-landing.yml deploys landing changes on main to the existing Vercel project. Keep the existing domain and hosting; no migration is required.

When publishing a desktop build in future, verify its public download URL and distribution readiness before adding an install button. Update platform status and FAQ together.

## Contacts and verification (2026-10-30)

- Contact: mailto:humtrack@gmail.com on both languages and existing policy pages.
- X: https://x.com/Humtrack in the homepage header on both languages, with an X icon and outlined button; also linked from the vision page.
- Ko-fi: https://ko-fi.com/humtrack in the homepage header as a lime-tinted coffee button, English only. On narrow screens the social buttons form a second header row. Its profile, amount entry and Tip button loaded in a browser. No payment was submitted; settlement is unverified.
- Store URLs loaded. Public store descriptions still show heobusy@gmail.com; changing store listings is separate from the homepage update. A mailto link does not verify mailbox delivery.
- Prices and trial availability are confirmed in the app purchase screen instead of hardcoded. Free saves four songs; Pro adds unlimited saves and WAV/MIDI/stem exports.
- FAQ uses native details/summary for keyboard access. Reduced motion and visible focus styles are supported.
