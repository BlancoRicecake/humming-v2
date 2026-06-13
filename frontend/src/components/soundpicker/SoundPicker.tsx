import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type {
  AuditionItem,
  CuratedSound,
  CurationMap,
  RenderCapabilities,
  TrackType,
} from "../../types";
import { auditionRender, getAuditionPalette, toRenderRequest } from "../../lib/api";
import { playAudioBlob } from "../../lib/playback";
import { AuditionList } from "./AuditionList";

const ROLES: TrackType[] = ["melody", "bass", "drums"];
const ROLE_LABELS: Record<TrackType, string> = { melody: "Melody", bass: "Bass", drums: "Drums" };
const LS_KEY = "soundlab.curation.v1";

function emptyCuration(): CurationMap {
  return { melody: [], bass: [], drums: [] };
}

function loadCuration(): CurationMap {
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (!raw) return emptyCuration();
    const p = JSON.parse(raw);
    return {
      melody: Array.isArray(p.melody) ? p.melody : [],
      bass: Array.isArray(p.bass) ? p.bass : [],
      drums: Array.isArray(p.drums) ? p.drums : [],
    };
  } catch {
    return emptyCuration();
  }
}

function saveCuration(c: CurationMap) {
  try {
    localStorage.setItem(LS_KEY, JSON.stringify(c));
  } catch {
    /* quota / private mode — non-fatal */
  }
}

function itemToCurated(it: AuditionItem): CuratedSound {
  return {
    key: it.key,
    source: it.source,
    label: it.label,
    category: it.category,
    sf_bank: it.sf_bank,
    sf_program: it.sf_program,
    track_type: it.track_type,
    gm: it.gm,
    soundfont_id: it.soundfont_id,
    sentinel_id: it.sentinel_id,
    starred_at: new Date().toISOString(),
  };
}

interface Props {
  caps: RenderCapabilities | null;
}

export function SoundPicker({ caps }: Props) {
  const [role, setRole] = useState<TrackType>("melody");
  const [items, setItems] = useState<AuditionItem[]>([]);
  const [loadingPalette, setLoadingPalette] = useState(false);
  const [paletteErr, setPaletteErr] = useState<string | null>(null);
  const [loadingKey, setLoadingKey] = useState<string | null>(null);
  const [curation, setCuration] = useState<CurationMap>(() => loadCuration());
  const [copied, setCopied] = useState(false);
  const playingRef = useRef<HTMLAudioElement | null>(null);

  const engineOk = !!caps?.soundfont_available;

  useEffect(() => {
    saveCuration(curation);
  }, [curation]);

  useEffect(() => {
    let cancelled = false;
    setLoadingPalette(true);
    setPaletteErr(null);
    getAuditionPalette(role)
      .then((r) => {
        if (!cancelled) setItems(r.items);
      })
      .catch((e) => {
        if (!cancelled) {
          setItems([]);
          setPaletteErr(String(e?.message ?? e));
        }
      })
      .finally(() => {
        if (!cancelled) setLoadingPalette(false);
      });
    return () => {
      cancelled = true;
    };
  }, [role]);

  const onPlay = useCallback(
    async (item: AuditionItem) => {
      if (!engineOk) return;
      if (playingRef.current) {
        playingRef.current.pause();
        playingRef.current = null;
      }
      setLoadingKey(item.key);
      try {
        const blob = await auditionRender(toRenderRequest(item));
        playingRef.current = await playAudioBlob(blob);
      } catch (e) {
        console.error("audition render failed", e);
      } finally {
        setLoadingKey((k) => (k === item.key ? null : k));
      }
    },
    [engineOk],
  );

  const selectedKeys = useMemo(
    () => new Set(curation[role].map((s) => s.key)),
    [curation, role],
  );

  const onToggle = useCallback((item: AuditionItem) => {
    setCuration((cur) => {
      const list = cur[item.role];
      const exists = list.some((s) => s.key === item.key);
      const next = exists
        ? list.filter((s) => s.key !== item.key)
        : [...list, itemToCurated(item)];
      return { ...cur, [item.role]: next };
    });
  }, []);

  const buildExport = useCallback(() => {
    const sf2 = caps?.sf2_path ? caps.sf2_path.split(/[\\/]/).pop() : null;
    return {
      version: 1,
      exported_at: new Date().toISOString(),
      soundfont: sf2,
      counts: {
        melody: curation.melody.length,
        bass: curation.bass.length,
        drums: curation.drums.length,
      },
      tracks: curation,
    };
  }, [curation, caps]);

  const onDownload = useCallback(() => {
    const blob = new Blob([JSON.stringify(buildExport(), null, 2)], {
      type: "application/json",
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "curation.json";
    a.click();
    URL.revokeObjectURL(url);
  }, [buildExport]);

  const onCopy = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(JSON.stringify(buildExport(), null, 2));
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch (e) {
      console.error("clipboard copy failed", e);
    }
  }, [buildExport]);

  const onClear = useCallback(() => {
    if (window.confirm("Clear all curated sounds (all track types)?")) {
      setCuration(emptyCuration());
    }
  }, []);

  const total =
    curation.melody.length + curation.bass.length + curation.drums.length;

  return (
    <div className="sp">
      <div className="sp-bar row">
        <div className="sp-roles">
          {ROLES.map((r) => (
            <button
              key={r}
              className={role === r ? "active" : ""}
              onClick={() => setRole(r)}
            >
              {ROLE_LABELS[r]}
              {curation[r].length > 0 ? ` (${curation[r].length})` : ""}
            </button>
          ))}
        </div>
        <div className="sp-export row">
          <span className="meta">Curated: {total}</span>
          <button className="primary" disabled={total === 0} onClick={onDownload}>
            Download JSON
          </button>
          <button disabled={total === 0} onClick={onCopy}>
            {copied ? "Copied ✓" : "Copy"}
          </button>
          <button disabled={total === 0} onClick={onClear}>
            Clear
          </button>
        </div>
      </div>

      {!engineOk && (
        <p className="warn">
          SoundFont engine unavailable — {caps?.error ?? "backend not initialized"}.
          Preview is disabled.
        </p>
      )}
      {paletteErr && <p className="err">Palette failed: {paletteErr}</p>}
      {loadingPalette ? (
        <p className="meta">Loading {ROLE_LABELS[role]} palette…</p>
      ) : (
        <AuditionList
          items={items}
          selectedKeys={selectedKeys}
          loadingKey={loadingKey}
          disabled={!engineOk}
          onPlay={onPlay}
          onToggle={onToggle}
        />
      )}
    </div>
  );
}
