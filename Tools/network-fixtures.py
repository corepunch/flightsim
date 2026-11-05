"""Isolated empty missions and deliberately distinct ship parameters; no art needed."""
import json
import pathlib
import shutil
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[1]
qa = pathlib.Path(sys.argv[1])
if len(sys.argv) == 2:
    # A one-game bundle: Games/NetCheck with only ship and projectile data and two levels.
    game = qa / 'Games' / 'NetCheck'
    for name in ('Ships', 'Projectiles'):
        shutil.copytree(root / 'Games' / 'KestrelFrontier' / 'Data' / name, game / 'Data' / name)
    shutil.copytree(root / 'Resources' / 'Strings', qa / 'Strings')
    missions = []
    for i, ship in enumerate(('executioner', 'wasp')):
        p = game / 'Data' / 'Ships' / (ship + '.json')
        d = json.loads(p.read_text())
        d['params']['maxSpeed'] = 170 + 73 * i
        d['params']['turnRate'] = 0.7 + 0.6 * i
        d['gun'].update(speed=700 + 433*i, life=1.2 + 0.7*i, interval=0.12 + 0.09*i, energy=0.001, recharge=1)
        p.write_text(json.dumps(d))
        missions.append(dict(name=f'check-{i+1}', seed=i+1, player=dict(ship=ship, pos=[0, 0, 0], facing=[0, 0, -1]),
                             loadout=dict(torpedoes=3), objectives=[dict(id='hold', type='survive', text='Hold position', seconds=10000)]))
    # Aim assist: a drone that cannot move, turn or hurt anyone, 600 m ahead and
    # 1.5 degrees off the nose (16 m to the side, far outside its hit radius).
    p = game / 'Data' / 'Ships' / 'drone.json'
    d = json.loads((game / 'Data' / 'Ships' / 'wasp.json').read_text())
    d['ai'] = dict(maxSpeed=0.01, turnRate=0, grip=60, boostGrip=60)   # spawns at 100 m/s; stop within 2 m
    d['aiGun'] = dict(damage=0, capitalDamage=0)
    d['hull'] = 100   # outlasts every shot, so each one that lands counts
    p.write_text(json.dumps(d))
    missions.append(dict(name='check-aim', seed=3, player=dict(ship='executioner', pos=[0, 0, 0], facing=[0, 0, -1]),
                         waves=[dict(id='drone', ship='drone', count=1, team='enemy', pos=[16, 0, -600], spread=0)],
                         objectives=[dict(id='hold', type='survive', text='Hold position', seconds=10000)]))
    # Ion fire: the player flies an ion variant of the executioner at a drone that
    # states a shield, systems and a sturdy hull of its own.
    p = game / 'Data' / 'Ships' / 'ionexec.json'
    d = json.loads((game / 'Data' / 'Ships' / 'executioner.json').read_text())
    d['gun']['ion'] = True
    d['gun']['damage'] = 0.1
    p.write_text(json.dumps(d))
    p = game / 'Data' / 'Ships' / 'dummy.json'
    d = json.loads((game / 'Data' / 'Ships' / 'drone.json').read_text())
    d.update(hull=3, shield=0.5, shieldRegen=0, systems=0.5)
    p.write_text(json.dumps(d))
    missions.append(dict(name='check-ion', seed=4, player=dict(ship='ionexec', pos=[0, 0, 0], facing=[0, 0, -1]),
                         waves=[dict(id='dummy', ship='dummy', count=1, team='enemy', pos=[16, 0, -600], spread=0)],
                         objectives=[dict(id='hold', type='survive', text='Hold position', seconds=10000)]))
    (game / 'Levels').mkdir()
    for mission in missions:
        (game / 'Levels' / (mission['name'] + '.json')).write_text(json.dumps(mission))
else:
    def identity():
        return subprocess.check_output([str(qa / 'NetworkChecks'), '--identity'], text=True).strip()
    baseline = identity()
    p = qa / 'Games' / 'NetCheck' / 'Data' / 'Ships' / 'wasp.json'
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
