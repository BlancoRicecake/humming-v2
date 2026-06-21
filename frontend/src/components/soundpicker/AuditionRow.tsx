import type { AuditionItem, DrumPiece } from "../../types";

interface Props {
  item: AuditionItem;
  selected: boolean;
  loadingId: string | null; // composite: item.key (full) or `${item.key}#${piece}`
  disabled: boolean;
  onPlay: (item: AuditionItem, piece?: DrumPiece) => void;
  onToggle: (item: AuditionItem) => void;
}

function sourceTag(it: AuditionItem): string {
  if (it.source === "gm") return it.sf_bank === 128 ? `kit ${it.sf_program}` : `GM ${it.sf_program}`;
  if (it.source === "sentinel") return "Sentinel";
  return "Catalog";
}

const DRUM_PIECES: { piece: DrumPiece; label: string; title: string }[] = [
  { piece: "kick", label: "K", title: "Kick" },
  { piece: "snare", label: "S", title: "Snare" },
  { piece: "hat", label: "H", title: "Hi-hat" },
];

export function AuditionRow({ item, selected, loadingId, disabled, onPlay, onToggle }: Props) {
  const isDrum = item.track_type === "drums";
  return (
    <div className={"sp-row" + (selected ? " sp-row-sel" : "")}>
      <button
        className="sp-play"
        disabled={disabled || loadingId === item.key}
        onClick={() => onPlay(item)}
        title={isDrum ? "Full beat" : "Preview"}
      >
        {loadingId === item.key ? "…" : "▶"}
      </button>
      {isDrum && (
        <div className="sp-pieces">
          {DRUM_PIECES.map((p) => {
            const id = `${item.key}#${p.piece}`;
            return (
              <button
                key={p.piece}
                className="sp-piece"
                disabled={disabled || loadingId === id}
                onClick={() => onPlay(item, p.piece)}
                title={p.title}
              >
                {loadingId === id ? "…" : p.label}
              </button>
            );
          })}
        </div>
      )}
      <span className="sp-label">{item.label}</span>
      <span className="sp-src meta">{sourceTag(item)}</span>
      <button
        className={"sp-star" + (selected ? " active" : "")}
        onClick={() => onToggle(item)}
        title={selected ? "Remove from curation" : "Add to curation"}
      >
        {selected ? "★" : "☆"}
      </button>
    </div>
  );
}
