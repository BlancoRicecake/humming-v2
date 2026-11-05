"""Report unfinished mandatory release checks. Never publish or mutate a service."""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECKLIST = ROOT / 'docs/release/RELEASE-CHECKLIST-2026-10-31.md'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / 'artifacts'):
        raise ValueError('The report must stay in workspace artifacts')
    rows = re.findall(r'^- \[([ x])\] ([A-E]\d{2}) (.+)$', CHECKLIST.read_text(encoding='utf-8'), re.M)
    if not rows or len({r[1] for r in rows}) != len(rows):
        raise ValueError('Checklist missing or duplicate IDs')
    pending = [{'id': i, 'requirement': text} for mark, i, text in rows if mark != 'x']
    report = {'checklist': str(CHECKLIST), 'completed': len(rows) - len(pending),
              'total': len(rows), 'pending': pending, 'ready_for_release_review': not pending,
              'published': False}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'completed': report['completed'], 'total': report['total'],
                      'pending_ids': [r['id'] for r in pending],
                      'ready_for_release_review': not pending, 'published': False}))
    sys.exit(0 if not pending else 2)


if __name__ == '__main__': main()
