"""Isolated empty missions and deliberately distinct ship parameters; no art needed."""
import json
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
qa = pathlib.Path(sys.argv[1])
if len(sys.argv) == 2:
    for name in ('Ships', 'Projectiles', 'Strings'):
        shutil.copytree(root / 'Resources' / name, qa / name)
    missions = []
    for i, ship in enumerate(('executioner', 'wasp')):
        p = qa / 'Ships' / (ship + '.json')
        d = json.loads(p.read_text())
        d['params']['maxSpeed'] = 170 + 73 * i
        d['params']['turnRate'] = 0.7 + 0.6 * i
        d['gun'].update(speed=700 + 433*i, life=1.2 + 0.7*i, interval=0.12 + 0.09*i, energy=0.001, recharge=1)
        p.write_text(json.dumps(d))
        missions.append(dict(id=i+1, player=dict(ship=ship, pos=[0, 0, 0], facing=[0, 0, -1]),
                             loadout=dict(torpedoes=3), objectives=[dict(id='hold', type='survive', text='Hold position', seconds=10000)]))
    (qa / 'Missions').mkdir()
    (qa / 'Missions' / 'missions.json').write_text(json.dumps({'missions': missions}))
else:
    def identity():
        return subprocess.check_output([str(qa / 'NetworkChecks'), '--identity'], text=True).strip()
    baseline = identity()
    p = qa / 'Ships' / 'wasp.json'
    original = p.read_text()
    try:
        for section, key in (('params', 'maxSpeed'), ('gun', 'speed'), ('gun', 'interval')):
            d = json.loads(original)
            d[section][key] += 1
            p.write_text(json.dumps(d))
            assert identity() != baseline, (section, key)
        p.unlink()
        assert identity() != baseline, 'missing ship'
    finally:
        p.write_text(original)
    assert identity() == baseline
    print('PASS independent-process identities: movement, weapon speed, cadence, missing ship, restored data')
