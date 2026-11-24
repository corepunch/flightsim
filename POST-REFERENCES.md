# Post-processing and look references

What the frame does after the scene is drawn (`Sources/Render/Post.m`,
`Resources/Shaders/Post.metal`), on landscapes and in space, the standing trees it is drawn with
(`Resources/Shaders/Terrain.metal`, "Trees"), and what Project Aces published about
the Ace Combat look the two are measured against. The target is Ace Combat 5's
pastel, hazy frame and Ace Combat 7's sky light that bleeds into everything.

## What the current code does

| Piece | What it is | Where it comes from |
|---|---|---|
| Bloom | The display-ready frame's light above a knee, blurred at a quarter (glow) and a sixteenth (veil) of the drawable and added back | The PlayStation 2 glare recipe (Kawase; Gotanda and Shoji below): a reduced buffer, a threshold, a few Gaussians, added back. Unreal's bloom in AC7 is the same sum of Gaussians at 1/2 to 1/32 resolution |
| Colour filter | In a perceptual domain: blacks lifted toward the haze, saturation eased, highlights warmed and shadows cooled, contrast flattened, a vignette, a trace of lateral colour | AC7's per-mission colour filter, vignette and `SceneColorFringe` (confirmed by the mods that remove them); AC5's "very pastel, muted" grade |
| Aerial perspective | Exponential height fog with a 900 m scale height that warms toward the sun (`aerial`, `TerrainCommon.metal`), applied to ground, trees and sky alike | trueSKY's haze in AC7: Mie scattering with a haze base of 0 km and a scale height of 0.3 km (clear) to 2 km (hazy), applied to every pixel including translucents |
| Trees | Conifer spires and broadleaf crowns on four slot rings; near trees ray cast inside a bipyramid proxy, far trees one triangle each | AC7's SpeedTree LOD chains ending in billboards, with HLOD clusters at distance; AC5's sparse sprite trees |

Tuning: `r_post`, `r_bloom`, `r_vignette` ([CONSOLE.md](CONSOLE.md)); the knee and
the filter's numbers are constants in `Post.metal` and `Post.m`.

## Space: bloom in high dynamic range

Space goes through the same technique with a half-float scene (`kHDR` in
`Post.metal`, `r_spaceBloom`).

| Piece | What it is | Where it comes from |
|---|---|---|
| Scene | Scene-linear light in `rgba16f`: lit hulls stay under 0.85, emitters are written above white (sun disc 40, brightest stars about 10, bolt cores 1.3 to 1.8, fire up to 6, the fireball's flipbook 1.7) | McCurdy: emissive has to sit far above lit surfaces for bloom to tell them apart |
| Bloom | What exceeds white by its strongest channel, blurred at a quarter (glow) and a sixteenth (veil), added back at `r_spaceBloom` | The same reduced-buffer Gaussians as the landscape; the strongest channel rather than luma so a saturated red bolt blooms as readily as white fire |
| Streak | The veil blurred sideways once more, tinted cool | Anamorphic streaks as a horizontal-only blur of the bloom buffer (KinoStreak) |
| Tone curve | Identity up to 0.8, each channel rolled off above | Per-channel curves whiten hot cores and leave a coloured rim; identity below the shoulder as in Khronos PBR Neutral, so hulls and the nebula keep their look |
| Stars | A star's colour survives into its bloom: the display curve runs on its strongest channel and the bright end is stretched back out above white | Star renderers map magnitude to radiance and let glare come from the bloom pyramid (Schneegans et al.) |

Measured on an M1 at 3200x1800 in missions 3 and 6, GPU time a frame from the Metal
HUD log (`MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1`), median of 1200 frames a run.
Runs drift by a millisecond or more with what else the machine is doing, so only
runs made back to back compare:

| Pipeline | GPU time | Metal memory |
|---|---|---|
| Straight to the drawable (`r_post 0`) | 7.5 to 9.6 ms | 181 MiB |
| SceneKit's HDR camera with its bloom | 10.6 to 12.0 ms | 258 to 265 MiB |
| SceneKit's HDR camera, bloom off | 10.0 ms | 226 MiB |
| This technique, half-float scene | 5.3 to 8.8 ms | 233 MiB |

In each of six back-to-back pairs the technique took less GPU time than drawing
straight to the drawable, by 0.5 to 2.7 ms; why SceneKit's direct path costs more on
this machine was not established. SceneKit's HDR camera took 2.4 ms more than the
direct path beside it. The technique's extra memory is the scene texture (8 bytes a
pixel) and four small blur targets: about 14 MiB at the phone's 1864x860. Not
measured on a phone.

Sources read for it:

- SceneKit: [SCNCamera](https://developer.apple.com/documentation/scenekit/scncamera)
  (`wantsHDR`, bloom threshold 1, intensity 0 and blur radius 4 by default; exposure
  adaptation on by default, which a mostly black frame does not want),
  [SCNTechnique](https://developer.apple.com/documentation/scenekit/scntechnique)
  (target formats are listed in `SCNTechnique.h`; `rgba16f` needs iOS 16 or macOS 13),
  [WWDC 2016 session 609](https://nonstrict.eu/wwdcindex/wwdc2016/609/) (the HDR camera
  renders "float per component"; effects add up in cost).
- Bloom: Jimenez, *Next Generation Post Processing in Call of Duty: Advanced Warfare*,
  SIGGRAPH 2014 ([post](https://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare/));
  [LearnOpenGL, Physically Based Bloom](https://learnopengl.com/Guest-Articles/2022/Phys.-Based-Bloom)
  (no threshold, a 13-tap downsample and 3x3 tent upsample pyramid, bloom mixed in at
  about 0.04, Karis average on the first downsample against fireflies);
  Bjørge, *Bandwidth-Efficient Rendering*, SIGGRAPH 2015
  ([notes](https://community.arm.com/cfs-file/__key/communityserver-blogs-components-weblogfiles/00-00-00-20-66/siggraph2015_2D00_mmg_2D00_marius_2D00_notes.pdf):
  the dual filter, 5 taps down and 8 up, and why render target switches hurt tilers);
  [Karis on tone mapping and averaging](http://graphicrants.blogspot.com/2013/12/tone-mapping.html);
  [McCurdy, Emission and bloom](https://www.donmccurdy.com/2024/04/27/emission-and-bloom/).
- Flares without a depth read: Chapman, *Screen Space Lens Flare*
  ([2017](https://john-chapman.github.io/2017/11/05/pseudo-lens-flare.html)): ghosts and
  a halo made by reading the bloom buffer mirrored through the centre, so occlusion is
  automatic. Tried here and taken out: from a sixteenth-size veil the ghosts were
  coloured blobs. [KinoStreak](https://github.com/keijiro/KinoStreak) for the streak.
- Stars and backdrops: Schneegans et al., *Smaller than Pixels: Rendering Millions of
  Stars in Real-Time*, Eurographics 2025 ([paper](https://elib.dlr.de/215930/1/egs20251029.pdf):
  magnitude to luminance, splatting over 2x2 pixels against flicker, glare as a sum of
  Gaussians); [godot-starlight](https://github.com/tiffany352/godot-starlight);
  [Simon Schreibt on Homeworld 2's backgrounds](https://simonschreibt.de/gat/homeworld-2-backgrounds/)
  (a vertex-coloured sphere, as the nebula here).
- Tone curves: [Tone Mapping](https://64.github.io/tonemapping/) (Reinhard, Hable,
  ACES fits), [Khronos PBR Neutral](https://github.com/KhronosGroup/ToneMapping/blob/main/PBR_Neutral/README.md).

Not done, in order of promise: a pyramid bloom with the dual filter in place of the
two Gaussians; Chapman's ghosts from the quarter-size glow with a threshold only the
sun passes; stars splatted over 2x2 pixels.

## Ace Combat 7 (Project Aces, Unreal Engine 4.18, trueSKY)

Primary material:

- Masato Kanno, *Regarding Ace Combat 7's Revolution of the Sky*, CEDEC 2019.
  [English translation](https://www.skywardfm.com/cedec-2019-1) (PDF linked from the
  page), [CEDiL entry](https://cedil.cesa.or.jp/cedil_sessions/view/2023),
  [session abstract](https://cedec.cesa.or.jp/2019/session/detail/s5c9cb6579df11.html).
  The only published numbers. The sky is trueSKY's physically based Rayleigh and Mie
  scattering; Rayleigh is exposed but never touched, the whole look is tuned through
  Mie ("change the amount of dust in the atmosphere with only Haze/Fog and not touch
  Visibility"). Presets: clear = Haze/Fog 1, haze base 0 km, haze scale 0.3 km, Mie
  RGB (6.08, 8.14, 11.6); hazy = Haze/Fog 20, haze scale 2 km, Mie ×10; foggy =
  Haze/Fog 40, haze scale 2 km. The Mie ratio is always kept at 6.08 : 8.14 : 11.6
  (about 0.52 : 0.70 : 1.0, blue-heavy). Field 100 km, visual range 300 km, ceiling
  15 km, cloud tops about 10 km. Aerial perspective is applied to every translucent
  through a custom material modifier. Pass order: geometry, trueSKY (clouds marched at
  low resolution and composited against the full-resolution depth), translucents, post.
- Press reports of the talk, with details the slides leave out:
  [Famitsu](https://www.famitsu.com/news/201909/05182747.html) (haze and dust raised
  to change the look; more water vapour reads cooler; Mission 4's atmosphere matched
  to aerial photographs of Singapore haze),
  [GameBusiness](https://www.gamebusiness.jp/article/2019/11/06/16410.html) (Haze/Fog
  1 clear, 20 hazy, 40 foggy on the Fort Grace map; haze-scale changes add a yellow
  tint; cloud colour matched to the atmosphere colour at that distance),
  [AUTOMATON on the Unreal Fest West 2019 talk](https://automaton-media.com/devlog/report/20190910-101532/)
  ([programme](https://unrealengine.jp/unrealfest/west2019/),
  [video](https://www.youtube.com/watch?v=bmSYkp2JAyg)).
- [Ace Combat 7 Dev Insight: Revolution of the Sky and Clouds](https://www.youtube.com/watch?v=Jwk3Ze2Onzs)
  (TaskForce23's video summary),
  [Epic's interview with Kazutoki Kono](https://www.unrealengine.com/developer-interviews/ace-combat-7-soars-high-with-ue4-to-become-franchise-s-best-installment),
  Bandai Namco Studios' making-of [part 1](https://www.bandainamcostudios.com/en/behind-the-game/205)
  and [part 2](https://www.bandainamcostudios.com/en/behind-the-game/252),
  [Simul on trueSKY](https://80.lv/articles/truesky-making-skies-alive) (clouds
  marched into a low-resolution buffer, scattering tables, cloud shadows and ambient
  driven from the sky), trueSKY's
  [sky keyframe reference](https://docs.simul.co/4.3/Reference/Sky/skykeyframe.html).

What the shipped post stack contains, from the mods that switch its parts off:
[Color Filter Removal](https://www.nexusmods.com/acecombat7skiesunknown/mods/3252)
(a per-mission colour filter and vignette),
[No Vignette / No Color Filter / No Dirty Screen](https://www.nexusmods.com/acecombat7skiesunknown/mods/3102)
(vignette, filter, lens dirt, grain, depth of field),
[RenderToggler](https://www.nexusmods.com/acecombat7skiesunknown/mods/3351)
(vignette, depth of field, chromatic aberration, fog, grain, sharpening, lens flare,
bloom, motion blur, volumetric fog, auto exposure, sun flares),
[PCGamingWiki](https://www.pcgamingwiki.com/wiki/Ace_Combat_7:_Skies_Unknown)
(`r.SceneColorFringe` on by default; FXAA; no HDR output; tree pop-in cured by
`r.ViewDistanceScale`, `r.StaticMeshLODDistanceScale` and `r.Streaming.HLODStrategy`,
so distant forests are HLOD proxies and near ones SpeedTree LOD meshes). The
[Deep Dark Blue Skies ReShade preset](https://sfx.thelazy.net/games/preset/10649/)
describes the stock grade as yellowish. Vegetation middleware is SpeedTree
([wiki](https://acecombat.wiki.gg/wiki/Ace_Combat_7:_Skies_Unknown), secondary).

The Unreal 4.18 defaults behind the look:
[filmic tonemapper](https://dev.epicgames.com/documentation/en-us/unreal-engine/color-grading-and-the-filmic-tonemapper-in-unreal-engine)
(slope 0.88, toe 0.55, shoulder 0.26, black clip 0, white clip 0.04; colour
correction in scene-linear, LUTs after the tonemap),
[bloom](https://dev.epicgames.com/documentation/en-us/unreal-engine/bloom-in-unreal-engine)
(five Gaussians at 1/2 to 1/32 resolution, intensity 1, threshold 1),
[auto exposure](https://dev.epicgames.com/documentation/en-us/unreal-engine/auto-exposure-in-unreal-engine)
(histogram, 70–80 / 80–95 percentiles),
[atmospheric fog](https://dev.epicgames.com/documentation/unreal-engine/atmospheric-fog-user-guide?application_version=4.27)
(density height 0.35 ≈ 2.7 km, 0.5 ≈ 8 km).

Inference, not published: the "sky in the lens" feel is mostly Mie forward
scattering with a blue-weighted coefficient and a low scale height, so every pixel
below a few kilometres gets a bright, desaturating in-scatter term; the same term on
translucents; the filmic shoulder rolling the bright sky off with auto exposure
metered against it; and the wide, low-threshold blurs of the bloom sum. The colour
filter is a post-process volume per map.

## Ace Combat 6 (2007)

- [Game Watch interview](https://game.watch.impress.co.jp/docs/20070427/ace6.htm):
  the first in the series with tone mapping and simulated light adaptation (the flash
  on leaving cloud into sun); clouds and missile smoke share one method; a 100 km
  field. Its clouds were still billboard particles on a vertex-coloured dome (Kanno).

## Ace Combat 5 (2004, PlayStation 2) and the PS2 recipe

Nothing primary describes AC5's post pipeline or trees; this is what the hardware
and the emulator record show.

- [PCSX2 GameDB](https://github.com/PCSX2/pcsx2/blob/master/bin/resources/GameIndex.yaml):
  AC04 needs `halfPixelOffset` for "bloom misalignment" and `nativeScaling` to
  "smooth post-processing"; AC5 and Zero need `halfPixelOffset` for "ghosting in foggy
  maps" and blending fixes for dithering banding: a full-screen down- and up-sampled
  pass, a sprite sun, dithered 8-bit output.
  [Forum thread on the blur](https://forums.pcsx2.net/Thread-Ace-Combat-Zero-5-Blurry-effect-Help),
  [clouds and explosions as camera-facing sprites](https://github.com/PCSX2/pcsx2/issues/8876),
  [terrain as GS sprite strips](https://github.com/PCSX2/pcsx2/issues/10271).
- [Ace Combat 5 static recompilation](https://github.com/sal063/Ace-Combat-5-Static-recompilation):
  the VU1 transform and lighting microprograms rewritten natively; the place to read
  AC5's actual draw order.
- Gotanda, Shoji (tri-Ace), *Practical Implementation of SH Lighting and HDR Rendering
  on PlayStation 2* ([slides](https://www.slideserve.com/selah/practical-implementation-of-sh-lighting-and-hdr-rendering-on-playstation-2)):
  the canonical PS2 glare: 640×448 reduced to 128×128, a threshold, three Gaussians
  at 40/20/10 % of the radius, a persistence buffer, pseudo-HDR in fixed point.
  Kawase, *Frame Buffer Postprocessing Effects in DOUBLE-S.T.E.A.L*, GDC 2003
  ([Mynavi's series on it](https://news.mynavi.jp/article/graphics-50/)): the
  multi-Gaussian glare the tri-Ace deck builds on.
- Contemporary reviews: [AC04](https://game.watch.impress.co.jp/docs/20010914/ac04.htm)
  (satellite photo terrain with the studio's height data, seams at 200 m, "clear deep
  blue sky, hazy puffy clouds"), [AC5](https://game.watch.impress.co.jp/docs/20041020/ac5.htm),
  [25th anniversary interview](https://www.gamebusiness.jp/article/2020/08/20/17499_2.html)
  (satellite terrain from AC04 on; clouds "first became cloud-like in 04"),
  [retro review](https://gametyrant.com/news/ace-combat-5-14th-anniversary-retro-review)
  (missions add "some modelled buildings or trees"),
  [Bandai Namco's AC5 page](https://www.bandainamcoent.co.jp/cs/list/acecombat5/artwork/)
  (lens flare as a headline effect). Players describe AC5 as "very pastel... muted".

Inference: AC5's faded, warm, low-contrast frame is an 8-bit buffer, a reduced-buffer
glare added back (lifting blacks), vertex fog toward a pale sky colour, a sprite sun
with 2D flare sprites, and low-saturation satellite textures seen through that fog;
not a per-pixel LUT, which the PS2 could not afford. Its trees, where present, are
sparse sprites placed by the level.

## Not found

No CEDEC talk on AC7's terrain or foliage; no RenderDoc or Courrèges-style frame
breakdown of any Ace Combat; no developer material on AC5's post pipeline or trees;
the Gamefest/CEDEC AC6 "cloud rendering and HDR" talk could not be located.
