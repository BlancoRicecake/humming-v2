import { useCallback, useRef, useState } from "react";

export type RecorderState = "idle" | "requesting" | "recording" | "processing" | "ready" | "error";

export function useRecorder() {
  const [state, setState] = useState<RecorderState>("idle");
  const [error, setError] = useState<string | null>(null);
  const [blob, setBlob] = useState<Blob | null>(null);
  const [elapsed, setElapsed] = useState(0);

  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const streamRef = useRef<MediaStream | null>(null);
  const intervalRef = useRef<number | null>(null);
  const startRef = useRef<number>(0);

  const start = useCallback(async () => {
    setError(null);
    setState("requesting");
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
      });
      streamRef.current = stream;
      const mime = pickMimeType();
      const recorder = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined);
      chunksRef.current = [];
      recorder.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data);
      };
      recorder.onstop = () => {
        const out = new Blob(chunksRef.current, { type: mime || "audio/webm" });
        setBlob(out);
        setState("ready");
        stream.getTracks().forEach((t) => t.stop());
        streamRef.current = null;
      };
      mediaRecorderRef.current = recorder;
      recorder.start(50);
      startRef.current = performance.now();
      setElapsed(0);
      intervalRef.current = window.setInterval(() => {
        setElapsed((performance.now() - startRef.current) / 1000);
      }, 100);
      setState("recording");
    } catch (e: any) {
      setError(e?.message ?? String(e));
      setState("error");
    }
  }, []);

  const stop = useCallback(() => {
    if (intervalRef.current) {
      window.clearInterval(intervalRef.current);
      intervalRef.current = null;
    }
    const rec = mediaRecorderRef.current;
    if (rec && rec.state !== "inactive") {
      setState("processing");
      rec.stop();
    }
  }, []);

  const reset = useCallback(() => {
    setBlob(null);
    setElapsed(0);
    setState("idle");
    setError(null);
  }, []);

  return { state, error, blob, elapsed, start, stop, reset };
}

function pickMimeType(): string | null {
  const candidates = [
    "audio/webm;codecs=opus",
    "audio/webm",
    "audio/ogg;codecs=opus",
    "audio/mp4",
  ];
  for (const c of candidates) {
    if (typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(c)) return c;
  }
  return null;
}
