# Raw research — hum/pitch tech, AI music tools, legal (collected 2026-10-12)

# HumTrack research: hum-to-MIDI, AI music tools, and the legal landscape (as of 2026-10-12)

The shared WebSearch budget for this turn ran out near the end, so a few items are marked **[unverified]**. Every other claim has a URL. Licenses are as stated on the repo or model pages. Check the LICENSE files yourself before shipping. This is not legal advice.

---

## Correction to HumTrack's current assumption: YuE weights are now Apache-2.0

HumTrack ruled out YuE because its weights were CC BY-NC. That is out of date. The YuE repo says: "The YuE model (including its weights) is now released under the Apache License, Version 2.0". The change was announced 2025-01-30. The project encourages commercial use of outputs and asks for credit to "YuE by HKUST/M-A-P" ([github.com/multimodal-art-projection/YuE](https://github.com/multimodal-art-projection/YuE)).

A remaining risk is that the source of its training data is not disclosed. The Suno rulings below show that training-data provenance, not the license, is where the legal exposure is.

---

## A. Voice/hum-to-MIDI and pitch technology

### Benchmarks (humming and singing transcription)

**HumTrans test set** ([Dynamic HumTrans, arXiv 2410.05455](https://arxiv.org/html/2410.05455v1)): mir_eval, 50 ms onset tolerance, offsets ignored.

| Method | Octave-aware F1, notes + onsets | Octave-aware F1, notes only |
|---|---|---|
| Dynamic HumTrans (CNN + DP) | **0.651** | **0.817** |
| MIR-ST500 | 0.361 | 0.488 |
| VOCANO | 0.341 | 0.444 |
| basic_pitch | 0.268 | 0.432 |

- This independently confirms HumTrack's decision to reject Basic Pitch for humming.
- pYIN was not evaluated in that paper.
- The method is Basic-Pitch-like: CQT input with harmonic stacking, a per-frame note classifier, then Viterbi/dynamic-programming cleanup.

**Singing, note level** ([STARS, arXiv 2507.06670](https://arxiv.org/html/2507.06670v1)), COnPOff F1:

| Method | COnPOff F1 | RPA |
|---|---|---|
| STARS | 71.0 | 86.7 |
| ROSVOT | 70.2 | — |
| VOCANO | 50.2 | — |

STARS code and weights are not stated as released.

### Pitch and transcription models

| Tool | What it does | License / commercial use | Cost | Fit |
|---|---|---|---|---|
| **pYIN (librosa)** | Probabilistic f0 tracking | librosa is ISC **[unverified]** | Free | **Use now** (current baseline) |
| **Basic Pitch** (Spotify) | Polyphonic audio-to-MIDI; TF, CoreML, TFLite and ONNX builds ([repo](https://github.com/spotify/basic-pitch)) | Apache-2.0 | Free | **Avoid as the default for humming.** F1 0.268 on HumTrans (above) |
| **RMVPE** | Robust f0, best under noise. 90.4M params; RTF 0.033 on an RTX 4090 ([FCPE paper](https://arxiv.org/html/2509.15140v1)) | Repo Apache-2.0 ([repo](https://github.com/Dream-High/RMVPE)); weights license not stated | Free | **Evaluate.** Phone recordings are noisy, and it holds up best there: 43.6 RPA at −20 dB vs FCPE 29.8 |
| **FCPE** | Fast f0, 10.6M params. 96.79 RPA on MIR-1K; 5.3× faster than RMVPE. Has a built-in `extact_midi()` ([paper](https://arxiv.org/html/2509.15140v1), [repo](https://github.com/CNChTu/FCPE)) | Code MIT; weights license not stated | Free | **Evaluate** (cheap to run on a server) |
| **PESTO (v2)** | Self-supervised, about 130k params, under 10 ms latency, streaming mode, ONNX/TorchScript export ([arXiv 2508.01488](https://arxiv.org/abs/2508.01488), [repo](https://github.com/SonyCSLParis/pesto)) | **LGPL-3.0** | Free | **Evaluate for on-device, real-time pitch display.** Best MIR-1K RPA, 98.47 ([FCPE paper](https://arxiv.org/html/2509.15140v1)). LGPL is fine if loaded as a replaceable module or ONNX file **[get legal check]** |
| **CREPE / torchcrepe** | Supervised f0 with tiny and full sizes ([torchcrepe](https://github.com/maxrmorrison/torchcrepe)) | MIT | Free | **Avoid.** 77× slower than FCPE and collapses in noise (1.09 RPA at −20 dB) ([paper](https://arxiv.org/html/2509.15140v1)) |
| **SPICE** (Google) | Self-supervised f0; the TF Hub tutorial goes from singing to notes to MIDI ([tutorial](https://www.tensorflow.org/hub/tutorials/spice)) | Model license not stated on the tutorial page | Free | Low priority. Superseded by PESTO |
| **ROSVOT** | Singing to MIDI notes; robust to noise and accompaniment ([repo](https://github.com/RickyL-2000/ROSVOT)) | Code MIT; checkpoints (Google Drive, trained on M4Singer only) have no stated license. M4Singer is research-licensed **[unverified]** | Free | **Evaluate as a benchmark reference.** Probably not usable commercially as-is |
| **YourMT3+** | Multi-instrument transcription ([repo](https://github.com/mimbres/YourMT3)) | **GPL-3.0** | Free | **Avoid.** Wrong task, and GPL |
| **MT3** (Google) | Multi-instrument transcription | Apache-2.0 **[unverified]** | Free | Wrong task |
| **Dubler 2** (Vochlea) | Real-time voice-to-MIDI on desktop; beatbox triggers, voice-to-chords ([review](https://musictech.com/reviews/software-instruments/vochlea-dubler-2-review/)) | Proprietary | $249 for software; $329 kit with mic | Competitor and UX reference. Its "stickiness" setting trades responsiveness for pitch stability, and inaccurate singers create extra notes that need editing. This is the same problem HumTrack has |
| **Melodyne 5** | Pro-grade pitch editing and audio-to-MIDI | Proprietary | Paid tiers ([store](https://www.pluginboutique.com/meta_product/3-Studio-Tools/48-Audio-Editor/6460-Celemony-Melodyne-5-Studio)) | UX reference for note "blobs" |

### Consumer hum-to-song apps (competitors)

- **HumToSong** (iOS): released 2025-11-23. Free, under 1k downloads, 2.6★ ([mwm.ai](https://mwm.ai/apps/humtosong/6755473455)).
- **Humtap** (iOS): hum or tap to a full song ([aiapps](https://www.aiapps.com/items/humtap/)). Whether it is still active is unverified.
- Several web "hum to song" generators exist ([songcre.ai](https://www.songcre.ai/hum-to-song)).
- **None of these offer editable notes plus deterministic backing.** That combination is HumTrack's opening.

---

## B. AI music generation and assistive tools

### Full-song and audio generation models

| Tool | What it does | License / commercial use | Cost | Fit |
|---|---|---|---|---|
| **Suno v6** | Text/lyrics to song. Launched 2026-09-09, built with Warner, BMG and Believe on "licensed data" ([Rundown](https://www.therundown.ai/news/suno-v6-music-partners-paid-fan-remixes)) | Proprietary; no public API. Free tier lost downloads. Pro gets 20 downloads/month, Premier 60 | Subscription | **Avoid** (no API; being sued, see C) |
| **Udio** | Song generation. Settled with UMG (Oct 2025) and WMG; moving to a "walled garden" with downloads blocked ([DMN](https://www.digitalmusicnews.com/?p=333617)) | Proprietary | — | **Avoid** |
| **ElevenLabs Eleven Music** | Text to music. Launched 2025-08-05; training data licensed via Merlin and Kobalt; cleared for commercial use by tier ([YourStory](https://yourstory.com/ai-story/elevenlabs-eleven-music-ai-generator-launch)) | Proprietary, paid | Paid | Evaluate only if you drop the "no paid APIs" rule. It is the cleanest licensed option |
| **ACE-Step 1.5** | Lyrics to song. Also: cover, repaint, **Vocal2BGM** (backing for a vocal), stem separation, LoRA. Runs in under 4 GB VRAM; XL (4B) released 2026-04-02 ([repo](https://github.com/ace-step/ACE-Step-1.5)) | Code **MIT**; weights license not stated on the repo; training data not disclosed | Free / self-hosted | **Evaluate, with legal caution.** Vocal2BGM maps directly onto "hum, then backing" |
| **YuE** | Lyrics to song ([repo](https://github.com/multimodal-art-projection/YuE)) | **Apache-2.0 for code and weights** (since 2025-01-30); training data undisclosed | Free | Re-evaluate. Provenance risk remains |
| **DiffRhythm v1.2** | Full song up to 4m45s ([repo](https://github.com/ASLP-lab/DiffRhythm)) | Apache-2.0 for code and DiT weights; data undisclosed | Free | Same provenance caveat |
| **SongGeneration 2 / LeVo 2** (Tencent) | Lyrics to song. v2-large released around 2026-03-01; needs 22–28 GB VRAM ([gaga.art](https://gaga.art/blog/songgeneration-2/), [HF](https://huggingface.co/tencent/SongGeneration)) | Custom "Other" license; terms could not be read **[unverified]**. Tencent model licenses often exclude some regions | Free | Check the LICENSE before any use |
| **MusicGen / AudioCraft** | Text to music ([repo](https://github.com/facebookresearch/audiocraft)) | Code MIT; **weights CC-BY-NC 4.0** | Free | **Avoid** for commercial use |
| **Stable Audio Open 1.0 / Small** | Text to audio, up to 47 s; no realistic vocals. Trained only on CC0, CC-BY and CC-Sampling+ audio (Freesound, FMA). Small is 0.5B params with an Arm/LiteRT guide ([1.0](https://huggingface.co/stabilityai/stable-audio-open-1.0), [Small](https://huggingface.co/stabilityai/stable-audio-open-small)) | Stability Community License: free under $1M annual revenue; you own outputs ([license](https://stability.ai/license)) | Free under $1M | **Use now for loops, FX and textures.** The most defensible training-data story among open models |
| **Magenta RealTime** | Real-time instrumental streaming. Trained on about 190k hours of stock music. Real-time inference needs Apple Silicon ([repo](https://github.com/magenta/magenta-realtime), [HF](https://huggingface.co/google/magenta-realtime)) | Code Apache-2.0; **weights CC-BY 4.0** | Free | Evaluate for a later "jam" feature. Not mobile-ready |
| **Lyria RealTime** (Gemini API) | Steerable instrumental streaming over WebSocket. Experimental; output always watermarked ([docs](https://ai.google.dev/gemini-api/docs/realtime-music-generation?hl=ko)) | Google API terms | Paid API | Avoid for now (cost, experimental status) |

### Symbolic accompaniment (MIDI)

| Tool | What it does | License / data | Fit |
|---|---|---|---|
| **Anticipatory Music Transformer** | Takes a **melody as control input and generates accompaniment** ([repo](https://github.com/jthickstun/anticipation)) | Code Apache-2.0; weights `stanford-crfm/music-medium-800k` Apache-2.0 (360M params) ([HF](https://huggingface.co/stanford-crfm/music-medium-800k)). Trained on **Lakh MIDI**, which contains fan transcriptions of commercial songs | **Evaluate as an optional "AI variation" next to the deterministic engine.** Licenses are clean; the dataset is a gray area |
| **AccoMontage-3** | Lead sheet to piano, then multi-track arrangement ([repo](https://github.com/zhaojw1998/AccoMontage-3)) | Code MIT; checkpoints and data have no license (trained on LMD and Slakh) | Evaluate. Unclear weight license |
| **Text2midi** | Text to MIDI ([repo](https://github.com/AMAAI-Lab/Text2midi)) | Code MIT; weights license not stated; trained on MidiCaps/Lakh | Low priority |
| **MIDI-LLM** (NeurIPS 2025) | Llama-3.2-1B extended with MIDI tokens; beats Text2midi ([arXiv](https://arxiv.org/abs/2511.03942v1)) | Llama 3.2 Community License applies to derivatives **[unverified]** | Low priority |
| **BandLab SongStarter** | Generates three ideas (beat, melody, chords) per roll; free to keep ([MusicInAfrica](https://musicinafrica.net/node/212735)) | Proprietary | Competitor and UX reference ("3 candidates" matches HumTrack's design) |

### Stem separation and other tools

| Tool | License | Notes | Fit |
|---|---|---|---|
| **Demucs / HTDemucs** | MIT | Repo archived 2025-01-01; maintained fork at adefossez/demucs; htdemucs scores 9.0 dB SDR ([repo](https://github.com/facebookresearch/demucs)) | **Use now** if you need stems from user uploads |
| **BS-RoFormer / MDX via python-audio-separator** | Tool MIT; **weights licenses not stated** ([repo](https://github.com/nomadkaraoke/python-audio-separator)) | Many UVR weights were trained on MUSDB and similar sets **[unverified]** | Avoid commercially until weights are verified |
| **Spleeter** | MIT **[unverified this session]** | Older and lower quality | Fallback only |
| **Moises** | Proprietary. Free plan: 5 uploads/month. Premium $3.99/month; Pro $9.99/month. No developer API mentioned ([review](https://sunowatermark.com/blog/moises-ai-review-2026/)) | — | Competitor reference |
| **Synthesizer V 2 / ACE Studio** | Proprietary singing synthesis using licensed voice databases. Pricing could not be retrieved **[unverified]** ([store](https://store.dreamtonics.com/product/bundle-synthesizer-v-studio-2-pro-any-voice-database)) | — | Reference for an "AI singer" feature |
| **RVC / so-vits** | Code is MIT-style, but community voice models are often unlicensed clones of real singers | — | **Avoid** user-uploaded voice models (impersonation laws, below) |
| **LANDR** | Not researched (search budget ran out) | — | — |

---

## C. Legal and ethical landscape, 2025–2026

**Label litigation**
- UMG settled with Udio on 2025-10-31; WMG settled with Suno in November 2025 ([dynamoi](https://dynamoi.com/learn/ai-music-distribution/ai-music-copyright-cases-timeline), [MBW](https://www.musicbusinessworldwide.com/warner-music-group-settles-with-suno-strikes-first-of-its-kind-deal-with-ai-song-generator/)).
- **2026-09-18: UMG and Sony filed a second lawsuit against Suno.** It covers 60,202 recordings, with theoretical damages of about $9B, and alleges v6 is "fruit of the same poisoned tree" because it was distilled from earlier models' outputs. Suno admitted in a filing to obtaining YouTube audio with yt-dlp ([MBW](https://www.musicbusinessworldwide.com/universal-and-sony-sue-suno-for-a-second-time-claiming-platforms-v6-models-are-the-fruit-of-the-same-poisoned-tree/)).
- Sony has not settled with either company ([Dubspot](https://blog.dubspot.com/suno-udio-ai-music-lawsuits-2026)).

**Europe**
- In Munich, GEMA beat Suno: training in the US on GEMA repertoire was found to infringe, and outputs matched the originals. Announced 2026-07-31. This followed GEMA's November 2025 win against OpenAI ([GEMA](https://www.gema.de/en/w/gema-prevails-over-suno)).
- EU AI Act general-purpose-model obligations have applied since 2025-08-02, with enforcement from 2026-08-02. Providers must publish a training-data summary and a copyright policy ([Mayer Brown](https://www.mayerbrown.com/en/insights/publications/2025/08/eu-ai-act-news-rules-on-general-purpose-ai-start-applying-guidelines-and-template-for-summary-of-training-data-finalized)).
- Article 50 rules on marking AI-generated content still apply from 2026-08-02. Systems already on the market get until 2026-12-02. The AI Omnibus was adopted 2026-06-29 ([Kingsley Napley](https://www.kingsleynapley.co.uk/our-insights/articles/the-eu-ai-omnibus-where-are-we-now-and-what-should-businesses-do-next/)).

**US Copyright Office**
- Part 2 (2025-01-29): **prompts alone are not enough for copyright.** A human-authored work that is recognizable in the output, and human arrangement or modification, can be protected ([copyright.gov](https://copyright.gov/newsnet/2025/1060.html)).
- Part 3 (2025-05-09): commercial training that produces competing content is unlikely to be fair use; it introduces a "market dilution" argument ([Lowenstein](https://www.lowenstein.com/news-insights/publications/client-alerts/us-copyright-office-releases-long-awaited-report-on-generative-ai-training-and-copyright-law)).

**Voice and likeness**
- Tennessee's ELVIS Act has been in force since 2024-07-01.
- The federal NO FAKES Act was reintroduced 2026-05-20 and is not yet law ([Promise Legal](https://blog.promise.legal/ai-voice-clones-no-fakes-act-creators/)).

**Platforms**
- **Spotify** (September 2025): AI music is allowed. It bans unauthorized voice clones, runs a spam filter, and uses voluntary DDEX AI-credit disclosure ([Relix](https://relix.com/news/detail/spotify-targets-ai-slop-and-embraces-ai-music-in-new-policy)).
- **Deezer** (April 2026): 44% of daily uploads (about 75k tracks/day) are fully AI-made. It tags them and demonetizes 85% as fraudulent ([Mixmag](https://mixmag.net/read/almost-half-all-music-uploaded-deezer-daily-ai-generated-news)).
- **YouTube**: disclosure is required, and the July 2025 "inauthentic content" monetization rule applies. This is a third-party summary ([OutlierKit](https://outlierkit.com/resources/ai-generated-music-youtube-monetization-2026/)).
- **TikTok**: labels are required where content could mislead; it auto-labels via C2PA ([dynamoi](https://dynamoi.com/learn/faqs/is-ai-music-allowed-on-tiktok)). Vendor blog, partly unverified.

**What "commercially safe" means in practice**
1. A permissive license on code and weights.
2. Training data that is known and licensed (or CC/public domain).
3. No voice or likeness cloning.
4. Human authorship in the output.
5. Disclosure and labeling.

Third-party certification exists through Fairly Trained, which has certified Jen, Kits AI and Voicemod ([MBW](https://www.musicbusinessworldwide.com/music-ai-platforms-can-get-a-fairly-trained-certification-for-meeting-ethical-standards-those-standards-just-got-tougher/)). Korea's KOMCA policy on registering AI-assisted works was not researched because the search budget ran out **[unverified, worth checking]**.

---

## The 5 most decision-relevant findings and what to do

1. **Humming is a distinct hard problem, and Basic Pitch is measurably bad at it** (octave-aware F1 0.27 vs 0.65 for a purpose-built model). **Do this:** build a 30–50 clip HumTrack benchmark that includes the public HumTrans test split. On it, compare:
   - pYIN (current)
   - **RMVPE** and **FCPE** for f0, each feeding your existing note segmentation
   - FCPE's built-in `extact_midi()`
   - a Dynamic-HumTrans-style dynamic-programming/Viterbi note smoother on top of the best f0

   Of all the options, the DP smoothing step is the most likely to fix over-split legato notes. Use **PESTO** (LGPL, about 130k params, under 10 ms) only for on-device, real-time pitch display in Flutter, not for the final transcription.

2. **HumTrack's architecture is also its legal advantage.** The user's hummed melody is the human-authored element (Copyright Office Part 2), and deterministic rule-based backing carries no training-data risk. Keep the deterministic chord/drum/bass engine as the default and **market it as "your melody, your song, no scraped data."**

3. **The open full-song generators are not safe to put behind a global product yet.** Suno has been sued again over v6 and lost to GEMA in Munich; Udio is locked down. YuE (now Apache-2.0), ACE-Step 1.5 and DiffRhythm all have permissive licenses but undisclosed training data, which is exactly what the courts are now ruling on. Keep them out of the main path. If you prototype ACE-Step's Vocal2BGM, label it as experimental and AI-generated.

4. **If you add generative AI, use the options whose training data is clean.** Stable Audio Open (CC-licensed data, free under $1M revenue) suits loops and textures. Anticipatory Music Transformer (Apache weights) can serve as an optional "AI variation" for MIDI accompaniment generated from the user's melody, though its Lakh MIDI training data is a gray area. Paid but licensed: ElevenLabs Music.

5. **Build compliance in now, since the EU Article 50 deadline (2026-08-02; 2026-12-02 for systems already on the market) has passed and platforms label AI content.**
   - Record in export metadata which parts were AI-generated versus rule-based or user-made (DDEX-style credits; C2PA where feasible).
   - Never allow voice cloning of real people.
   - Remind users of Spotify, YouTube and TikTok disclosure rules when they export.

**Facts worth remembering:** YuE's license is now Apache-2.0 for code and weights, not CC BY-NC. UMG and Sony filed a second lawsuit against Suno on 2026-09-18. GEMA beat Suno in Munich (announced 2026-07-31).
