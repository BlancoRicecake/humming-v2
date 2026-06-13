import type { AuditionItem } from "../../types";

interface Props {
  item: AuditionItem;
  selected: boolean;
  loading: boolean;
  disabled: boolean;
  onPlay: (item: AuditionItem) => void;
  onToggle: (item: AuditionItem) => void;
}

function sourceTag(it: AuditionItem): string {
  if (it.source === "gm") return it.sf_bank === 128 ? `kit ${it.sf_program}` : `GM ${it.sf_program}`;
  if (it.source === "sentinel") return "Sentinel";
  return "Catalog";
}

export function AuditionRow({ item, selected, loading, disabled, onPlay, onToggle }: Props) {
  return (
    <div className={"sp-row" + (selected ? " sp-row-sel" : "")}>
      <button
        className="sp-play"
        disabled={disabled || loading}
        onClick={() => onPlay(item)}
        title="Preview"
      >
        {loading ? "…" : "▶"}
      </button>
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
