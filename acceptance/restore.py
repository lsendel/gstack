#!/usr/bin/env python3
"""Verify every sealed payload byte and restore only its pinned source tree."""
import hashlib,json,pathlib,subprocess,sys
payload=pathlib.Path(__file__).resolve().parent
manifest=json.loads((payload/'manifest.json').read_text())
for name,expected in manifest['payload'].items():
    data=(payload/name).read_bytes()
    assert len(data)==expected['bytes'] and hashlib.sha256(data).hexdigest()==expected['sha256'], name
repo=pathlib.Path(sys.argv[1]).resolve()
assert not repo.exists(), 'Refuse to overwrite an existing checkout'
subprocess.run(['git','init',str(repo)],check=True)
(repo/'.git/shallow').write_bytes((payload/'shallow').read_bytes())
def git(*args):
    return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()
heads=git('bundle','unbundle',str(payload/'source.bundle')).splitlines()
assert set(heads)=={manifest['source']+' HEAD',manifest['source']+' refs/heads/fix/pregate-literal-context',manifest['base']+' refs/heads/main'}
git('update-ref','refs/heads/main',manifest['base'])
git('update-ref','refs/remotes/origin/main',manifest['base'])
git('checkout','--detach',manifest['source'])
assert git('rev-parse','HEAD')==manifest['source']
assert git('rev-parse','HEAD^{tree}')==manifest['tree']
assert git('status','--porcelain')==''
assert git('rev-list','--count',manifest['base']+'..HEAD')=='2'
diff=subprocess.check_output(['git','-C',str(repo),'diff','--no-ext-diff','--no-textconv','--no-renames','--binary','--full-index',manifest['base'],manifest['source']])
assert hashlib.sha256(diff).hexdigest()==manifest['repairDiffSha256']
print(json.dumps({'source':manifest['source'],'tree':manifest['tree'],'payload_verified':True},sort_keys=True))
