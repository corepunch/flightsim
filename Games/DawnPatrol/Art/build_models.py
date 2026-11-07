"""Run with Blender --background --factory-startup --disable-autoexec --python <this file>.

Exports only the chosen CC0 airframes and their assigned material colors.
The source archive stays intact; unrelated reference images are never exported.
"""
from pathlib import Path
import bpy,math,random,tempfile,zipfile
from mathutils import Vector
ROOT=Path(__file__).resolve().parents[1]

def color(material):
    if material and material.use_nodes:
        shader=next((n for n in material.node_tree.nodes if n.type=='BSDF_PRINCIPLED'),None)
        if shader:return tuple(shader.inputs['Base Color'].default_value[:3])
    return tuple(material.diffuse_color[:3]) if material else (0.4,0.4,0.4)

class Obj:
    def __init__(self,name):self.name=name;self.faces=[];self.colors={}
    def face(self,points,material,rgb):
        self.colors[material]=rgb
        for i in range(1,len(points)-1):self.faces.append(([Vector(p) for p in [points[0],points[i],points[i+1]]],material))
    def box(self,center,size,material,rgb):
        c=Vector(center);s=Vector(size)*0.5
        v=[c+Vector((x*s.x,y*s.y,z*s.z)) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
        for indices in [(0,3,2,1),(4,5,6,7),(0,1,5,4),(3,7,6,2),(0,4,7,3),(1,2,6,5)]:self.face([v[i] for i in indices],material,rgb)
    def save(self):
        path=ROOT/'Models'/self.name;lines=['mtllib '+self.name+'.mtl','o '+self.name];last=None
        for i,(points,material) in enumerate(self.faces):
            if material!=last:lines.append('usemtl '+material);last=material
            normal=(points[1]-points[0]).cross(points[2]-points[0]);normal.normalize()
            for p in points:lines.append('v %.5f %.5f %.5f'%tuple(p))
            lines.append('vn %.6f %.6f %.6f'%tuple(normal));lines.append('f '+' '.join(f'{i*3+j+1}//{i+1}' for j in range(3)))
        path.with_suffix('.obj').write_text('\n'.join(lines)+'\n')
        path.with_suffix('.mtl').write_text('\n'.join(f'newmtl {name}\nKd {r:.6f} {g:.6f} {b:.6f}\nKs 0.02 0.02 0.02\nNs 8\nd 1\nillum 2\n' for name,(r,g,b) in self.colors.items()))
        print(self.name,len(self.faces),'triangles')

with tempfile.TemporaryDirectory(prefix='dawn-patrol-') as temp:
    with zipfile.ZipFile(ROOT/'Art/Sources/ww1_planes_painted_2.blend.zip') as z:
        member='WW1_Planes_painted_2.blend';z.extract(member,temp)
    bpy.ops.wm.open_mainfile(filepath=str(Path(temp)/member),load_ui=False,use_scripts=False)
    for collection,body,output in [('SE5a','SE5a','SE5a'),('Fokker_D7','Fokker_D7','FokkerD7')]:
        obj=Obj(output);base=bpy.data.objects[body]
        center=sum((base.matrix_world@Vector(p) for p in base.bound_box),Vector())/8
        for mesh in bpy.data.collections[collection].all_objects:
            if mesh.type!='MESH' or mesh.name.startswith('prop_blur'):continue
            mesh.data.calc_loop_triangles()
            for triangle in mesh.data.loop_triangles:
                points=[]
                for index in triangle.vertices:
                    p=mesh.matrix_world@mesh.data.vertices[index].co-center
                    points.append((p.x,p.z,-p.y))
                material=mesh.material_slots[triangle.material_index].material if mesh.material_slots else None
                obj.face(points,material.name.replace(' ','_') if material else 'canvas',color(material))
        obj.save()

# The patrol's flat collision datum is y=0; everything above it is scenery.
land=Obj('PatrolLandscape');rng=random.Random(1918)
land.box((0,-3,0),(40000,6,40000),'earth',(0.22,0.30,0.14))
field_colors=[(0.25,0.34,0.14),(0.34,0.37,0.17),(0.31,0.27,0.16),(0.39,0.39,0.20),(0.19,0.28,0.12),(0.31,0.38,0.18)]
for ix in range(-13,14):
    for iz in range(-13,14):
        x=ix*600;z=iz*600;k=rng.randrange(len(field_colors))
        land.box((x,0.05,z),(588,0.1,588),'field'+str(k),field_colors[k])
        if rng.random()<0.4:land.box((x+297,1,z),(4,2,598),'hedge',(0.12,0.19,0.08))
# A winding waterway and its light banks.
for i in range(-24,25):
    z=i*180;x=520+math.sin(z/600)*160
    land.box((x,0.2,z),(85,0.1,210),'riverbank',(0.35,0.35,0.23))
    land.box((x,0.3,z),(55,0.1,210),'water',(0.18,0.32,0.34))
land.box((0,0.45,650),(90,0.2,650),'runway',(0.36,0.34,0.22))
for z in [430,650,870]:
    land.box((130,7,z),(60,14,40),'canvas',(0.42,0.40,0.27))
    land.box((99,5,z),(0.3,10,28),'hangardoor',(0.10,0.12,0.08))
land.box((-72,4,690),(8,8,8),'ops',(0.32,0.27,0.18))
# Villages and recognizable route landmarks.
for anchor in [(0,-250),(-600,-2100),(1100,-600),(-900,700)]:
    for j in range(14):
        x=anchor[0]+rng.uniform(-200,200);z=anchor[1]+rng.uniform(-180,180)
        land.box((x,4,z),(14,8,19),'plaster',(0.62,0.56,0.39))
        land.box((x,8.5,z),(16,1,21),'roofs',(0.29,0.18,0.12))
land.box((0,9,-250),(18,18,38),'church',(0.51,0.48,0.36))
land.box((0,23,-234),(10,30,10),'church',(0.51,0.48,0.36))
land.box((-600,11,-2100),(12,22,12),'mill',(0.43,0.35,0.22))
for i in range(700):
    x=rng.uniform(-6500,6500);z=rng.uniform(-6500,6500)
    if abs(x)<80 and 250<z<1100:continue
    h=rng.uniform(9,17);r=rng.uniform(4,7)
    land.box((x,2,z),(1.5,4,1.5),'bark',(0.20,0.15,0.09))
    tip=(x,h,z);base=[(x+r*math.cos(a*math.tau/6),3,z+r*math.sin(a*math.tau/6)) for a in range(6)]
    for a in range(6):land.face([base[a],tip,base[(a+1)%6]],'leaves',(0.16,0.24,0.10))
land.save()
