import json, pathlib, subprocess, tempfile, unittest
SCRIPT = pathlib.Path(__file__).parents[1] / 'src-tauri/src/wakeup_mcp.py'
class DurableWakeupTests(unittest.TestCase):
    def test_duplicate_request_survives_process_restart(self):
        with tempfile.TemporaryDirectory() as root:
            args = {'request_id':'same','delay_seconds':60,'prompt':'inspect build','reason':'CI'}
            command = ['python3', str(SCRIPT), root, 'test-mission', 'schedule_wakeup', json.dumps(args)]
            first = json.loads(subprocess.check_output(command))
            self.assertEqual(first['state'], 'pending_sync')
            second = json.loads(subprocess.check_output(command))
            self.assertEqual(second['state'], 'persisted')
            files = list(pathlib.Path(root).glob('*.json'))
            self.assertEqual(len(files), 1)
            payload = json.loads(files[0].read_text())
            self.assertEqual(payload['body']['variables']['__wakeup_request_id'], 'same')
            self.assertIn('__wakeup_due_at', payload['body']['variables'])
            files[0].rename(files[0].with_suffix('.acked'))
            subprocess.check_output(command)
            self.assertFalse(list(pathlib.Path(root).glob('*.json')))
    def test_mcp_receipt_is_honest_about_offline_state(self):
        with tempfile.TemporaryDirectory() as root:
            request={'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'schedule_wakeup','arguments':{'prompt':'continue','reason':'wait','delay_seconds':120}}}
            response=json.loads(subprocess.check_output(['python3',str(SCRIPT),root,'mission'],input=json.dumps(request)+'\n',text=True))
            receipt=json.loads(response['result']['content'][0]['text'])
            self.assertEqual(receipt['state'],'pending_sync')
            self.assertEqual(receipt['owner'],'sandboxed')
    def test_cancellation_tombstone_prevents_recreation(self):
        with tempfile.TemporaryDirectory() as root:
            args={'request_id':'cancelled','delay_seconds':60,'prompt':'continue','reason':'CI'}
            command=['python3',str(SCRIPT),root,'mission','schedule_wakeup',json.dumps(args)]
            subprocess.check_output(command)
            path=next(pathlib.Path(root).glob('*.json'))
            path.rename(path.with_suffix('.cancelled'))
            self.assertEqual(json.loads(subprocess.check_output(command))['state'],'cancelled')
            self.assertFalse(list(pathlib.Path(root).glob('*.json')))
    def test_concurrent_retries_create_one_request(self):
        with tempfile.TemporaryDirectory() as root:
            args={'request_id':'concurrent','delay_seconds':60,'prompt':'continue','reason':'CI'}
            command=['python3',str(SCRIPT),root,'mission','schedule_wakeup',json.dumps(args)]
            processes=[subprocess.Popen(command,stdout=subprocess.PIPE) for _ in range(2)]
            for process in processes:
                process.communicate()
                self.assertEqual(process.returncode,0)
            self.assertEqual(len(list(pathlib.Path(root).glob('*.json'))),1)
    def test_invalid_request_does_not_create_schedule(self):
        with tempfile.TemporaryDirectory() as root:
            request={'id':2,'method':'tools/call','params':{'name':'schedule_wakeup','arguments':{'prompt':''}}}
            response=json.loads(subprocess.check_output(['python3',str(SCRIPT),root,'mission'],input=json.dumps(request)+'\n',text=True))
            self.assertTrue(response['result']['isError'])
            self.assertFalse(list(pathlib.Path(root).glob('*.json')))
if __name__ == '__main__': unittest.main()
