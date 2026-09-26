#!/usr/bin/env python3
"""Same behavioral probes against exact upstream trees; never patch test subjects
to make their interfaces compile. Patch-specific probes run separately.
"""
import argparse
import io
import json
from pathlib import Path
import subprocess
import tarfile

from test_ipc import semaphore_env
import os
import hashlib
import re

HISTORICAL = '5c76adff754de49c0b934c7fd7bddf7619b0c3d6'
CURRENT = '0fee4a53f54074ad6237b9fa1083a272cac89f60'
p = argparse.ArgumentParser()
p.add_argument('--source', type=Path, required=True, help='upstream Git clone')
p.add_argument('--out', type=Path, required=True, help='fresh results directory')
a = p.parse_args()
here = Path(__file__).resolve().parent
patch_path = here.parent.parent/'lab/phase1/hermes-vara-discard-stale-data.patch'
notice = patch_path.with_name('HERMES_PATCH_NOTICE.md').read_text()
assert hashlib.sha256(patch_path.read_bytes()).hexdigest() == re.search(r'SHA-256: `([0-9a-f]{64})`', notice)[1]
manifest = subprocess.check_output(['git','apply','--numstat',str(patch_path)],text=True)
assert {line.split('\t')[2] for line in manifest.splitlines()} == {
    'uucpd/'+name for name in ('call_uucico.c','net.c','shm.c','shm.h','uucpd.c','uucpd.h','uuport.c','vara.c')
}
assert all(line.split('\t')[0].isdigit() for line in manifest.splitlines())
a.out.mkdir(parents=True, exist_ok=False)
results = []
for label, sha, patch, variant in [
    ('historical', HISTORICAL, None, 0),
    ('historical-old-patch', HISTORICAL, here/'fixtures/historical-stale-tail.patch', 1),
    ('current-unmodified', CURRENT, None, 0),
    ('current-patched', CURRENT, here.parent.parent/'lab/phase1/hermes-vara-discard-stale-data.patch', 2),
]:
    root = (a.out/label).resolve(); root.mkdir()
    actual = subprocess.check_output(['git', '-C', str(a.source), 'rev-parse', sha+'^{commit}'], text=True).strip()
    assert actual == sha
    data = subprocess.check_output(['git', '-C', str(a.source), 'archive', sha])
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        archive.extractall(root, filter='data')
    if patch:
        subprocess.run(['git', '-C', str(root), 'apply', '--check', str(patch)], check=True)
        subprocess.run(['git', '-C', str(root), 'apply', str(patch)], check=True)
    common = ['gcc','-O2','-g','-Wall','-ffunction-sections','-fdata-sections','-no-pie',
              f'-I{root}/uucpd',f'-I{root}/include','-pthread','-Wl,--gc-sections']
    if variant == 2: common += ['-DTEST_BRIDGE_SEMAPHORE']
    def source(n): return str(root/'uucpd'/n)
    groups = [
        ('workers', ['active-greeting','binary-transfer','tx-retained-generation','cleanup-normal','reconnect-inflight'],
         [f'-DVARIANT={variant}',f'-DVARA_SOURCE="{source("vara.c")}"',str(here/'session_test.c'),
          source('net.c'),source('circular_buffer.c'),source('shm.c')]),
        ('net', ['net-reset','net-eintr','net-ebadf'],
         [f'-DNET_SOURCE="{source("net.c")}"',str(here/'net_test.c')]),
        ('bridge', ['bridge-delayed-exit'],
         [f'-DVARA_SOURCE="{source("vara.c")}"',f'-DUUPORT_SOURCE="{source("uuport.c")}"',
          str(here/'bridge_test.c'),str(here/'uuport_process.c'),source('net.c'),source('circular_buffer.c'),source('shm.c')]),
    ]
    for group, cases, inputs in groups:
        binary = root/(group+'-tests')
        cmd = common+inputs+['-o',str(binary)]
        built = subprocess.run(cmd,capture_output=True,text=True)
        (a.out/f'{label}-{group}-build.log').write_text(built.stdout+built.stderr)
        built.check_returncode()
        for case in cases:
            args = [] if group == 'bridge' else [case]
            with semaphore_env(os.environ) as env:
                run = subprocess.run([str(binary),*args],capture_output=True,text=True,env=env,timeout=20)
            expected = 0 if variant == 2 or case in ('active-greeting','binary-transfer') or (variant == 1 and case == 'cleanup-normal') else 1
            row = dict(variant=label,sha=sha,case=case,exit=run.returncode,expected=expected,stdout=run.stdout,stderr=run.stderr)
            results.append(row)
            (a.out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
            print(label,case,run.returncode,'expected',expected,flush=True)
            # A compile error, signal, timeout or changed behavior is NOT an
            # expected defect. Reassess upstream/patch removal when this changes.
            assert run.returncode == expected, row
