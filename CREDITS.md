# Credits

Space Fight uses the following third-party assets. All of them are released
under **CC0 1.0 Universal** (public domain): credit isn't required, but it is
given here gladly.

## 3D models

**Ultimate Spaceships Pack** by **Quaternius**
- https://quaternius.com/packs/ultimatespaceships.html
- Downloaded from OpenGameArt: https://opengameart.org/content/lowpoly-spaceships-pack
- License: CC0 1.0
- Used: `Executioner.obj` (player), `Spitfire.obj`, `Insurgent.obj` (enemies)
- Support the author: https://www.patreon.com/quaternius

**Colour-variant textures and exhaust placement reference** from the Godot port
of the same pack by **Malcolm Nixon**
- https://github.com/Malcolmnixon/Quaternius-Ultimate-Spaceships-Pack
- License: CC0 1.0
- Used: `Executioner_Blue.png`, `Spitfire_Red.png`, `Insurgent_Red.png`; nozzle
  positions cross-checked against its exhaust node transforms

## Particle textures

**Particle Pack** by **Kenney** (Kenney Vleugels, www.kenney.nl)
- https://kenney.nl/assets/particle-pack
- Downloaded from OpenGameArt: https://opengameart.org/content/particle-pack-80-sprites
- License: CC0 1.0 (filter templates credited by Kenney to Indigo Ray, Craig
  Nisbet, Zoltan Erdokovy, Heliagon, ThreeDee, Killst4r and Tim2501)
- Used (downscaled to 256 px, edge-masked at load): `fire_01` (engine plasma,
  damage fire), `smoke_07` (exhaust fumes, damage smoke), `star_06` (muzzle
  flash), `flare_01`, `light_01`, `circle_05` (lens flare)

## Techniques

The skybox, explosions (shader-driven fire spheres), shockwave ring and lens
streaks are procedural; they ship no image assets.
They build on these published techniques:
- Domain-warped fBm noise: Inigo Quilez, "Domain Warping",
  https://iquilezles.org/articles/warp/
- `pcg3d` hash: Mark Jarzynski & Marc Olano, "Hash Functions for GPU Rendering",
  JCGT vol. 9 no. 3 (2020), https://jcgt.org/published/0009/03/02/
- Quintic-interpolated gradient noise: Ken Perlin, "Improving Noise" (SIGGRAPH 2002)
