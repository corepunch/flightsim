"""Original compact placeholder piston-engine, gun and music sounds; no sampled recordings."""
from pathlib import Path
import array,math,random,wave
ROOT=Path(__file__).resolve().parents[1]/'Audio'
RATE=22050
rng=random.Random(1918)
def write(name,seconds,sample):
    values=array.array('h',(int(max(-1,min(1,sample(i/RATE)))*28000) for i in range(round(seconds*RATE))))
    with wave.open(str(ROOT/(name+'.wav')),'wb') as out:
        out.setnchannels(1);out.setsampwidth(2);out.setframerate(RATE);out.writeframes(values.tobytes())
# Integer cycles make the engine bed loop cleanly at two seconds.
write('engine',2,lambda t:0.32*math.sin(math.tau*72*t)+0.14*math.sin(math.tau*144*t)+0.07*math.sin(math.tau*216*t)+0.06*math.sin(math.tau*36*t)*math.sin(math.tau*432*t))
write('laser',0.14,lambda t:(rng.uniform(-1,1)*0.75+math.sin(math.tau*(95*t+80*t*t))*0.25)*math.exp(-t*44))
write('impact',0.18,lambda t:rng.uniform(-1,1)*0.6*math.exp(-t*30))
write('explosion',1.1,lambda t:(rng.uniform(-1,1)*0.5+math.sin(math.tau*43*t)*0.35)*math.exp(-t*5))
# A restrained original sixteen-second four-chord instrumental bed.
chords=[(146.8324,174.6141,220),(130.8128,164.8138,195.9977),(116.5409,146.8324,174.6141),(130.8128,164.8138,220)]
def music(t):
    slot=min(3,int(t/4));u=t-slot*4;envelope=min(1,u/0.6,(4-u)/0.8)
    return envelope*sum(math.sin(math.tau*f*t)*0.035+math.sin(math.tau*f*2*t)*0.009 for f in chords[slot])
write('bastion-watch',16,music);write('lancer-flight',16,music)
