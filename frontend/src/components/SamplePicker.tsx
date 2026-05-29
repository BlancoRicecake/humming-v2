import { useEffect, useRef, useState } from "react";
import { fetchSampleBlob, listSamples, type SampleInfo } from "../lib/api";

interface Props {
  onSourceLoaded: (blob: Blob, label: string) => Promise<void>;
  disabled?: boolean;
}

export function SamplePicker({ onSourceLoaded, disabled }: Props) {
  const [samples, setSamples] = useState<SampleInfo[]>([]);
  const [loadingSlug, setLoadingSlug] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    listSamples()
      .then(setSamples)
      .catch((e) => {
        console.warn("sample list failed:", e);
        setError(String(e?.message ?? e));
      });
  }, []);

  const loadSample = async (slug: string, label: string) => {
    setError(null);
    setLoadingSlug(slug);
    try {
      const blob = await fetchSampleBlob(slug);
      await onSourceLoaded(blob, label);
    } catch (e: any) {
      setError(e?.message ?? String(e));
    } finally {
      setLoadingSlug(null);
    }
  };

  const onFileChange = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setError(null);
    setLoadingSlug("__file__");
    try {
      await onSourceLoaded(file, file.name);
    } catch (err: any) {
      setError(err?.message ?? String(err));
    } finally {
      setLoadingSlug(null);
      if (fileRef.current) fileRef.current.value = "";
    }
  };

  return (
    <div className="sample-picker">
      <div className="sample-row">
        <span className="sample-label">Samples</span>
        {samples.length === 0 && !error && <span className="meta">loading…</span>}
        {samples.map((s) => (
          <button
            key={s.slug}
            onClick={() => loadSample(s.slug, s.label)}
            disabled={disabled || loadingSlug === s.slug}
          >
            {loadingSlug === s.slug ? "loading…" : s.label}
          </button>
        ))}
        <span className="sample-label">·</span>
        <label className="file-pick">
          <input
            ref={fileRef}
            type="file"
            accept="audio/*,.m4a,.mp3,.wav,.webm,.ogg,.flac"
            onChange={onFileChange}
            disabled={disabled || loadingSlug !== null}
          />
          <span className="file-button">Choose file…</span>
        </label>
      </div>
      {error && <div className="meta" style={{ color: "var(--err)" }}>{error}</div>}
    </div>
  );
}
