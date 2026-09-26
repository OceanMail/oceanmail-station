#!/usr/bin/env python3
"""Exercise the production lifecycle parser, including the CI-observed duplicate."""
from pathlib import Path
import subprocess
import unittest
import os
import tempfile

PARSER=Path(__file__).with_name('phase4i-hermes-boundary.awk')
D='TNC: DISCONNECTED\n'
C='Connection cleanup complete.\n'
I='DISCONNECTED with no link up, ignoring.\n'
N='TNC: CONNECTED TESTA TESTB 2300\n'

class Boundary(unittest.TestCase):
    def check(self, log, expected, ready):
        result=subprocess.run(['awk','-f',str(PARSER)],input=log,text=True,capture_output=True,check=True)
        self.assertEqual(result.stdout.strip(), expected)
        latest,disc,clean,ignored=result.stdout.split()
        self.assertEqual(latest=='clean' and int(clean)>=int(disc),ready)

    def test_no_evidence(self):self.check('', 'none 0 0 0',False)
    def test_incomplete_disconnect(self):self.check(D, 'disconnect 1 0 0',False)
    def test_retired(self):self.check(D+C, 'clean 1 1 0',True)
    def test_observed_local_ack_then_idle_duplicate(self):
        self.check(N+D+'Disconnect completed.\n'+C+'BUFFER: 0\n'+D+I,'clean 1 1 1',True)
    def test_duplicate_without_prior_cleanup(self):self.check(D+I,'none 0 0 1',False)
    def test_real_later_disconnect(self):self.check(D+C+D,'disconnect 2 1 0',False)
    def test_two_real_disconnects_need_two_cleanups(self):self.check(D+D+C,'clean 2 1 0',False)
    def test_ignored_duplicate_cannot_cancel_prior_pending_retirement(self):
        self.check(D+C+D+D+I,'disconnect 2 1 1',False)
    def test_new_connection_invalidates_old_cleanup(self):self.check(D+C+N,'connected 1 1 0',False)
    def test_bare_ignore_cannot_grant_readiness(self):self.check(D+C+I,'invalid 1 1 0',False)
    def test_partial_duplicate_record_fails_closed(self):self.check(D+C+D,'disconnect 2 1 0',False)

    def run_full_gate(self, busy, expected):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'log').write_text(N+D+C+D+I)
            docker=root/'docker'
            docker.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
args=sys.argv[1:]
assert args.pop(0)=='exec'
if args[0]=='-i':args.pop(0)
args.pop(0) # fixture station name
if args[0]=='ps':
    print('S uuport' if os.environ['BUSY']=='1' else 'Z uuport')
else:
    args=[os.environ['FIXTURE'] if x=='/evidence/uucpd.log' else x for x in args]
    sys.exit(subprocess.call(args))
''')
            docker.chmod(0o755)
            env=dict(os.environ,PATH=str(root)+os.pathsep+os.environ['PATH'],
                     FIXTURE=str(root/'log'),BUSY=str(busy))
            result=subprocess.run(['bash',str(PARSER.with_name('phase4i-wait-hermes-clean.sh')),
                                   'a','b','1','0.01'],env=env,capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,expected,result.stdout+result.stderr)

    def test_live_bridge_still_blocks_full_gate(self):self.run_full_gate(1,1)
    def test_inert_zombie_does_not_block_retired_gate(self):self.run_full_gate(0,0)

if __name__=='__main__':unittest.main()
