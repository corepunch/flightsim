# Terrain rendering references

Sources behind the procedural terrain in `Sources/Render/Terrain.m` and
`Resources/Shaders/Terrain*.metal`, and what shipped flight and air-combat games
have published about their own terrain. The code today follows the first
section; the second is what it should be measured against.

## What the current code is built on

| Reference | What it gives us |
|---|---|
| Losasso, Hoppe — *Geometry Clipmaps: Terrain Rendering Using Nested Regular Grids*, SIGGRAPH 2004. [hhoppe.com/proj/geomclipmap](https://hhoppe.com/proj/geomclipmap/) | Nested rings of one grid following the camera; the ring layout in `Terrain.m`. |
| Asirvatham, Hoppe — *Terrain Rendering Using GPU-Based Geometry Clipmaps*, GPU Gems 2 ch. 2, 2005. [developer.nvidia.com](https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-2-terrain-rendering-using-gpu-based-geometry), [PDF](https://hhoppe.com/gpugcm.pdf), [GDC 2005 slides](https://download.nvidia.com/developer/presentations/2005/GDC/Sponsored_Day/GPUTerrain.pdf), [sample code](https://github.com/QianMo/GPU-Gems-Book-Source-Code/tree/master/GPU-Gems-2-CD-Content/Geometric_Complexity/Ch_02_Terrain_Rendering_using_GPU-Based_Geometry_Clipmaps) | Vertex-shader displacement, the "finest ring ≈ half the camera height" rule. |
| Strugar — *Continuous Distance-Dependent Level of Detail for Rendering Heightmaps (CDLOD)*, 2010. [github.com/fstrugar/CDLOD](https://github.com/fstrugar/CDLOD) | The edge morph that removes seams and T-junctions between rings; the height morphs between map levels with it. |
| Tanner, Migdal, Jones — *The Clipmap: A Virtual Mipmap*, SIGGRAPH 1998. [PDF](https://dl.acm.org/doi/pdf/10.1145/280814.280855) | The ground maps: nested windows of a lit ground image and a height map, one per power-of-two spacing, held as tori that scroll with the camera; `groundBake` fills in the texels that come into view. The procedural surface runs once per texel, not per pixel per frame. |

## What flight and air-combat games published

### War Thunder — Gaijin, Dagor Engine

- [Dagor Engine 5.0: New landscape creation technology](https://warthunder.com/en/news/5341-development-dagor-engine-5-0-new-landscape-creation-technology-en/) (2018). Heightmap plus per-material albedo, normal, roughness, AO and a ground-type map (grass, sand, dirt); displacement for ruts and puddles; works at every quality level including ultra-low.
- [Dagor Engine 5.0: Displacement mapping, mud and puddles](https://warthunder.com/en/news/5310-development-dagor-engine-5-0-displacement-mapping-mud-and-puddles-en).
- [Dagor Engine 5.0: Weather and environment: rain, fog, clouds and sun](https://warthunder.com/en/news/5318-in-development-dagor-engine-5-0-weather-and-environment-rain-fog-clouds-and-sun-en).
- [Dagor Engine 6.5: New surface rendering](https://warthunder.com/en/news/7585-development-dagor-engine-6-5-new-surface-rendering-en) (2022). Micro-shadows, reflectance and AO for ground materials, with before/after screenshots.
- [Dagor Engine documentation](https://gaijinentertainment.github.io/DagorEngine/index.html) — the engine is open source; landmesh, clipmap and shader code of a shipping air-combat game that also has a mobile client.

### Ace Combat 7 — Project Aces

- Masato Kanno, *Regarding Ace Combat 7's Revolution of the Sky*, CEDEC 2019. [English translation](https://www.skywardfm.com/post/cedec-2019-presentation-regarding-ace-combat-7-s-revolution-of-the-sky), [slides](https://www.skywardfm.com/cedec-2019-1). Unreal Engine 4 with trueSKY; authored terrain, the effort is in volumetric clouds.
- [Ace Combat 7 Dev Insight: Revolution of the Sky and Clouds](https://www.youtube.com/watch?v=Jwk3Ze2Onzs) (video).

### Microsoft Flight Simulator — Asobo

- Lionel Fuentes, *Designing the Terrain System of Flight Simulator: Representing the Earth*, GDC 2022. [GDC Vault](https://gdcvault.com/play/1027838/Advanced-Graphics-Summit-Designing-the), [slides PDF](https://media.gdcvault.com/GDC+2022/Speaker+Slides/Designing_Terrain_System_Fuentes_Lionel.pdf), [80.lv summary](https://80.lv/articles/gdc-designing-the-terrain-system-of-flight-simulator).

### Battlefield — DICE, Frostbite

- Johan Andersson, *Terrain Rendering in Frostbite Using Procedural Shader Splatting*, SIGGRAPH 2007. [PDF](https://media.contentapi.ea.com/content/dam/eacom/frostbite/files/chapter5-andersson-terrain-rendering-in-frostbite.pdf), [Frostbite page](https://careers.ea.com/frostbite/news/terrain-rendering-in-frostbite-using-procedural-shader-splatting). Closest to our approach — material decided in the shader — but driven by painted masks, heightmap slope and height, with procedural noise only breaking up tiling.

### IL-2 Sturmovik: Great Battles — 1C Game Studios

- [Developer diary index](https://forum.il2sturmovik.com/topic/168-developer-diary/), [Dev blog #332](https://il2sturmovik.com/news/765/dev-blog-332/) and later entries cover map and landscape work.

### Tiny Combat Arena — Why485

- [Devlog](https://why485.itch.io/tiny-combat-arena/devlog) — indie air-combat game; stylised terrain, written up by its single developer.

### Related terrain talks (not flight games)

- *Ghost Recon Wildlands: Terrain Tools and Technology*, GDC 2017. [GDC Vault](https://gdcvault.com/play/1024029/-Ghost-Recon-Wildlands-Terrain).
- *Terrain Rendering in Far Cry 5*, GDC 2018. [GDC Vault](https://www.gdcvault.com/play/1025480/Terrain-Rendering-in-Far-Cry).

## Reverse engineering

- Adrian Courrèges, [Graphics studies compilation](https://www.adriancourreges.com/blog/2020/12/29/graphics-studies-compilation/) — index of frame breakdowns of shipped games. No published frame analysis of an air-combat title was found.
- [RenderDoc](https://renderdoc.org/) — the tool those studies use; capture a frame of any of the above on PC to see draw order, terrain draws and texture inputs.

## The common pattern

Every shipped title above renders an **authored or measured heightmap** with a
**material/type map** and **tiled detail textures**, and uses procedural noise only
as a modifier: splat blending, micro-detail, displacement. `TerrainCommon.metal`
still computes landform, erosion, parcels, roads, forest and albedo from noise alone,
but into the clipmap's ground maps as they scroll, so a frame samples textures as
those games do; the finest map is a metre per texel, coarser ones blur with distance
where a tiled detail texture would keep them sharp.
