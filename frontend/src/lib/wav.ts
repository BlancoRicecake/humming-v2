/**
 * Encode a Float32Array PCM channel into a 16-bit mono WAV Blob.
 */
export function encodeWav(samples: Float32Array, sampleRate: number): Blob {
  const buffer = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(buffer);

  // RIFF header
  writeString(view, 0, "RIFF");
  view.setUint32(4, 36 + samples.length * 2, true);
  writeString(view, 8, "WAVE");
  writeString(view, 12, "fmt ");
  view.setUint32(16, 16, true);              // PCM chunk size
  view.setUint16(20, 1, true);               // format = PCM
  view.setUint16(22, 1, true);               // channels
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);  // byte rate
  view.setUint16(32, 2, true);               // block align
  view.setUint16(34, 16, true);              // bits per sample
  writeString(view, 36, "data");
  view.setUint32(40, samples.length * 2, true);

  let offset = 44;
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    offset += 2;
  }
  return new Blob([buffer], { type: "audio/wav" });
}

function writeString(view: DataView, offset: number, str: string) {
  for (let i = 0; i < str.length; i++) view.setUint8(offset + i, str.charCodeAt(i));
}

/**
 * Decode a recorded Blob (webm/opus/etc) into mono Float32 PCM at the requested rate.
 */
export async function blobToMonoPcm(
  blob: Blob,
  targetSampleRate = 22050,
): Promise<{ samples: Float32Array; sampleRate: number }> {
  const arrayBuf = await blob.arrayBuffer();
  // Decoder context — using default rate first, then we render through OfflineAudioContext.
  const decodeCtx = new (window.AudioContext || (window as any).webkitAudioContext)();
  const audio = await decodeCtx.decodeAudioData(arrayBuf.slice(0));
  await decodeCtx.close();

  const channels = audio.numberOfChannels;
  const length = audio.length;

  // mix to mono
  let mono = new Float32Array(length);
  for (let c = 0; c < channels; c++) {
    const data = audio.getChannelData(c);
    for (let i = 0; i < length; i++) mono[i] += data[i] / channels;
  }

  if (audio.sampleRate === targetSampleRate) {
    return { samples: mono, sampleRate: targetSampleRate };
  }

  // resample via OfflineAudioContext
  const ratio = targetSampleRate / audio.sampleRate;
  const outLength = Math.floor(length * ratio);
  const offline = new OfflineAudioContext(1, outLength, targetSampleRate);
  const src = offline.createBufferSource();
  const buf = offline.createBuffer(1, length, audio.sampleRate);
  buf.copyToChannel(mono, 0);
  src.buffer = buf;
  src.connect(offline.destination);
  src.start();
  const rendered = await offline.startRendering();
  return { samples: rendered.getChannelData(0).slice(0), sampleRate: targetSampleRate };
}
