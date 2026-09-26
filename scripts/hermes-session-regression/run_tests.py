#!/usr/bin/env python3
"""Build actual HERMES sources and retain every regression result and log."""
import argparse
import collections
import json
import os
from pathlib import Path
import subprocess
import time
from test_ipc import semaphore_env

p=argparse.ArgumentParser()
p.add_argument('--replacement', type=Path, required=True)
p.add_argument('--tsan', action='store_true')
p.add_argument('--repeat', type=int, default=30)
a=p.parse_args()
here=Path(__file__).resolve().parent
src=a.replacement.resolve()
logs=here/'logs'; logs.mkdir(exist_ok=True)
worker_cases=['active-greeting','drain-small','drain-large','drain-empty','drain-eof',
 'drain-error','drain-eintr','cleanup-normal','cleanup-eintr','cleanup-error',
 'cleanup-eof','full-buffer-disconnect','reconnect-inflight','disconnect-during-read',
 'early-connect','connect-during-final-wait','receive-eintr','receive-eof','receive-error',
 'repeated-sessions','binary-transfer','cleanup-real-time','retirement-eintr-storm',
 'retirement-data-stream','idle-polling','tx-retained-generation','tx-partial-eintr',
 'tx-partial-eagain','control-reset-shutdown','incoming-busy',
 'duplicate-disconnected','local-disconnect-ack']
common=['gcc','-O2','-g','-Wall','-ffunction-sections','-fdata-sections','-no-pie',
 '-DTEST_BRIDGE_SEMAPHORE',f'-I{src}/uucpd',f'-I{src}/include','-pthread','-Wl,--gc-sections']
def source(name): return str(src/'uucpd'/name)
groups=[
 ('workers', ['-DVARIANT=2',f'-DVARA_SOURCE="{source("vara.c")}"',str(here/'session_test.c'),
               source('net.c'),source('circular_buffer.c'),source('shm.c')],[(x,[x]) for x in worker_cases],True),
 ('net',[f'-DNET_SOURCE="{source("net.c")}"',str(here/'net_test.c')],
        [(x,[x]) for x in ('net-reset','net-eintr','net-ebadf')],True),
 ('bridge',[f'-DVARA_SOURCE="{source("vara.c")}"',f'-DUUPORT_SOURCE="{source("uuport.c")}"',
             str(here/'bridge_test.c'),str(here/'uuport_process.c'),source('net.c'),
             source('circular_buffer.c'),source('shm.c')],[('bridge-delayed-exit',[]),('bridge-crash', ['crash'])],False),
 ('incoming',[f'-DUUCICO_SOURCE="{source("call_uucico.c")}"',str(here/'internal_bridge_test.c'),
               source('circular_buffer.c'),source('shm.c')],[('incoming-backpressure',[]),('incoming-preexec', ['preexec'])],False),
]
env=dict(os.environ,ASAN_OPTIONS='detect_leaks=0',UBSAN_OPTIONS='halt_on_error=1',TSAN_OPTIONS='halt_on_error=1')
results=[]; repeats={}; failed=False

def run(binary,case,args,label):
    start=time.monotonic()
    try:
        with semaphore_env(env) as test_env:
            r=subprocess.run([str(binary),*args],capture_output=True,text=True,env=test_env,timeout=18)
        out,err,code=r.stdout,r.stderr,r.returncode
    except subprocess.TimeoutExpired as e:
        out=e.stdout or b'';err=e.stderr or b''
        if isinstance(out,bytes):out=out.decode(errors='replace')
        if isinstance(err,bytes):err=err.decode(errors='replace')
        err+='\nTEST TIMEOUT\n';code=124
    row=dict(variant=label,case=case,exit=code,seconds=round(time.monotonic()-start,4),stdout=out,stderr=err)
    (logs/f'{label}-{case}.log').write_text(out+err)
    return row

for group,inputs,cases,supports_tsan in groups:
    for sanitizer in (None,'address,undefined')+(('thread',) if a.tsan and supports_tsan else ()):
        label='replacement'+('-tsan' if sanitizer=='thread' else '-asan' if sanitizer else '')
        binary=here/(group+'-'+label+'-tests')
        cmd=common+inputs+['-o',str(binary)]
        if sanitizer:cmd += [f'-fsanitize={sanitizer}','-fno-omit-frame-pointer']
        build=subprocess.run(cmd,capture_output=True,text=True)
        (logs/f'build-{group}-{label}.log').write_text(build.stdout+build.stderr)
        build.check_returncode()
        for case,args in cases:
            row=run(binary,case,args,label);results.append(row)
            failed |= row['exit']!=0
            print(label,case,row['exit'],flush=True)
            (here/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    for case,args in cases:
        if case in ('cleanup-real-time','idle-polling','control-reset-shutdown'):continue
        counts=collections.Counter()
        for iteration in range(a.repeat):
            row=run(here/(group+'-replacement-tests'),case,args,f'repeat-{iteration+1:02}')
            counts[str(row['exit'])]+=1;failed |= row['exit']!=0
        repeats[case]=dict(counts)
        print('REPEAT',case,dict(counts),flush=True)
        (here/'repeat-results.json').write_text(json.dumps(repeats,indent=2)+'\n')
# TSan does not establish cross-process synchronization. Fork/SHM lifecycle tests
# run normally and with ASan/UBSan; their assertions provide the process evidence.
raise SystemExit(1 if failed else 0)
