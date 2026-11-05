"""Read the deployed operator CLI via Fly SSH. Never run or modify cleanup work."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
ALERTS = frozenset({'scheduled_worker_missing', 'scheduled_worker_stale', 'worker_pass_failed',
                   'delete_queue_old', 'account_scans_overdue', 'auth_deletion_overdue',
                   'primary_purge_overdue', 'cloud_cleanup_health_unavailable'})


def check(flyctl='flyctl', app='humming-api'):
    try:
        process = subprocess.run([flyctl, 'ssh', 'console', '-a', app, '--pty=false',
                                  '-C', 'python -m app.cloud_monitor'],
                                 capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=75)
        raw = next(line for line in reversed(process.stdout.splitlines()) if line.startswith('{'))
        report = json.loads(raw)
        alerts = report.get('alerts')
        if (not isinstance(report.get('healthy'), bool) or not isinstance(alerts, list)
                or any(not isinstance(a, str) or a not in ALERTS for a in alerts)
                or report['healthy'] != (not alerts) or (report['healthy'] and process.returncode != 0)):
            raise ValueError('Invalid aggregate monitor result')
        return {'healthy': report['healthy'], 'alerts': alerts}
    except Exception:
        # SSH stderr/raw JSON may contain provider/connection details. Never forward it.
        return {'healthy': False, 'alerts': ['cloud_cleanup_health_unavailable']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flyctl', default='flyctl')
    parser.add_argument('--app', default='humming-api')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.output and not args.output.resolve().is_relative_to(ROOT / 'artifacts'):
        parser.error('Evidence must stay inside workspace artifacts')
    report = check(args.flyctl, args.app)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report))
    raise SystemExit(0 if report['healthy'] else 1)


if __name__ == '__main__':
    main()
