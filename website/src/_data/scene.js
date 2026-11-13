// The site's artwork: a coastal city at sunset behind coconut palms, drawn at
// build time from fixed seeds. No image files in the repository, and the same
// SVG on every build. Each layer becomes a file under /assets/scene/
// (src/scene.njk), so that the browser caches it and moves it as one bitmap.
import { createHash } from "node:crypto";

const W = 1600;
const H = 1000;
const HORIZON = 690;
const SUN = { x: 1010, y: 646, r: 80 };

const TAU = Math.PI * 2;
const rad = (deg) => (deg * Math.PI) / 180;
const lerp = (a, b, t) => a + (b - a) * t;
const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n));
const smooth = (t) => {
  const c = clamp(t, 0, 1);
  return c * c * (3 - 2 * c);
};

// mulberry32: a small seeded generator, so that every build draws the same.
function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// One decimal is enough at the sizes the layers are shown.
const n1 = (n) => {
  const r = Math.round(n * 10) / 10;
  return r === 0 ? "0" : String(r);
};
const pt = (x, y) => `${n1(x)} ${n1(y)}`;

function svgFile(width, height, body, viewBox = `0 0 ${width} ${height}`) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${viewBox}" width="${n1(width)}" height="${n1(height)}">${body}</svg>`;
}

// A closed shape around a polyline, `half(i)` wide on either side of point i.
// Every shape in this file is wound the same way, so shapes that overlap
// within one path fill solid.
function ribbon(points, half) {
  const left = [];
  const right = [];
  for (let i = 0; i < points.length; i++) {
    const a = points[Math.max(0, i - 1)];
    const b = points[Math.min(points.length - 1, i + 1)];
    const len = Math.hypot(b.x - a.x, b.y - a.y) || 1;
    const nx = (-(b.y - a.y) / len) * half(i);
    const ny = ((b.x - a.x) / len) * half(i);
    left.push(pt(points[i].x - nx, points[i].y - ny));
    right.push(pt(points[i].x + nx, points[i].y + ny));
  }
  return `M${left.join("L")}L${right.reverse().join("L")}Z`;
}

// A tapering blade from a base point through a control point to its tip:
// leaflets, grass, fan segments.
function blade(bx, by, cx, cy, tx, ty, width) {
  const len = Math.hypot(tx - bx, ty - by) || 1;
  const px = (-(ty - by) / len) * (width / 2);
  const py = ((tx - bx) / len) * (width / 2);
  const x0 = bx - px;
  const y0 = by - py;
  return (
    `M${pt(x0, y0)}q${pt(cx - px * 0.7 - x0, cy - py * 0.7 - y0)} ${pt(tx - x0, ty - y0)}` +
    `q${pt(cx + px * 0.7 - tx, cy + py * 0.7 - ty)} ${pt(bx + px - tx, by + py - ty)}z`
  );
}

// ---------- Palms ----------

// One frond of a coconut palm. The midrib grows from the crown in a vertical
// plane turned `azimuth` around the trunk, starts `elevation` away from
// straight up and bends under its own weight. Leaflets leave it on both
// sides, out of that plane, and hang. Everything is then projected onto the
// picture: a frond seen from the side shows a hanging fringe, one that points
// at the viewer a short feather.
function frond(rand, crown, o) {
  const cosA = Math.cos(o.azimuth);
  const sinA = Math.sin(o.azimuth);
  const steps = Math.max(8, Math.round(o.length / (o.pitch * o.scale)));
  const ds = o.length / steps;
  let a = o.elevation - Math.PI / 2;
  let u = 0;
  let v = 0;
  const rib = [];
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    rib.push({ x: crown.x + u * cosA, y: crown.y + v, a, t });
    a = Math.min(a + (o.bend * (0.25 + 2.25 * t * t)) / steps, rad(86));
    u += Math.cos(a) * ds;
    v += Math.sin(a) * ds;
  }

  let d = ribbon(rib, (i) => o.scale * (2.7 * (1 - rib[i].t) + 0.55));
  const longest = o.leaflet * o.scale;
  let gap = 0;
  for (let i = 1; i <= steps; i++) {
    const { x, y, a: ang, t } = rib[i];
    if (t < 0.1) continue;
    const k = (t - 0.1) / 0.9;
    if (gap > 0) {
      gap--;
      continue;
    }
    if (rand() < o.tatter) {
      gap = 1 + Math.floor(rand() * 4);
      continue;
    }
    const profile = (0.5 + 0.5 * smooth(k / 0.28)) * (1 - 0.72 * smooth((k - 0.5) / 0.5));
    const sweep = o.closed ? rad(14) : rad(lerp(64, 36, k) + (rand() - 0.5) * 10);
    const lift = o.closed ? 0 : rad(lerp(34, 4, k));
    const weight = o.closed ? 0.1 : lerp(0.55, 1.5, k) * o.limp;
    const cosS = Math.cos(sweep);
    const sinS = Math.sin(sweep);
    for (const side of [1, -1]) {
      const size = longest * profile * (0.82 + rand() * 0.36);
      // Direction in space: along the midrib, sideways out of the frond's
      // plane, and up out of the trough the two rows form.
      const sx = side * Math.cos(lift);
      const sy = Math.sin(lift);
      const dx = Math.cos(ang) * cosA * cosS + (-sinA * sx + Math.sin(ang) * cosA * sy) * sinS;
      const dy = Math.sin(ang) * cosS - Math.cos(ang) * sy * sinS;
      const dz = Math.cos(ang) * sinA * cosS + (cosA * sx + Math.sin(ang) * sinA * sy) * sinS;
      // The outer half gives in to gravity.
      const m = Math.hypot(dx, dy + weight, dz);
      const cx = x + dx * size * 0.45;
      const cy = y + dy * size * 0.45;
      const tx = cx + (dx / m) * size * 0.55;
      const ty = cy + ((dy + weight) / m) * size * 0.55;
      if (Math.hypot(tx - x, ty - y) < 3 * o.scale) continue;
      d += blade(x, y, cx, cy, tx, ty, clamp(size * 0.13, 1.6, 5.2) * o.scale);
    }
  }
  return { d, rib };
}

// How far a frond bends in total, by how far from upright it starts: young
// fronds stand stiff, the ones in the middle of the crown arch over, the old
// ones already hang.
function bendFor(elevationDeg) {
  if (elevationDeg < 45) return lerp(22, 105, elevationDeg / 45);
  if (elevationDeg < 90) return lerp(105, 78, (elevationDeg - 45) / 45);
  return lerp(78, 30, clamp((elevationDeg - 90) / 60, 0, 1));
}

// A coconut palm as a file of its own: a slender trunk that leans out at the
// foot and straightens towards the crown, and the crown's fronds set around
// it by the golden angle. `sun` is the side the light comes from (1: right).
function palm(seed, o) {
  const rand = rng(seed);
  const scale = o.height / 800;
  const p0 = { x: 0, y: 60 * scale };
  const p3 = { x: o.lean, y: -o.height };
  const p1 = { x: o.lean * 0.62, y: -o.height * 0.3 };
  const p2 = { x: o.lean * 1.04, y: -o.height * 0.68 };
  const steps = Math.ceil(o.height / 5);
  const spine = [];
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    const q = 1 - t;
    spine.push({
      x: q ** 3 * p0.x + 3 * q * q * t * p1.x + 3 * q * t * t * p2.x + t ** 3 * p3.x,
      y: q ** 3 * p0.y + 3 * q * q * t * p1.y + 3 * q * t * t * p2.y + t ** 3 * p3.y,
      t,
    });
  }
  const top = o.girth * 0.6;
  const half = (i) => {
    const t = spine[i].t;
    // Swollen foot, old leaf bases under the crown, and the leaf scars that
    // ring the trunk.
    const body = top + (o.girth - top) * (1 - t) ** 1.5;
    return (body + o.girth * 0.5 * Math.exp(-t * 22) + top * 0.55 * Math.exp(-(1 - t) * 34)) / 2 + (i % 2 ? 0.55 : 0) * scale;
  };
  const trunk = ribbon(spine, half);
  // The edge of the trunk that faces the sun.
  const lit = [];
  for (let i = 4; i < steps; i += 2) {
    const a = spine[i - 1];
    const b = spine[i + 1];
    const len = Math.hypot(b.x - a.x, b.y - a.y) || 1;
    const h = (half(i) - 1.1 * scale) * o.sun;
    lit.push(pt(spine[i].x - ((b.y - a.y) / len) * h, spine[i].y + ((b.x - a.x) / len) * h));
  }

  const crown = p3;
  const fronds = [];
  const phase = rand() * TAU;
  for (let i = 0; i < o.fronds; i++) {
    const age = i / (o.fronds - 1);
    const azimuth = phase + i * rad(137.5);
    // The wind lifts the fronds that face it and presses the others down.
    const elevationDeg = clamp(lerp(5, 148, age ** 0.92) + (rand() - 0.5) * 12 + o.wind * Math.cos(azimuth), 3, 158);
    const spear = i === 0;
    fronds.push(
      frond(rand, crown, {
        azimuth,
        elevation: rad(elevationDeg),
        length: o.crown * (spear ? 0.52 : i < 3 ? 0.7 + i * 0.08 : 0.9 + rand() * 0.22) * (age > 0.86 ? 0.84 : 1),
        bend: rad(bendFor(elevationDeg) * (0.85 + rand() * 0.3)),
        leaflet: o.crown * 0.23,
        limp: lerp(0.8, 1.25, age),
        tatter: lerp(0.01, 0.07, age),
        closed: spear,
        pitch: o.pitch ?? 6.2,
        scale,
      }),
    );
  }

  let nuts = "";
  const r = top * 0.58;
  for (const [dx, dy] of [
    [-1.1, 1.3],
    [0.9, 1.5],
    [-0.2, 2.2],
    [1.6, 0.6],
    [-1.7, 0.5],
  ]) {
    nuts += `<ellipse cx="${n1(crown.x + dx * r * 1.25)}" cy="${n1(crown.y + dy * r * 1.3 + r)}" rx="${n1(r)}" ry="${n1(r * 1.15)}"/>`;
  }

  // The fronds the low sun shines through: a line of light along the midrib.
  const glints = fronds
    .filter((f, i) => {
      const tip = f.rib[f.rib.length - 1];
      return i > 0 && (tip.x - crown.x) * o.sun > o.crown * 0.3 && tip.y < crown.y + o.crown * 0.55;
    })
    .map((f) => `M${f.rib.filter((p) => p.t > 0.08 && p.t < 0.8).map((p) => pt(p.x, p.y - 1.4 * scale)).join("L")}`)
    .join("");

  const xs = fronds.flatMap((f) => f.rib.map((p) => p.x));
  const ys = fronds.flatMap((f) => f.rib.map((p) => p.y));
  const pad = o.crown * 0.24;
  const minX = Math.min(...xs, -o.girth) - pad;
  const maxX = Math.max(...xs, o.girth) + pad;
  const minY = Math.min(...ys) - pad * 0.6;
  const width = maxX - minX;
  const height = -minY;
  const far = o.sun > 0 ? minX : maxX;
  const near = o.sun > 0 ? maxX : minX;

  const body =
    `<defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="${n1(far)}" y1="0" x2="${n1(near)}" y2="0"><stop offset="0" stop-color="#0d0522"/><stop offset=".55" stop-color="#1b0930"/><stop offset="1" stop-color="#3a1040"/></linearGradient>` +
    `<linearGradient id="r" gradientUnits="userSpaceOnUse" x1="0" y1="${n1(-o.height)}" x2="0" y2="0"><stop offset="0" stop-color="#ffb07a" stop-opacity=".75"/><stop offset=".7" stop-color="#ff6f8f" stop-opacity=".35"/><stop offset="1" stop-color="#ff6f8f" stop-opacity="0"/></linearGradient></defs>` +
    `<g fill="url(#g)"><path d="${trunk}"/>${nuts}${fronds.map((f) => `<path d="${f.d}"/>`).join("")}</g>` +
    `<path d="M${lit.join("L")}" fill="none" stroke="url(#r)" stroke-width="${n1(1.6 * scale)}" stroke-linecap="round"/>` +
    `<path d="${glints}" fill="none" stroke="#ff9d78" stroke-opacity=".38" stroke-width="${n1(1.1 * scale)}" stroke-linecap="round"/>`;
  return {
    svg: svgFile(width, height, body, `${n1(minX)} ${n1(minY)} ${n1(width)} ${n1(height)}`),
    width: Math.round(width),
    height: Math.round(height),
    // Where the trunk meets the ground, in percent of the width: the point
    // the palm sways around.
    foot: Math.round((-minX / width) * 1000) / 10,
  };
}

// Undergrowth for the corners of the picture: a low dune, saw palmettos and
// beach grass. Drawn for the right corner; the left one is its mirror image.
function thicket(seed) {
  const rand = rng(seed);
  const w = 760;
  const h = 300;
  const ground = (x) => h - 14 - 154 * smooth(x / w) ** 1.25;
  let d = `M0 ${h}`;
  for (let x = 0; x <= w; x += 20) d += `L${pt(x, ground(x))}`;
  d += `L${w} ${h}Z`;
  // Beach grass: tufts of long blades, thicker towards the corner.
  for (let i = 0; i < 46; i++) {
    const x = w * (0.06 + 0.94 * rand() ** 0.75);
    const y = ground(x) + 10;
    const blades = 6 + Math.floor(rand() * 7);
    const tall = lerp(34, 92, x / w) * (0.7 + rand() * 0.6);
    for (let b = 0; b < blades; b++) {
      const a = rad(-90 + (rand() - 0.5) * 88);
      const len = tall * (0.55 + rand() * 0.45);
      const cx = x + Math.cos(a) * len * 0.6;
      const cy = y + Math.sin(a) * len * 0.6;
      d += blade(x + (rand() - 0.5) * 8, y, cx, cy, cx + Math.cos(a) * len * 0.5 + (rand() - 0.5) * 8, cy + Math.sin(a) * len * 0.12 + len * 0.1, 3.4);
    }
  }
  // Saw palmettos: fans of stiff segments on short stalks.
  for (const [fx, size] of [
    [300, 0.75],
    [455, 1],
    [590, 1.25],
    [700, 1.05],
    [745, 1.5],
  ]) {
    const fans = 5 + Math.floor(rand() * 3);
    for (let f = 0; f < fans; f++) {
      const stalk = rad(-90 + (f / (fans - 1) - 0.5) * 130 + (rand() - 0.5) * 16);
      const reach = (34 + rand() * 30) * size;
      const x0 = fx + (rand() - 0.5) * 12;
      const y0 = ground(fx) + 12;
      const cx = x0 + Math.cos(stalk) * reach;
      const cy = y0 + Math.sin(stalk) * reach;
      d += ribbon(
        [
          { x: x0, y: y0 },
          { x: cx, y: cy },
        ],
        () => 1.5 * size,
      );
      const segments = 15 + Math.floor(rand() * 5);
      for (let s = 0; s < segments; s++) {
        const a = stalk + rad((s / (segments - 1) - 0.5) * 205);
        const len = (40 + rand() * 12) * size * (1 - 0.3 * Math.abs(s / (segments - 1) - 0.5));
        const mx = cx + Math.cos(a) * len * 0.6;
        const my = cy + Math.sin(a) * len * 0.6;
        d += blade(cx, cy, mx, my, cx + Math.cos(a) * len, cy + Math.sin(a) * len + len * 0.14, 6.5 * size);
      }
    }
  }
  const body =
    `<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#24093a"/><stop offset="1" stop-color="#0d0522"/></linearGradient></defs>` +
    `<path d="${d}" fill="url(#g)"/>`;
  return { svg: svgFile(w, h, body), width: w, height: h };
}

// ---------- Sky ----------

function stars(rand) {
  let out = "";
  for (let i = 0; i < 90; i++) {
    const y = rand() ** 1.6 * 330;
    out += `<circle cx="${n1(rand() * W)}" cy="${n1(y)}" r="${n1(0.5 + rand() * 1.1)}" opacity="${n1((0.25 + rand() * 0.7) * (1 - y / 360))}"/>`;
  }
  return `<g fill="#fff3fb">${out}</g>`;
}

function birds(rand) {
  let d = "";
  for (let i = 0; i < 7; i++) {
    const x = 1130 + i * 34 + rand() * 22;
    const y = 470 - i * 13 + rand() * 26;
    const s = 5 + rand() * 4;
    d += `M${pt(x - s, y + s * 0.2)}q${pt(s * 0.5, -s * 0.75)} ${pt(s, 0)}q${pt(s * 0.5, -s * 0.8)} ${pt(s, -s * 0.1)}`;
  }
  return `<path d="${d}" fill="none" stroke="#2a0d45" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" opacity=".8"/>`;
}

// Clouds are fractal noise cut off at a level: `cover` moves the level, a
// rectangle's gradient gives them their colour and thins them out towards
// its edges. The lower bank is lit from below by the sun.
function cloudFilter(id, { freq, seed, octaves, gain, cover, light }) {
  const shape =
    `<feTurbulence type="fractalNoise" baseFrequency="${freq}" numOctaves="${octaves}" seed="${seed}"/>` +
    `<feColorMatrix values="0 0 0 0 1 0 0 0 0 1 0 0 0 0 1 ${gain} 0 0 0 ${n1(-gain * cover)}" result="shape"/>`;
  const body = `<feComposite in="SourceGraphic" in2="shape" operator="in" result="body"/>`;
  const lit = light
    ? `<feGaussianBlur in="shape" stdDeviation="2.4" result="soft"/>` +
      `<feDiffuseLighting in="soft" surfaceScale="${light.depth}" diffuseConstant="1.15" lighting-color="${light.colour}" result="glow"><feDistantLight azimuth="${light.azimuth}" elevation="${light.elevation}"/></feDiffuseLighting>` +
      `<feComposite in="glow" in2="body" operator="in" result="rim"/>` +
      `<feBlend in="rim" in2="body" mode="screen"/>`
    : "";
  return `<filter id="${id}" filterUnits="userSpaceOnUse" x="0" y="0" width="${W}" height="${HORIZON}" color-interpolation-filters="sRGB">${shape}${body}${lit}</filter>`;
}

function sky() {
  const rand = rng(0x5ca1ab1e);
  const stops = [
    [0, "#110a3a"],
    [100, "#221260"],
    [215, "#4a1a82"],
    [320, "#84228f"],
    [415, "#c5318c"],
    [495, "#f4507c"],
    [570, "#ff7d62"],
    [635, "#ffa965"],
    [HORIZON, "#ffdc96"],
  ];
  const body =
    `<defs>` +
    `<linearGradient id="sky" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="${HORIZON}">${stops.map(([y, c]) => `<stop offset="${n1(y / HORIZON)}" stop-color="${c}"/>`).join("")}</linearGradient>` +
    `<radialGradient id="halo" gradientUnits="userSpaceOnUse" cx="${SUN.x}" cy="${SUN.y}" r="620"><stop offset="0" stop-color="#fff2c2" stop-opacity=".95"/><stop offset=".16" stop-color="#ffc878" stop-opacity=".62"/><stop offset=".45" stop-color="#ff7d6e" stop-opacity=".24"/><stop offset="1" stop-color="#ff5f8f" stop-opacity="0"/></radialGradient>` +
    `<radialGradient id="disc" gradientUnits="userSpaceOnUse" cx="${SUN.x}" cy="${SUN.y}" r="${SUN.r}"><stop offset="0" stop-color="#fffbe6"/><stop offset=".7" stop-color="#fff0b8"/><stop offset="1" stop-color="#ffd27a"/></radialGradient>` +
    `<linearGradient id="high" gradientUnits="userSpaceOnUse" x1="0" y1="30" x2="0" y2="470"><stop offset="0" stop-color="#b65bd0" stop-opacity="0"/><stop offset=".3" stop-color="#e06bc0" stop-opacity=".55"/><stop offset=".72" stop-color="#ff8fa0" stop-opacity=".8"/><stop offset="1" stop-color="#ffb48a" stop-opacity="0"/></linearGradient>` +
    `<linearGradient id="low" gradientUnits="userSpaceOnUse" x1="0" y1="360" x2="0" y2="668"><stop offset="0" stop-color="#6a2390" stop-opacity="0"/><stop offset=".3" stop-color="#7d2a94" stop-opacity=".9"/><stop offset=".75" stop-color="#b03a8c" stop-opacity=".9"/><stop offset="1" stop-color="#e0607c" stop-opacity="0"/></linearGradient>` +
    cloudFilter("wisps", { freq: ".0026 .017", seed: 23, octaves: 5, gain: 3.4, cover: 0.52 }) +
    cloudFilter("bank", {
      freq: ".0036 .016",
      seed: 4,
      octaves: 5,
      gain: 5.5,
      cover: 0.54,
      light: { depth: 14, colour: "#ffa070", azimuth: 78, elevation: 24 },
    }) +
    `</defs>` +
    `<rect width="${W}" height="${H}" fill="url(#sky)"/>` +
    stars(rand) +
    `<rect width="${W}" height="${HORIZON}" fill="url(#high)" filter="url(#wisps)"/>` +
    `<rect width="${W}" height="${HORIZON}" fill="url(#low)" filter="url(#bank)"/>` +
    `<rect width="${W}" height="${H}" fill="url(#halo)"/>` +
    `<circle cx="${SUN.x}" cy="${SUN.y}" r="${SUN.r}" fill="url(#disc)"/>` +
    birds(rand);
  return { svg: svgFile(W, H, body), width: W, height: H };
}

// ---------- City and water ----------

// A row of towers. Each is a closed outline; `lights` are its lit windows by
// colour, `edges` the sides the sun catches.
function skyline(rand, o) {
  let d = "";
  let edges = "";
  let faces = "";
  let beacons = "";
  let crowns = "";
  const lights = { warm: "", cool: "", pink: "" };
  let x = o.from;
  while (x < o.to) {
    const w = lerp(o.minW, o.maxW, rand());
    // Tallest downtown, lower towards the edges of the row.
    const centre = Math.max(0, 1 - Math.abs(x + w / 2 - o.peak) / o.spread) ** 1.3;
    const h = lerp(o.minH, o.maxH, centre * (0.45 + rand() * 0.55));
    const top = HORIZON - h;
    const right = x + w;
    const kind = rand();
    let roof = top;
    if (kind < 0.2 && h > 90) {
      // Setbacks under a mast, as on the towers of the 1930s.
      const s1 = w * 0.14;
      const s2 = w * 0.3;
      const t1 = top + h * 0.2;
      const t2 = top + h * 0.08;
      d += `M${pt(x, HORIZON)}V${n1(t1)}H${n1(x + s1)}V${n1(t2)}H${n1(x + s2)}V${n1(top)}H${n1(right - s2)}V${n1(t2)}H${n1(right - s1)}V${n1(t1)}H${n1(right)}V${HORIZON}Z`;
      const mid = x + w / 2;
      const mast = 18 + rand() * 30;
      d += `M${pt(mid - 1, top)}V${n1(top - mast)}H${n1(mid + 1)}V${n1(top)}Z`;
      beacons += `<circle cx="${n1(mid)}" cy="${n1(top - mast - 1.5)}" r="2"/>`;
      roof = t1;
    } else if (kind < 0.36) {
      // A slanted glass roof.
      const drop = 10 + rand() * 22;
      const high = rand() < 0.5;
      d += `M${pt(x, HORIZON)}V${n1(top + (high ? 0 : drop))}L${pt(right, top + (high ? drop : 0))}V${HORIZON}Z`;
      roof = top + drop;
    } else if (kind < 0.5 && w > 40) {
      // Two fins above the roof.
      const fin = w * 0.16;
      const up = 8 + rand() * 12;
      d += `M${pt(x, HORIZON)}V${n1(top - up)}H${n1(x + fin)}V${n1(top)}H${n1(right - fin)}V${n1(top - up)}H${n1(right)}V${HORIZON}Z`;
    } else {
      d += `M${pt(x, HORIZON)}V${n1(top)}H${n1(right)}V${HORIZON}Z`;
      if (rand() < 0.6) {
        // Plant room, sometimes an aerial.
        const pw = w * (0.3 + rand() * 0.3);
        const px = x + (w - pw) * rand();
        const ph = 5 + rand() * 7;
        d += `M${pt(px, top)}V${n1(top - ph)}H${n1(px + pw)}V${n1(top)}Z`;
        if (rand() < 0.4) {
          const ax = px + pw * rand();
          d += `M${pt(ax, top - ph)}V${n1(top - ph - 14 - rand() * 18)}H${n1(ax + 1.4)}V${n1(top - ph)}Z`;
        }
      }
    }
    if (o.windows) {
      // The side that faces the sun: a lighter face and a bright edge.
      const left = x + w / 2 > SUN.x;
      const face = w * (0.22 + rand() * 0.12);
      faces += `M${pt(left ? x : right - face, roof)}h${n1(face)}V${HORIZON}h${n1(-face)}Z`;
      edges += `M${pt(left ? x : right - 1.8, roof + 2)}v${n1(HORIZON - roof - 2)}h1.8V${n1(roof + 2)}Z`;
      if (rand() < 0.28) crowns += `M${pt(x + 3, roof + 3.5)}H${n1(right - 3)}`;
      const lit = 0.08 + rand() * 0.26;
      for (let wy = roof + 9; wy < HORIZON - 14; wy += 7.6) {
        // Whole floors stay dark, a few are lit from end to end.
        const floor = rand();
        if (floor < 0.22) continue;
        for (let wx = x + 4; wx < right - 5.5; wx += 5.4) {
          if (rand() > lit * (floor > 0.9 ? 2.6 : 1)) continue;
          const tint = rand();
          lights[tint < 0.86 ? "warm" : tint < 0.95 ? "cool" : "pink"] += `M${pt(wx, wy)}h2.5v3.6h-2.5z`;
        }
      }
    }
    x = right + (rand() < 0.3 ? 3 + rand() * 12 : -rand() * 6);
  }
  return { d, edges, faces, lights, beacons, crowns };
}

// A small palm for the far shore, drawn once and placed many times.
const miniPalm =
  `<symbol id="mp" overflow="visible"><path d="M0 0Q1.5-10 .6-21" stroke-width="1.5"/>` +
  `<path d="M.6-21q-5-5.5-11-1.5M.6-21q-6.5-8-12.5-6.5M.6-21q-2.5-8.5-7-10.5M.6-21q2.5-8.5 7.5-10M.6-21q6.5-7.5 12.5-5.5M.6-21q5.5-5 11-.5M.6-21q-1 4-5 6M.6-21q2 4 5.5 5.5" stroke-width="1.25"/></symbol>`;

function shorePalms(rand, from, to, y, count, size) {
  let out = "";
  for (let i = 0; i < count; i++) {
    const x = lerp(from, to, (i + rand() * 0.8) / count);
    const s = size * (0.7 + rand() * 0.7);
    out += `<use href="#mp" transform="translate(${n1(x)} ${n1(typeof y === "function" ? y(x) : y)}) scale(${rand() < 0.5 ? "-" : ""}${n1(s)} ${n1(s)})"/>`;
  }
  return out;
}

// The sun's path on the water: short streaks, sparse and fine at the
// horizon, wide and scattered towards the viewer.
function glitter(rand) {
  const bands = ["#fff6d0", "#ffd98a", "#ffab6e", "#ff7f8a"].map(() => "");
  for (let i = 0; i < 190; i++) {
    const depth = rand() ** 1.35;
    const y = HORIZON + 3 + depth * 300;
    const spread = 26 + depth * 210;
    const off = (rand() + rand() + rand() - 1.5) * spread * 0.8;
    const w = (5 + depth * 46) * (0.4 + rand());
    const h = 0.9 + depth * 2.6;
    const band = clamp(Math.floor(depth * 2.6 + (Math.abs(off) / spread) * 1.8), 0, 3);
    const x = SUN.x + off - w / 2;
    bands[band] += `M${pt(x, y)}q${pt(w / 2, -h)} ${pt(w, 0)}q${pt(-w / 2, h)} ${pt(-w, 0)}z`;
  }
  const colours = ["#fff6d0", "#ffd98a", "#ffab6e", "#ff7f8a"];
  const alpha = [0.95, 0.8, 0.62, 0.42];
  return bands.map((d, i) => `<path d="${d}" fill="${colours[i]}" opacity="${alpha[i]}"/>`).join("");
}

// A causeway from the city to the headland, low on piers with one raised
// span for boats; it crosses in front of the sun.
function causeway(from, to) {
  const deck = (x) => {
    const t = (x - from) / (to - from);
    return HORIZON - 9 - 15 * Math.exp(-(((t - 0.52) / 0.13) ** 2));
  };
  const top = [];
  for (let x = from; x <= to; x += 8) top.push({ x, y: deck(x) });
  let d = ribbon(top, () => 1.6);
  let lamps = "";
  for (let x = from + 14; x < to; x += 26) {
    d += `M${pt(x - 1.3, deck(x))}h2.6V${HORIZON}h-2.6Z`;
    if (Math.round((x - from) / 26) % 2 === 0) lamps += `<circle cx="${n1(x + 13)}" cy="${n1(deck(x + 13) - 4.5)}" r="1.1"/>`;
  }
  return { d, lamps };
}

function sailboat(x, y, s) {
  return (
    `<g transform="translate(${x} ${y}) scale(${s})">` +
    `<path d="M-19 0h38q-2 7-9 7h-21q-6 0-8-7ZM-1-46h1.6v46h-1.6ZM2.5-44q14 20 15 40h-15ZM-2.5-36q-11 16-14 32h14Z" fill="#200a3c"/>` +
    `<path d="M-15 12h30M-9 17h20M-4 22h9" stroke="#200a3c" stroke-width="2.2" stroke-linecap="round" opacity=".45"/></g>`
  );
}

function city() {
  const rand = rng(0x0bacf4b1);
  const far = skyline(rand, { from: -30, to: 905, minW: 22, maxW: 54, minH: 16, maxH: 190, peak: 520, spread: 760 });
  const mid = skyline(rand, { from: -30, to: 880, minW: 30, maxW: 66, minH: 30, maxH: 285, peak: 400, spread: 620 });
  const near = skyline(rand, { from: -30, to: 850, minW: 40, maxW: 86, minH: 34, maxH: 372, peak: 330, spread: 560, windows: true });
  const bridge = causeway(820, 1300);
  const hill = (x) => HORIZON - 4 - 66 * smooth((x - 1230) / 330) + 10 * Math.sin(x / 47);
  let headland = `M1220 ${HORIZON}`;
  for (let x = 1220; x <= 1620; x += 20) headland += `L${pt(x, hill(x))}`;
  headland += `L1620 ${HORIZON}Z`;
  const low = skyline(rand, { from: 1330, to: 1620, minW: 18, maxW: 40, minH: 60, maxH: 120, peak: 1560, spread: 320 });

  const depth = H - HORIZON;
  const body =
    `<defs>${miniPalm}` +
    `<linearGradient id="far" gradientUnits="userSpaceOnUse" x1="0" y1="${HORIZON - 190}" x2="0" y2="${HORIZON}"><stop offset="0" stop-color="#a23a8e"/><stop offset="1" stop-color="#ec6d86"/></linearGradient>` +
    `<linearGradient id="mid" gradientUnits="userSpaceOnUse" x1="0" y1="${HORIZON - 285}" x2="0" y2="${HORIZON}"><stop offset="0" stop-color="#5b1f80"/><stop offset="1" stop-color="#a03685"/></linearGradient>` +
    `<linearGradient id="near" gradientUnits="userSpaceOnUse" x1="0" y1="${HORIZON - 372}" x2="0" y2="${HORIZON}"><stop offset="0" stop-color="#22104e"/><stop offset=".7" stop-color="#2f1259"/><stop offset="1" stop-color="#4f1a66"/></linearGradient>` +
    `<linearGradient id="edge" gradientUnits="userSpaceOnUse" x1="0" y1="${HORIZON - 372}" x2="0" y2="${HORIZON}"><stop offset="0" stop-color="#ff8f8a" stop-opacity=".2"/><stop offset="1" stop-color="#ffbf80" stop-opacity=".85"/></linearGradient>` +
    `<linearGradient id="haze" gradientUnits="userSpaceOnUse" x1="0" y1="${HORIZON - 130}" x2="0" y2="${HORIZON}"><stop offset="0" stop-color="#ff8a70" stop-opacity="0"/><stop offset="1" stop-color="#ffb07a" stop-opacity=".5"/></linearGradient>` +
    `<linearGradient id="sea" gradientUnits="userSpaceOnUse" x1="0" y1="${HORIZON}" x2="0" y2="${H}"><stop offset="0" stop-color="#ff9f7c"/><stop offset=".05" stop-color="#e9638a"/><stop offset=".2" stop-color="#93308f"/><stop offset=".5" stop-color="#3f1a75"/><stop offset="1" stop-color="#150a3a"/></linearGradient>` +
    `<radialGradient id="shine" gradientUnits="userSpaceOnUse" cx="${SUN.x}" cy="${HORIZON}" r="420" gradientTransform="translate(0 ${HORIZON}) scale(1 .62) translate(0 ${-HORIZON})"><stop offset="0" stop-color="#ffe2a0" stop-opacity=".85"/><stop offset=".35" stop-color="#ff9a78" stop-opacity=".4"/><stop offset="1" stop-color="#ff7a8a" stop-opacity="0"/></radialGradient>` +
    `<linearGradient id="fade" gradientUnits="userSpaceOnUse" x1="0" y1="${HORIZON}" x2="0" y2="${HORIZON + 250}"><stop offset="0" stop-color="#fff" stop-opacity=".8"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>` +
    `<mask id="depth"><rect x="0" y="${HORIZON}" width="${W}" height="${depth}" fill="url(#fade)"/></mask>` +
    // The mirror image of the city breaks up on the swell.
    `<filter id="swell" filterUnits="userSpaceOnUse" x="0" y="${HORIZON}" width="${W}" height="${depth}"><feTurbulence type="fractalNoise" baseFrequency=".004 .11" numOctaves="2" seed="8"/><feDisplacementMap in="SourceGraphic" scale="22" xChannelSelector="R" yChannelSelector="G"/><feGaussianBlur stdDeviation="1.1 .5"/></filter>` +
    // Streaks of light and shadow on the surface.
    `<filter id="ripples" filterUnits="userSpaceOnUse" x="0" y="${HORIZON}" width="${W}" height="${depth}" color-interpolation-filters="sRGB"><feTurbulence type="fractalNoise" baseFrequency=".0035 .085" numOctaves="3" seed="15"/><feColorMatrix values="0 0 0 0 1 0 0 0 0 .78 0 0 0 0 .72 4.2 0 0 0 -2.25" result="streaks"/><feComposite in="streaks" in2="SourceGraphic" operator="in"/></filter>` +
    `<g id="skyline"><path d="${near.d}" fill="url(#near)"/><path d="${near.faces}" fill="#ff8f9a" opacity=".13"/><path d="${near.edges}" fill="url(#edge)"/>` +
    `<path d="${near.lights.warm}" fill="#ffdca6"/><path d="${near.lights.cool}" fill="#8af5ee"/><path d="${near.lights.pink}" fill="#ff9aca"/></g>` +
    `</defs>` +
    `<path d="${far.d}" fill="url(#far)" opacity=".8"/>` +
    `<path d="${headland}${low.d}" fill="#7a2a86"/>` +
    `<g fill="none" stroke="#7a2a86" stroke-linecap="round">${shorePalms(rand, 1240, 1600, hill, 16, 0.9)}</g>` +
    `<path d="${mid.d}" fill="url(#mid)"/>` +
    `<rect x="0" y="${HORIZON - 130}" width="${W}" height="130" fill="url(#haze)"/>` +
    `<path d="${bridge.d}" fill="#3d1668"/><g fill="#ffe2a8">${bridge.lamps}</g>` +
    `<use href="#skyline"/>` +
    `<path d="${near.crowns}" fill="none" stroke="#ff5fae" stroke-width="1.6" opacity=".9"/>` +
    `<g fill="#ff5568">${near.beacons}${mid.beacons}</g>` +
    // The waterfront: a sea wall, its lamps and a line of palms.
    `<path d="M-10 ${HORIZON - 7}H868q10 0 16 7H-10Z" fill="#1c0b40"/>` +
    `<g fill="none" stroke="#1c0b40" stroke-linecap="round">${shorePalms(rand, 10, 860, HORIZON - 6, 30, 0.95)}</g>` +
    `<rect x="0" y="${HORIZON}" width="${W}" height="${depth}" fill="url(#sea)"/>` +
    `<rect x="0" y="${HORIZON}" width="${W}" height="${depth}" fill="url(#shine)"/>` +
    `<g mask="url(#depth)"><g filter="url(#swell)" opacity=".85"><use href="#skyline" transform="translate(0 ${HORIZON * 2}) scale(1 -1)"/><path d="${headland}${low.d}" fill="#5a2180" transform="translate(0 ${HORIZON * 2}) scale(1 -1)"/></g></g>` +
    `<rect x="0" y="${HORIZON}" width="${W}" height="${depth}" fill="url(#fade)" filter="url(#ripples)" opacity=".5"/>` +
    glitter(rand) +
    sailboat(1180, HORIZON + 34, 0.62) +
    `<rect x="0" y="${HORIZON - 0.6}" width="${W}" height="1.6" fill="#ffd9b0" opacity=".55"/>`;
  return { svg: svgFile(W, H, body), width: W, height: H };
}

const layers = {
  sky: sky(),
  city: city(),
  // Sun to the right of palms a and b, to the left of c: they stand on
  // either side of it.
  palmA: palm(0xa11ce, { height: 880, lean: -150, girth: 19, crown: 285, fronds: 25, wind: 9, sun: -1 }),
  palmB: palm(0xb0b, { height: 640, lean: 95, girth: 16, crown: 235, fronds: 23, wind: 9, sun: -1 }),
  palmC: palm(0xc0c0, { height: 760, lean: 210, girth: 18, crown: 270, fronds: 24, wind: -8, sun: 1 }),
  thicket: thicket(0x7b1c),
};

const slug = (name) => name.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
// A hash of the content in the address, as for the stylesheet (assets.js).
const address = (name, svg) => `/assets/scene/${slug(name)}.svg?v=${createHash("sha256").update(svg).digest("hex").slice(0, 10)}`;

export default {
  ...Object.fromEntries(Object.entries(layers).map(([name, { svg, ...size }]) => [name, { ...size, src: address(name, svg) }])),
  files: Object.entries(layers).map(([name, { svg }]) => ({ name: slug(name), svg })),
};
