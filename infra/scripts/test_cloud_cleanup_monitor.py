import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import check_cloud_cleanup as monitor


class MonitorTransportTest(unittest.TestCase):
    def process(self, report, code=0):
        return SimpleNamespace(stdout='Connecting...\n'+json.dumps(report)+'\n', stderr='private credential', returncode=code)

    def test_healthy_only_executes_readonly_monitor(self):
        with patch.object(monitor.subprocess,'run',return_value=self.process({'healthy':True,'alerts':[],'private':'hidden'})) as run:
            self.assertEqual(monitor.check(),{'healthy':True,'alerts':[]})
            command=run.call_args.args[0]
            self.assertEqual(command[-1],'python -m app.cloud_monitor')
            self.assertNotIn('--apply',command)

    def test_unhealthy_allowed_alert_is_preserved(self):
        with patch.object(monitor.subprocess,'run',return_value=self.process({'healthy':False,'alerts':['scheduled_worker_stale']},1)):
            self.assertEqual(monitor.check()['alerts'],['scheduled_worker_stale'])

    def test_malformed_or_unknown_alerts_do_not_leak_raw_text(self):
        for report in [{'healthy':True,'alerts':['private credential']},{'healthy':True,'alerts':['worker_pass_failed']},
                       {'healthy':'true','alerts':[]},{'healthy':False,'alerts':[]}]:
            with self.subTest(report=report),patch.object(monitor.subprocess,'run',return_value=self.process(report)):
                self.assertEqual(monitor.check(),{'healthy':False,'alerts':['cloud_cleanup_health_unavailable']})

    def test_transport_failure_and_contradictory_exit_fail_closed(self):
        with patch.object(monitor.subprocess,'run',side_effect=RuntimeError('private credential')):
            self.assertEqual(monitor.check()['alerts'],['cloud_cleanup_health_unavailable'])
        with patch.object(monitor.subprocess,'run',return_value=self.process({'healthy':True,'alerts':[]},1)):
            self.assertFalse(monitor.check()['healthy'])


if __name__=='__main__':unittest.main()
