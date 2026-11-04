# Generates tileable spaceship hull texture sets into Resources/Textures/:
#   <set>_color.png  albedo (neutral, tinted per faction in game)
#   <set>_normal.png OpenGL-convention normal map
#   <set>_rough.png  roughness
#   <set>_metal.png  metalness
#   <set>_emit.png   lit windows and running lights
#
#   Blender -b --factory-startup --python Art/build_hull_textures.py
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


def split(rng, x, y, w, h, out, depth=0, big=False):
    """Recursive kd split into panels, snapped to an 8 px grid."""
    area = w * h
    stop = area < 56 * 56 or (depth > 3 and rng.random() < (0.22 if not big else 0.4) * (depth - 3))
    if stop or min(w, h) < 40:
        out.append((x, y, w, h))
        return
    horizontal = w < h if rng.random() < 0.8 else rng.random() < 0.5
    if horizontal:
        s = int(h * rng.uniform(0.25, 0.75)) // 8 * 8
        if s < 24 or h - s < 24:
            out.append((x, y, w, h)); return
        split(rng, x, y, w, s, out, depth + 1, big)
        split(rng, x, y + s, w, h - s, out, depth + 1, big)
    else:
        s = int(w * rng.uniform(0.25, 0.75)) // 8 * 8
        if s < 24 or w - s < 24:
            out.append((x, y, w, h)); return
        split(rng, x, y, s, h, out, depth + 1, big)
        split(rng, x + s, y, w - s, h, out, depth + 1, big)


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

    # Weathering: blotchy grime, vertical streaks, and wear on raised edges.
    grime = fft_noise(rng, 60)
    fine = fft_noise(rng, 6)
    streak = fft_noise(rng, 40, aniso=(0.4, 6.0))
    dirt = np.clip(0.62 + 0.4 * grime + 0.12 * (fine - 0.5) - 0.5 * np.clip(streak - 0.55, 0, 1), 0.35, 1.1)
    A *= dirt[..., None]
    R += 0.18 * (1 - grime) + 0.08 * (fine - 0.5)
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
    return len(panels)


os.makedirs(OUT, exist_ok=True)
print({"panels": generate("panels", 11, detail=1.0, paint=0.35, windows=0.05, tones=(0.48, 0.86))})
print({"plating": generate("plating", 23, detail=0.55, paint=0.6, windows=0.08, big=True, tones=(0.62, 0.9))})
