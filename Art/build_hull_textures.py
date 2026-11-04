# Generates tileable spaceship hull texture sets into Resources/Textures/:
#   <set>_color.png  albedo (neutral, tinted per faction in game)
#   <set>_normal.png OpenGL-convention normal map
#   <set>_rough.png  roughness
#   <set>_metal.png  metalness
#   <set>_emit.png   lit windows and running lights
#
#   Blender -b --factory-startup --python Art/build_hull_textures.py [-- set ...]
#
# With no set names it builds every set in SETS (bottom of the file). The
# game loads <set>_<map>.jpg or .png, so the large colour and roughness maps
# can be converted to JPEG afterwards to keep the repo small:
#   sips -s format jpeg -s formatOptions 90 x_color.png --out x_color.jpg
#
# Runs inside Blender for its bundled numpy. Everything is generated on a
# torus (FFT filters, wrapped rolls), so the sets tile seamlessly.

import bpy
import numpy as np
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources", "Textures")
N = 2048


def fft_noise(rng, scale, aniso=(1.0, 1.0)):
    """Tileable smooth noise in 0..1: white noise low-passed in frequency space."""
    w = rng.standard_normal((N, N))
    fy = np.fft.fftfreq(N)[:, None] * aniso[1]
    fx = np.fft.fftfreq(N)[None, :] * aniso[0]
    f = np.sqrt(fx * fx + fy * fy)
    spec = np.fft.fft2(w) * np.exp(-(f * scale) ** 2)
    n = np.real(np.fft.ifft2(spec))
    n = (n - n.min()) / (n.max() - n.min() + 1e-9)
    return n


def blur(a, radius):
    fy = np.fft.fftfreq(N)[:, None]
    fx = np.fft.fftfreq(N)[None, :]
    g = np.exp(-((fx * fx + fy * fy) * (radius * np.pi) ** 2 * 2))
    return np.real(np.fft.ifft2(np.fft.fft2(a) * g))


def split(rng, x, y, w, h, out, depth=0, big=False, min_area=56 * 56, min_side=40):
    """Recursive kd split into panels, snapped to an 8 px grid."""
    area = w * h
    stop = area < min_area or (depth > 3 and rng.random() < (0.22 if not big else 0.4) * (depth - 3))
    if stop or min(w, h) < min_side:
        out.append((x, y, w, h))
        return
    horizontal = w < h if rng.random() < 0.8 else rng.random() < 0.5
    if horizontal:
        s = int(h * rng.uniform(0.25, 0.75)) // 8 * 8
        if s < 24 or h - s < 24:
            out.append((x, y, w, h)); return
        split(rng, x, y, w, s, out, depth + 1, big, min_area, min_side)
        split(rng, x, y + s, w, h - s, out, depth + 1, big, min_area, min_side)
    else:
        s = int(w * rng.uniform(0.25, 0.75)) // 8 * 8
        if s < 24 or w - s < 24:
            out.append((x, y, w, h)); return
        split(rng, x, y, s, h, out, depth + 1, big, min_area, min_side)
        split(rng, x + s, y, w - s, h, out, depth + 1, big, min_area, min_side)


def edge_distance(w, h):
    yy, xx = np.mgrid[0:h, 0:w]
    return np.minimum(np.minimum(xx, w - 1 - xx), np.minimum(yy, h - 1 - yy)).astype(np.float32)


def generate(name, seed, detail=1.0, paint=0.3, windows=0.05, big=False, tones=(0.5, 0.9)):
    rng = np.random.default_rng(seed)
    H = np.zeros((N, N), np.float32)          # height
    A = np.zeros((N, N, 3), np.float32)       # albedo
    R = np.zeros((N, N), np.float32)          # roughness
    M = np.zeros((N, N), np.float32)          # metalness
    E = np.zeros((N, N, 3), np.float32)       # emission

    # Big structural plates first, each subdivided into panels.
    plates = []
    split(rng, 0, 0, N, N, plates, 0, True)
    panels = []
    for (x, y, w, h) in plates:
        if rng.random() < (0.25 if big else 0.1) and w * h > 160 * 160:
            panels.append((x, y, w, h, True))
        else:
            sub = []
            split(rng, x, y, w, h, sub, 1, big)
            panels += [(a, b, c, d, False) for (a, b, c, d) in sub]

    for (x, y, w, h, plate) in panels:
        sl = (slice(y, y + h), slice(x, x + w))
        tone = rng.uniform(*tones) if rng.random() > 0.14 else rng.uniform(0.22, 0.38)
        warm = rng.uniform(-0.025, 0.025)
        painted = rng.random() < paint
        col = np.array([tone + warm, tone, tone - warm], np.float32)
        if painted and rng.random() < 0.15:
            col = col * np.array([0.75, 0.8, 0.95])    # an odd blue-grey replacement panel
        d = edge_distance(w, h)
        lift = rng.choice([0.0, 0.25, 0.5, -0.25]) * (0.5 if plate else 1.0)
        bevel = np.clip(d / 5.0, 0, 1)
        H[sl] += bevel * (0.6 + lift)
        A[sl] = col
        R[sl] = (0.55 if painted else 0.32) + rng.uniform(-0.06, 0.06)
        M[sl] = (0.08 if painted else 0.75) + rng.uniform(-0.05, 0.05)
        # Seams: dark grooves around every panel.
        seam = d < 1.5
        H[sl][seam] -= 0.6
        A[sl][seam] *= 0.3

        if min(w, h) < 32:
            continue
        # Inset groove a few pixels inside many panels.
        if rng.random() < 0.35 and min(w, h) > 60:
            k = int(rng.integers(6, 12))
            inset = np.abs(d - k) < 1.0
            H[sl][inset] -= 0.35
            A[sl][inset] *= 0.55
        r = rng.random() * 0.82 / max(detail, 1e-3)
        ix, iy, iw, ih = x + 10, y + 10, w - 20, h - 20
        isl = (slice(iy, iy + ih), slice(ix, ix + iw))
        if r < 0.14:
            # Vent: parallel slats across the short side.
            yy, xx = np.mgrid[0:ih, 0:iw]
            vw, vh = int(iw * rng.uniform(0.4, 0.8)), int(ih * rng.uniform(0.3, 0.7))
            ox, oy = (iw - vw) // 2, (ih - vh) // 2
            inside = (xx >= ox) & (xx < ox + vw) & (yy >= oy) & (yy < oy + vh)
            along = xx if vw < vh else yy
            slat = (along % 7) < 3
            H[isl][inside] -= 0.35
            H[isl][inside & slat] -= 0.4
            A[isl][inside & slat] *= 0.35
            A[isl][inside & ~slat] *= 0.8
            R[isl][inside] = 0.6
        elif r < 0.30:
            # Rivet rows along the panel edges.
            yy, xx = np.mgrid[0:h, 0:w]
            dd = edge_distance(w, h)
            ring = (np.abs(dd - 6) < 0.8)
            dots = ring & ((xx + yy) % 14 < 3)
            H[sl][dots] += 0.5
            A[sl][dots] *= 1.15
        elif r < 0.36:
            # Round hatch with a groove and lighter centre.
            yy, xx = np.mgrid[0:ih, 0:iw]
            rad = min(iw, ih) * rng.uniform(0.25, 0.42)
            rr = np.sqrt((xx - iw / 2) ** 2 + (yy - ih / 2) ** 2)
            H[isl][np.abs(rr - rad) < 1.8] -= 0.6
            A[isl][np.abs(rr - rad) < 1.8] *= 0.4
            inner = rr < rad - 2
            H[isl][inner] += 0.25
            A[isl][inner] *= 1.08
            for k in range(4):
                a = k * np.pi / 2 + np.pi / 4
                cx, cy = iw / 2 + np.cos(a) * rad * 0.7, ih / 2 + np.sin(a) * rad * 0.7
                bolt = (xx - cx) ** 2 + (yy - cy) ** 2 < 6
                H[isl][bolt] += 0.4
        elif r < 0.52:
            # Raised equipment blocks.
            for _ in range(rng.integers(2, 6)):
                bw, bh = int(iw * rng.uniform(0.15, 0.45)), int(ih * rng.uniform(0.15, 0.45))
                if bw < 8 or bh < 8:
                    continue
                bx, by = rng.integers(0, iw - bw + 1), rng.integers(0, ih - bh + 1)
                bsl = (slice(iy + by, iy + by + bh), slice(ix + bx, ix + bx + bw))
                bd = edge_distance(bw, bh)
                H[bsl] += np.clip(bd / 3.0, 0, 1) * rng.uniform(0.4, 1.0)
                A[bsl] *= rng.uniform(0.6, 1.1)
                R[bsl] = rng.uniform(0.3, 0.6)
                A[bsl][bd < 1] *= 0.5
        elif r < 0.56 and w * h < 260 * 260:
            # Hazard stripes on a strip of the panel.
            yy, xx = np.mgrid[0:ih, 0:iw]
            sh = max(10, ih // 4)
            band = yy < sh
            stripe = ((xx + yy) // 10) % 2 == 0
            A[isl][band & stripe] = (0.85, 0.62, 0.12)
            A[isl][band & ~stripe] = (0.08, 0.08, 0.08)
            M[isl][band] = 0.05
            R[isl][band] = 0.6
        elif r < 0.64:
            # Markings: thin stripes and a little block of "text".
            yy, xx = np.mgrid[0:ih, 0:iw]
            c = (0.92, 0.92, 0.9) if rng.random() < 0.6 else (0.12, 0.12, 0.12)
            if rng.random() < 0.5:
                line = (np.abs(yy - ih * 0.2) < 2) & (xx < iw * 0.7)
                A[isl][line] = c
            else:
                for k in range(rng.integers(3, 7)):
                    tx = 4 + k * 9
                    if tx + 6 < iw:
                        A[isl][4:12, tx:tx + 6] = c
            M[isl][A[isl][..., 0] == c[0]] = 0.05
        elif r < 0.72:
            # Pipes running along the panel.
            yy, xx = np.mgrid[0:ih, 0:iw]
            along_x = iw > ih
            across = yy if along_x else xx
            span = ih if along_x else iw
            for k in range(rng.integers(1, 4)):
                c0 = span * rng.uniform(0.2, 0.8)
                pr = rng.uniform(3, 7)
                t = np.clip(1 - ((across - c0) / pr) ** 2, 0, 1)
                pipe = t > 0
                H[isl][pipe] = np.maximum(H[isl][pipe], np.sqrt(t[pipe]) * 1.2 + H[isl][pipe] * 0)
                A[isl][pipe] = (np.array([0.55, 0.55, 0.56]) * (0.7 + 0.5 * np.sqrt(t[pipe]))[:, None])
                M[isl][pipe] = 0.85
                R[isl][pipe] = 0.3
        elif r < 0.72 + windows:
            # A row of lit windows.
            rows = rng.integers(1, 3)
            for k in range(rows):
                wy = iy + int(ih * (0.3 + 0.35 * k))
                for wx in range(ix + 4, ix + iw - 10, 14):
                    if rng.random() < 0.25:
                        continue
                    wsl = (slice(wy, wy + 7), slice(wx, wx + 9))
                    A[wsl] = 0.05
                    H[wsl] -= 0.3
                    glow = rng.choice([(1.0, 0.82, 0.55), (0.75, 0.88, 1.0), (1.0, 0.95, 0.85)])
                    E[wsl] = np.array(glow) * rng.uniform(0.6, 1.0)
        elif r < 0.72 + windows + 0.03:
            # Running light.
            cy, cx = iy + ih // 2, ix + iw // 2
            E[cy - 2:cy + 3, cx - 2:cx + 3] = (1.0, 0.3, 0.2) if rng.random() < 0.5 else (0.4, 1.0, 0.5)
            H[cy - 3:cy + 4, cx - 3:cx + 4] += 0.3

    finish(name, rng, H, A, R, M, E)
    return len(panels)


def finish(name, rng, H, A, R, M, E, grime_amount=1.0, streak_amount=1.0):
    """Shared last pass for every set: weathering, cavity shading and edge
    wear from the height field, the normal map, and saving all five maps."""
    # Weathering: blotchy grime, vertical streaks, and wear on raised edges.
    grime = fft_noise(rng, 60)
    fine = fft_noise(rng, 6)
    streak = fft_noise(rng, 40, aniso=(0.4, 6.0))
    dirt = np.clip(1 - grime_amount * (0.38 - 0.4 * grime - 0.12 * (fine - 0.5))
                   - streak_amount * 0.5 * np.clip(streak - 0.55, 0, 1), 0.35, 1.1)
    A *= dirt[..., None]
    R += grime_amount * (0.18 * (1 - grime) + 0.08 * (fine - 0.5))
    # Cavity occlusion from the height field.
    cav = blur(H, 3) - H
    ao = np.clip(1 - cav * 0.9, 0.35, 1.0)
    A *= ao[..., None]
    edge = np.clip((H - blur(H, 2)) * 1.5, 0, 1)
    A += edge[..., None] * 0.12
    M -= edge * 0.1

    # Normal map from the height field (wrapped differences).
    s = 3.0
    dx = (np.roll(H, -1, 1) - np.roll(H, 1, 1)) * s
    dy = (np.roll(H, -1, 0) - np.roll(H, 1, 0)) * s
    nz = np.ones_like(H)
    l = np.sqrt(dx * dx + dy * dy + nz * nz)
    # Image rows run top to bottom; OpenGL normals want +Y up.
    normal = np.stack([(-dx / l) * 0.5 + 0.5, (dy / l) * 0.5 + 0.5, (nz / l) * 0.5 + 0.5], -1)

    def save(arr, suffix, srgb=False):
        arr = np.clip(arr, 0, 1)
        if arr.ndim == 2:
            arr = np.repeat(arr[..., None], 3, -1)
        if srgb:
            arr = arr ** (1 / 2.2)
        rgba = np.concatenate([arr, np.ones((N, N, 1), np.float32)], -1)
        img = bpy.data.images.new(name + suffix, N, N, alpha=False, float_buffer=False)
        img.colorspace_settings.name = 'Non-Color'
        # Blender's pixel rows start at the bottom.
        img.pixels.foreach_set(rgba[::-1].astype(np.float32).ravel())
        img.filepath_raw = os.path.join(OUT, "%s_%s.png" % (name, suffix))
        img.file_format = 'PNG'
        img.save()
        bpy.data.images.remove(img)

    save(A, "color", srgb=True)
    save(normal, "normal")
    save(np.clip(R, 0.08, 0.95), "rough")
    save(np.clip(M, 0, 1), "metal")
    save(E, "emit", srgb=True)


def maps():
    """Empty height, albedo, roughness, metalness and emission maps."""
    return (np.zeros((N, N), np.float32), np.zeros((N, N, 3), np.float32), np.zeros((N, N), np.float32),
            np.zeros((N, N), np.float32), np.zeros((N, N, 3), np.float32))


def grid():
    yy, xx = np.mgrid[0:N, 0:N]
    return yy.astype(np.float32), xx.astype(np.float32)


def wrap(d):
    """Shortest signed distance on the torus."""
    return d - N * np.round(d / N)


def scratches(rng, A, R, M, count, length=(20, 120)):
    """Thin bright lines of bare metal, wrapped so they tile."""
    for _ in range(count):
        x0, y0 = rng.uniform(0, N, 2)
        a = rng.uniform(0, np.pi)
        t = np.arange(int(rng.uniform(*length)))
        px = (x0 + np.cos(a) * t).astype(int) % N
        py = (y0 + np.sin(a) * t).astype(int) % N
        A[py, px] = A[py, px] * 0.6 + 0.3
        M[py, px] = 0.9
        R[py, px] = 0.25


def armor(name, seed):
    """Heavy warship armour: big thick plates with deep seams, bolt rows,
    angled cuts, layered appliqué plates, stencilled numbers, scorch marks."""
    rng = np.random.default_rng(seed)
    H, A, R, M, E = maps()
    plates = []
    split(rng, 0, 0, N, N, plates, 0, True, min_area=150 * 150, min_side=90)
    chip = fft_noise(rng, 3)
    for (x, y, w, h) in plates:
        sl = (slice(y, y + h), slice(x, x + w))
        tone = rng.uniform(0.32, 0.55) if rng.random() > 0.15 else rng.uniform(0.2, 0.28)
        warm = rng.uniform(-0.02, 0.02)
        d = edge_distance(w, h)
        yy, xx = np.mgrid[0:h, 0:w]
        k = rng.uniform(9, 16)
        H[sl] += np.clip(d / k, 0, 1) * (1.0 + rng.choice([0.0, 0.3, -0.2]))
        A[sl] = (tone + warm, tone, tone - warm)
        R[sl] = 0.42 + rng.uniform(-0.06, 0.06)
        M[sl] = 0.65 + rng.uniform(-0.08, 0.08)
        seam = d < 2.0
        H[sl][seam] -= 0.8
        A[sl][seam] *= 0.22
        # Paint chipped off the plate edges down to bright bare metal.
        chipped = (d > 2) & (d < k + 4) & (chip[sl] > 0.62)
        A[sl][chipped] = 0.62
        M[sl][chipped] = 0.9
        R[sl][chipped] = 0.3

        # Bolt rows just inside the bevel, spaced along whichever edge is closest.
        ring = np.abs(d - (k + 6)) < 2.2
        along = np.where(np.minimum(yy, h - 1 - yy) <= np.minimum(xx, w - 1 - xx), xx, yy)
        bolts = ring & (along % 24 < 4)
        H[sl][bolts] += 0.55
        A[sl][bolts] *= 1.2

        # Angled cut across a corner: a groove with a step down beyond it.
        if rng.random() < 0.35:
            c = rng.uniform(0.25, 0.45) * (w + h)
            diag = (xx + yy) if rng.random() < 0.5 else (xx + (h - 1 - yy))
            groove = np.abs(diag - c) < 1.8
            beyond = diag < c
            H[sl][beyond] -= 0.3
            H[sl][groove] -= 0.6
            A[sl][groove] *= 0.3

        # Appliqué plate bolted on top.
        if rng.random() < 0.45 and min(w, h) > 150:
            aw, ah = int(w * rng.uniform(0.35, 0.7)), int(h * rng.uniform(0.35, 0.7))
            ax, ay = int(rng.integers(20, w - aw - 19)), int(rng.integers(20, h - ah - 19))
            asl = (slice(y + ay, y + ay + ah), slice(x + ax, x + ax + aw))
            ad = edge_distance(aw, ah)
            H[asl] += np.clip(ad / 6, 0, 1) * 0.45
            A[asl] *= rng.uniform(0.85, 1.1)
            A[asl][ad < 1.5] *= 0.35
            ayy, axx = np.mgrid[0:ah, 0:aw]
            a_along = np.where(np.minimum(ayy, ah - 1 - ayy) <= np.minimum(axx, aw - 1 - axx), axx, ayy)
            H[asl][(np.abs(ad - 9) < 2) & (a_along % 18 < 3)] += 0.3

        # Stencilled numbers: blocky glyphs in pale paint.
        if rng.random() < 0.3 and w > 160 and h > 90:
            gx, gy = x + int(k) + 18, y + int(k) + 18
            for g in range(int(rng.integers(2, 5))):
                for (bx, by, bw, bh) in [(0, 0, 14, 4), (0, 0, 4, 24), (10, 0, 4, 24), (0, 20, 14, 4), (0, 10, 14, 4)]:
                    if rng.random() < 0.6:
                        gsl = (slice(gy + by, gy + by + bh), slice(gx + g * 20 + bx, gx + g * 20 + bx + bw))
                        A[gsl] = 0.82
                        M[gsl] = 0.05
                        R[gsl] = 0.6

        # Rare dim red running light.
        if rng.random() < 0.05:
            cy, cx = y + h // 2, x + w // 2
            E[cy - 3:cy + 3, cx - 3:cx + 3] = (1.0, 0.18, 0.1)
            H[cy - 4:cy + 4, cx - 4:cx + 4] += 0.3

    # Scorch marks from weapons fire, and scratched-through paint.
    burn = np.clip((fft_noise(rng, 22) - 0.62) * 4, 0, 1)
    A *= (1 - 0.6 * burn)[..., None]
    R += 0.2 * burn
    M -= 0.3 * burn
    scratches(rng, A, R, M, 900)
    finish(name, rng, H, A, R, M, E, grime_amount=0.9)
    return len(plates)


def stealth(name, seed):
    """Dark faceted composite: Voronoi facets, each a flat plane at its own
    tilt, with a faint grid of absorber tiles and almost no lights."""
    rng = np.random.default_rng(seed)
    H, A, R, M, E = maps()
    yy, xx = grid()
    seeds = rng.uniform(0, N, (110, 2))
    d1 = np.full((N, N), np.inf, np.float32)
    d2 = np.full((N, N), np.inf, np.float32)
    idx = np.zeros((N, N), np.int32)
    ddx = np.zeros((N, N), np.float32)
    ddy = np.zeros((N, N), np.float32)
    for i, (sx, sy) in enumerate(seeds):
        dx, dy = wrap(xx - sx), wrap(yy - sy)
        d = np.sqrt(dx * dx + dy * dy)
        closer = d < d1
        d2 = np.where(closer, d1, np.minimum(d2, d))
        d1 = np.where(closer, d, d1)
        idx = np.where(closer, i, idx)
        ddx = np.where(closer, dx, ddx)
        ddy = np.where(closer, dy, ddy)
    n = len(seeds)
    tilt = rng.normal(0, 0.03, (n, 2)).astype(np.float32)
    tone = rng.uniform(0.05, 0.09, n).astype(np.float32)
    rough = rng.uniform(0.55, 0.78, n).astype(np.float32)
    H[:] = tilt[idx, 0] * ddx + tilt[idx, 1] * ddy
    A[:] = (tone[idx] * 0.97)[..., None] * np.array([1.0, 1.02, 1.06], np.float32)
    R[:] = rough[idx]
    M[:] = 0.15
    edge = (d2 - d1) / 2
    seam = edge < 1.3
    A[seam] *= 0.45
    R[seam] = 0.85
    # Absorber tiles: a faint 32 px grid.
    tiles = ((xx % 32) < 1) | ((yy % 32) < 1)
    H[tiles] -= 0.06
    A[tiles] *= 0.85
    # A handful of dim red edge lights.
    for _ in range(14):
        cx, cy = rng.integers(4, N - 4, 2)
        E[cy - 2:cy + 2, cx - 2:cx + 2] = (0.5, 0.06, 0.04)
    finish(name, rng, H, A, R, M, E, grime_amount=0.35, streak_amount=0.3)
    return n


def hexes(name, seed, cols=32, rows=36):
    """Hexagonal armour tiles on a staggered lattice (rows even so the stagger
    wraps), slightly domed, with the odd tile missing or replaced."""
    rng = np.random.default_rng(seed)
    H, A, R, M, E = maps()
    yy, xx = grid()
    cw, rh = N / cols, N / rows
    d1 = np.full((N, N), np.inf, np.float32)
    d2 = np.full((N, N), np.inf, np.float32)
    idx = np.zeros((N, N), np.int32)
    j0 = np.floor(yy / rh).astype(np.int32)
    for dj in (-1, 0, 1):
        j = j0 + dj
        off = 0.5 * (j % 2)
        ic = np.round(xx / cw - 0.5 - off).astype(np.int32)
        for di in (-1, 0, 1):
            i = ic + di
            dx = wrap(xx - (i + 0.5 + off) * cw)
            dy = wrap(yy - (j + 0.5) * rh)
            d = np.sqrt(dx * dx + dy * dy)
            closer = d < d1
            d2 = np.where(closer, d1, np.minimum(d2, d))
            d1 = np.where(closer, d, d1)
            idx = np.where(closer, (j % rows) * cols + (i % cols), idx)
    n = cols * rows
    kind = rng.random(n)
    tone = rng.uniform(0.42, 0.65, n).astype(np.float32)
    tone[(kind > 0.06) & (kind < 0.2)] *= 0.75              # replacement tiles
    edge = (d2 - d1) / 2
    H[:] = np.clip(edge / 6, 0, 1) + np.clip(1 - (d1 / (cw * 0.55)) ** 2, 0, 1) * 0.25
    A[:] = tone[idx][..., None] * np.array([1.0, 1.0, 1.02], np.float32)
    R[:] = 0.38 + rng.uniform(-0.06, 0.06, n)[idx]
    M[:] = 0.7 + rng.uniform(-0.08, 0.08, n)[idx]
    bolt = d1 < 3.2
    H[bolt] += 0.3
    A[bolt] *= 1.15
    # Missing tiles show the recessed frame and a cross brace underneath.
    missing = (kind < 0.06)[idx] & (edge > 2.5)
    H[missing] = -0.4 + 0.3 * (((xx - yy) % 32 < 3) | ((xx + yy) % 32 < 3))[missing]
    A[missing] = 0.12
    M[missing] = 0.8
    seam = edge < 1.5
    H[seam] -= 0.6
    A[seam] *= 0.3
    # A few tiles carry a blue emitter at the centre.
    lit = (kind > 0.985)[idx] & (d1 < 4)
    E[lit] = (0.35, 0.65, 1.0)
    scratches(rng, A, R, M, 250)
    finish(name, rng, H, A, R, M, E, grime_amount=0.8)
    return n


def ribbed(name, seed):
    """Civil freighter hull: horizontal bands of corrugated, smooth or
    stringered plating, crossed by frame ribs every 256 px, with painted
    bands, hull numbers and a few running lights."""
    rng = np.random.default_rng(seed)
    H, A, R, M, E = maps()
    yy, xx = grid()
    y = 0
    while y < N:
        h = int(rng.choice([32, 48, 64, 96, 128, 192]))
        if N - y - h < 48:
            h = N - y
        sl = slice(y, y + h)
        dy = np.minimum(yy[sl] - y, y + h - 1 - yy[sl])
        kind = rng.choice(["corrugated", "smooth", "stringer", "vent"], p=[0.45, 0.3, 0.15, 0.1])
        tone = rng.uniform(0.38, 0.62)
        painted = rng.random() < 0.6
        col = np.array([tone, tone, tone], np.float32)
        if painted and rng.random() < 0.3:
            col *= rng.choice([(0.95, 0.6, 0.3), (0.35, 0.65, 0.7), (0.85, 0.8, 0.4)])   # faded livery band
        H[sl] += np.clip(dy / 4, 0, 1) * 0.6
        A[sl] = col
        R[sl] = 0.55 if painted else 0.35
        M[sl] = 0.1 if painted else 0.7
        if kind == "corrugated":
            p = rng.choice([16, 32])
            H[sl] += 0.5 * (0.5 + 0.5 * np.cos(2 * np.pi * xx[sl] / p)) * np.clip(dy / 6, 0, 1)
        elif kind == "stringer":
            for _ in range(int(rng.integers(1, 4))):
                c0 = y + h * rng.uniform(0.2, 0.8)
                t = np.clip(1 - ((yy[sl] - c0) / 3.5) ** 2, 0, 1)
                H[sl] = np.where(t > 0, np.maximum(H[sl], 0.6 + np.sqrt(t) * 0.6), H[sl])
        elif kind == "vent" and h >= 48:
            inside = (dy > 10) & (np.sin(xx[sl] * (2 * np.pi / 1024) + y) > 0.3)
            slat = (xx[sl] % 8) < 3
            H[sl][inside] -= 0.35
            H[sl][inside & slat] -= 0.35
            A[sl][inside & slat] *= 0.35
        seam = dy < 1.5
        H[sl][seam] -= 0.6
        A[sl][seam] *= 0.3
        # Hull number on some painted bands.
        if painted and h >= 64 and rng.random() < 0.4:
            gx = int(rng.integers(0, N - 200))
            gy = y + h // 2 - 14
            for g in range(int(rng.integers(2, 5))):
                for (bx, by, bw, bh) in [(0, 0, 18, 5), (0, 0, 5, 28), (13, 0, 5, 28), (0, 23, 18, 5), (0, 12, 18, 5)]:
                    if rng.random() < 0.6:
                        A[gy + by:gy + by + bh, gx + g * 26 + bx:gx + g * 26 + bx + bw] = 0.9
        y += h
    # Frame ribs, rivetted, across every band.
    rib = (xx % 256) < 12
    rd = np.minimum(xx % 256, 11 - xx % 256)
    H[rib] = 0.9 + np.clip(rd[rib] / 3, 0, 1) * 0.4
    A[rib] = A[rib] * 0.8
    M[rib] = 0.75
    rivet = rib & (np.abs(xx % 256 - 5.5) < 2) & (yy % 16 < 3)
    H[rivet] += 0.3
    # Running lights on some rib crossings.
    for _ in range(18):
        cx = int(rng.integers(0, 8)) * 256 + 6
        cy = int(rng.integers(8, N - 8))
        E[cy - 2:cy + 3, cx - 2:cx + 3] = (1.0, 0.3, 0.2) if rng.random() < 0.5 else (0.4, 1.0, 0.5)
    scratches(rng, A, R, M, 200)
    finish(name, rng, H, A, R, M, E, grime_amount=1.2, streak_amount=1.4)
    return 1


# ---------------------------------------------------------------- interiors
#
# Dark, heavy tech interiors in the spirit of id Tech 4 (Doom 3) era sets,
# all original: deep bevelled modules, conduits, grilles and bolts in dark
# gunmetal, with a lot of grime in the cavities and bright wear on the
# edges, so they read under hard per-light shading with no fill. One tile
# is 4 m (the briefing room's UVs run one unit per 4 m).


def bolts(H, A, M, cx, cy, r=6):
    yy, xx = np.mgrid[-r:r + 1, -r:r + 1]
    t = np.clip(1 - (xx * xx + yy * yy) / float(r * r), 0, 1)
    for x, y in zip(np.atleast_1d(cx), np.atleast_1d(cy)):
        x, y = int(x) % N, int(y) % N
        sy, sx = slice(max(y - r, 0), min(y + r + 1, N)), slice(max(x - r, 0), min(x + r + 1, N))
        tt = t[sy.start - (y - r):sy.stop - (y - r), sx.start - (x - r):sx.stop - (x - r)]
        H[sy, sx] = np.maximum(H[sy, sx], H[sy, sx] * (tt <= 0) + (np.sqrt(tt) * 0.5 + 0.2) * (tt > 0))
        A[sy, sx] = np.where((tt > 0)[..., None], A[sy, sx] * 0.7 + 0.08, A[sy, sx])
        M[sy, sx] = np.where(tt > 0, 0.85, M[sy, sx])


def grille(H, A, R, sl, w, h, pitch=12, vertical=False):
    """Slots through a panel: louvres over a black void."""
    yy, xx = np.mgrid[0:h, 0:w]
    u = (xx if vertical else yy) % pitch
    slat = np.clip(1 - np.abs(u - pitch / 2) / (pitch / 2), 0, 1)
    d = edge_distance(w, h)
    inside = d > 6
    H[sl] = np.where(inside, H[sl] - 0.7 + slat * 0.55, H[sl])
    A[sl] = np.where(inside[..., None], A[sl] * (0.25 + 0.75 * slat[..., None] ** 2), A[sl])
    R[sl] = np.where(inside, 0.7, R[sl])


def pipes(H, A, M, R, y0, count, radius, gap):
    """Horizontal conduits across the tile, wrapped."""
    yy, _ = grid()
    for k in range(count):
        c = y0 + k * (2 * radius + gap)
        t = np.clip(1 - (wrap(yy - c) / radius) ** 2, 0, 1)
        on = t > 0
        H[on] = np.maximum(H[on], 0.6 + np.sqrt(t[on]) * 0.9)
        A[on] = A[on] * 0.6 + 0.07
        M[on] = 0.8
        R[on] = 0.3
        # Clamps every 512 px.
        _, xx = grid()
        clamp = on & (np.abs(wrap(xx - 128 - 512 * (k % 2) / 2) % 512 - 256) < 10)
        H[clamp] += 0.35
        A[clamp] *= 0.6


def plate(rng, A, R, M, sl, tone, rough=0.3):
    """A smooth metal plate: one flat cool grey-green, a little per-plate."""
    t = tone * rng.uniform(0.95, 1.05)
    A[sl] = np.array([0.93, 1.0, 0.98], np.float32) * t
    R[sl] = rough + rng.uniform(-0.03, 0.03)
    M[sl] = 0.65


def raised(H, sl, w, h, height, bevel):
    """Raise a rectangle with a sloped edge `bevel` px wide."""
    H[sl] += np.clip(edge_distance(w, h) / bevel, 0, 1) * height


def seam(H, A, sl, w, h, width=2.5):
    d = edge_distance(w, h)
    H[sl][d < width] -= 1.0
    A[sl][d < width] *= 0.25


def techwall(name, seed):
    """Wall modules 1024 px (2 m) wide and the tile (4 m) tall, in bands:
    a lamp lip, a tall smooth upper plate, a ledge, a lower plate with
    faint hazard striping, a vent strip, a kick plate; a thick raised
    pillar between modules. Big calm surfaces, few details."""
    rng = np.random.default_rng(seed)
    H, A, R, M, E = maps()
    P = 64                                       # half the pillar
    bands = [(0, 130, "lip"), (130, 760, "upper"), (890, 120, "ledge"), (1010, 560, "lower"),
             (1570, 110, "vent"), (1680, 368, "kick")]
    for col in range(2):
        x0, x1 = col * 1024 + P, col * 1024 + 1024 - P
        w = x1 - x0
        for (y, h, kind) in bands:
            sl = (slice(y, y + h), slice(x0, x1))
            tone = {"lip": 0.2, "upper": 0.34, "ledge": 0.38, "lower": 0.3, "vent": 0.16, "kick": 0.24}[kind]
            plate(rng, A, R, M, sl, tone, 0.26 if kind in ("upper", "lower") else 0.38)
            if kind == "ledge":
                raised(H, sl, w, h, 3.0, 22)
            elif kind == "lip":
                raised(H, sl, w, h, 2.0, 14)
                d = edge_distance(w, h)
                slot = (slice(y + 40, y + 90), slice(x0 + 120, x1 - 120))
                H[slot] -= 1.5
                A[slot] *= 0.3
            elif kind == "vent":
                grille(H, A, R, (slice(y + 20, y + h - 20), slice(x0 + 60, x1 - 60)), w - 120, h - 40, pitch=16, vertical=True)
            elif kind == "upper":
                raised(H, sl, w, h, 0.8, 30)
                # Two small inlets and a status light housing, low on the plate.
                for (ix, iy, iw, ih) in [(80, 560, 180, 26), (w - 300, 560, 120, 26), (w // 2 - 40, 600, 80, 14)]:
                    isl = (slice(y + iy, y + iy + ih), slice(x0 + ix, x0 + ix + iw))
                    H[isl] -= 0.6
                    A[isl] *= 0.35
            elif kind == "lower":
                raised(H, sl, w, h, 0.5, 30)
                yy, xx = np.mgrid[0:h, 0:w]
                stripe = (((xx + yy) // 90) % 2 == 0) & (yy > 300) & (yy < 520)
                A[sl] = np.where(stripe[..., None], A[sl] * 0.82, A[sl])
            else:
                raised(H, sl, w, h, 1.2, 12)
            seam(H, A, sl, w, h)
        # The pillar: raised, a groove down the middle, bolted.
        for xs in ([slice(N - P, N), slice(0, P)] if col == 0 else [slice(1024 - P, 1024 + P)]):
            sl = (slice(0, N), xs)
            plate(rng, A, R, M, sl, 0.28, 0.32)
            H[sl] += 4.0
        c = col * 1024
        _, xx = grid()
        dx = np.abs(wrap(xx - c))
        groove = dx < 8
        H[groove] -= 2.0
        A[groove] *= 0.3
        edge = (dx >= P - 3) & (dx < P)
        H[edge] -= 1.5
        bolts(H, A, M, np.full(N // 256, (c + 32) % N), np.arange(128, N, 256), r=8)
        bolts(H, A, M, np.full(N // 256, (c - 32) % N), np.arange(128, N, 256), r=8)
    scratches(rng, A, R, M, 120, length=(10, 60))
    finish(name, rng, H, A, R, M, E, grime_amount=0.35, streak_amount=0.5)
    return 1


def techfloor(name, seed):
    """Floor: 256 px (0.5 m) square tiles, smooth and faintly bevelled,
    in thin dark grout."""
    rng = np.random.default_rng(seed)
    H, A, R, M, E = maps()
    T = 256
    for ty in range(N // T):
        for tx in range(N // T):
            sl = (slice(ty * T, ty * T + T), slice(tx * T, tx * T + T))
            plate(rng, A, R, M, sl, 0.3, 0.3)
            M[sl] = 0.15                          # ceramic, not metal
            raised(H, sl, T, T, 1.0, 6)
            seam(H, A, sl, T, T, 3.0)
    finish(name, rng, H, A, R, M, E, grime_amount=0.4, streak_amount=0.0)
    return 1


def techgrate(name, seed):
    """Walkway grating: 512 px (1 m) panels of square mesh in frames."""
    rng = np.random.default_rng(seed)
    H, A, R, M, E = maps()
    T = 512
    yy, xx = np.mgrid[0:T, 0:T]
    mesh = ((xx % 24) < 5) | ((yy % 24) < 5)
    for ty in range(N // T):
        for tx in range(N // T):
            sl = (slice(ty * T, ty * T + T), slice(tx * T, tx * T + T))
            plate(rng, A, R, M, sl, 0.3, 0.35)
            d = edge_distance(T, T)
            frame = d < 22
            hole = ~mesh & ~frame
            H[sl] = np.where(frame, 2.0, np.where(mesh, 1.2, -2.0))
            A[sl] = np.where(hole[..., None], 0.02, A[sl])
            R[sl] = np.where(hole, 0.9, R[sl])
            seam(H, A, sl, T, T, 2.5)
    finish(name, rng, H, A, R, M, E, grime_amount=0.5, streak_amount=0.0)
    return 1


def techtrim(name, seed):
    """Beams and machinery: big bevelled 1024 x 512 px plates, a slot or
    a vent on some, bolted corners."""
    rng = np.random.default_rng(seed)
    H, A, R, M, E = maps()
    TW, TH = 1024, 512
    for ty in range(N // TH):
        for tx in range(N // TW):
            sl = (slice(ty * TH, ty * TH + TH), slice(tx * TW, tx * TW + TW))
            plate(rng, A, R, M, sl, rng.choice([0.26, 0.32]), 0.3)
            raised(H, sl, TW, TH, 2.0, 24)
            k = rng.choice(["plain", "slot", "vent"], p=[0.5, 0.3, 0.2])
            if k == "slot":
                isl = (slice(ty * TH + 220, ty * TH + 260), slice(tx * TW + 160, tx * TW + 860))
                H[isl] -= 1.2
                A[isl] *= 0.3
            elif k == "vent":
                grille(H, A, R, (slice(ty * TH + 140, ty * TH + 370), slice(tx * TW + 300, tx * TW + 724)), 424, 230, pitch=16)
            seam(H, A, sl, TW, TH)
            bolts(H, A, M, np.array([tx * TW + 40, tx * TW + TW - 40] * 2),
                  np.array([ty * TH + 40, ty * TH + 40, ty * TH + TH - 40, ty * TH + TH - 40]), r=9)
    scratches(rng, A, R, M, 100, length=(10, 60))
    finish(name, rng, H, A, R, M, E, grime_amount=0.35, streak_amount=0.5)
    return 1

SETS = {
    "panels": lambda: generate("panels", 11, detail=1.0, paint=0.35, windows=0.05, tones=(0.48, 0.86)),
    "plating": lambda: generate("plating", 23, detail=0.55, paint=0.6, windows=0.08, big=True, tones=(0.62, 0.9)),
    "armor": lambda: armor("armor", 37),
    "stealth": lambda: stealth("stealth", 41),
    "hex": lambda: hexes("hex", 53),
    "ribbed": lambda: ribbed("ribbed", 67),
    # Interior bulkheads (the briefing room): big painted panels, few
    # greebles, no windows.
    "bulkhead": lambda: generate("bulkhead", 79, detail=0.25, paint=0.8, windows=0.0, big=True, tones=(0.55, 0.72)),
    # Interiors with no fill light (the briefing room under stencil shadows).
    "techwall": lambda: techwall("techwall", 83),
    "techfloor": lambda: techfloor("techfloor", 89),
    "techtrim": lambda: techtrim("techtrim", 97),
    "techgrate": lambda: techgrate("techgrate", 101),
}

os.makedirs(OUT, exist_ok=True)
import sys
wanted = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else list(SETS)
for set_name in wanted:
    print({set_name: SETS[set_name]()})
