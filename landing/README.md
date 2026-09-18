# HumTrack landing page

Static bilingual Korean/English site for https://hum-track.com.

- Entry: index.html (inline page CSS, bilingual data-ko/data-en text).
- Existing mobile demonstrations: app.css, screens.js, icons.js.
- New desktop image: assets/desktop-workspace-20260918.png, captured from the Windows development preview.
- Updates section documents guided creation, sample editing, keyboard mappings, workspace resizing and timeline zoom.
- Platform status distinguishes store apps, locally validated Windows development preview and unverified macOS work. No desktop binary is published by this update.
- Legal pages and store download links are preserved.

Preview: python -m http.server 5500 --directory landing
Deployment: .github/workflows/deploy-landing.yml deploys landing changes on main to the existing Vercel project. Keep the existing domain and hosting; no migration is required.

When publishing a desktop build in future, verify its public download URL and distribution readiness before adding an install button. Update platform status and FAQ together.
