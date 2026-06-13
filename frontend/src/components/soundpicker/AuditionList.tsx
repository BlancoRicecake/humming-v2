import type { AuditionItem } from "../../types";
import { AuditionRow } from "./AuditionRow";

interface Props {
  items: AuditionItem[];
  selectedKeys: Set<string>;
  loadingKey: string | null;
  disabled: boolean;
  onPlay: (item: AuditionItem) => void;
  onToggle: (item: AuditionItem) => void;
}

// Group consecutive items by category, preserving the backend ordering.
function groupByCategory(items: AuditionItem[]): { category: string; items: AuditionItem[] }[] {
  const groups: { category: string; items: AuditionItem[] }[] = [];
  for (const it of items) {
    let g = groups[groups.length - 1];
    if (!g || g.category !== it.category) {
      g = { category: it.category, items: [] };
      groups.push(g);
    }
    g.items.push(it);
  }
  return groups;
}

export function AuditionList({ items, selectedKeys, loadingKey, disabled, onPlay, onToggle }: Props) {
  const groups = groupByCategory(items);
  return (
    <div className="sp-list">
      {groups.map((g) => (
        <div className="panel sp-group" key={g.category}>
          <div className="sp-group-head">{g.category}</div>
          <div className="sp-rows">
            {g.items.map((it) => (
              <AuditionRow
                key={it.key}
                item={it}
                selected={selectedKeys.has(it.key)}
                loading={loadingKey === it.key}
                disabled={disabled}
                onPlay={onPlay}
                onToggle={onToggle}
              />
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}
