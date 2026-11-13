// The hero's dusk skyline, drawn at build time from a fixed seed: no image
// files in the repository, and the same SVG on every build.
const W = 1600;
const H = 1000;
const HORIZON = 700;
const SUN = { x: 1000, y: 560, r: 250 };

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

const r1 = (n) => Math.round(n * 10) / 10;

function stars(rand) {
  let out = "";
  for (let i = 0; i < 70; i++) {
    const x = r1(rand() * W);
    const y = r1(rand() * 360);
    const r = r1(0.6 + rand() * 1.3);
    const cls = rand() < 0.3 ? ' class="twinkle"' : "";
    out += `<circle cx="${x}" cy="${y}" r="${r}"${cls} style="--d:${r1(rand() * 4)}s"/>`;
  }
  return `<g fill="#ffe9f7" opacity=".75">${out}</g>`;
}

// A row of towers on the horizon: an outline path and, optionally, lit
// windows.
function skyline(rand, { minH, maxH, minW, maxW, from, to, windows }) {
  let x = from;
  let d = `M${from} ${HORIZON}`;
  let lights = "";
  let beacons = "";
  while (x < to) {
    const w = minW + rand() * (maxW - minW);
    // Taller towers near the city centre, lower towards the edges.
    const centre = 1 - Math.min(1, Math.abs(x - 470) / 620);
    const h = minH + (maxH - minH) * (0.25 + 0.75 * centre) * (0.35 + rand() * 0.65);
    const top = HORIZON - h;
    const style = rand();
    if (style < 0.18) {
      // Stepped top.
      const inset = w * 0.2;
      d += `L${r1(x)} ${r1(top + 22)}L${r1(x + inset)} ${r1(top + 22)}L${r1(x + inset)} ${r1(top)}`;
      d += `L${r1(x + w - inset)} ${r1(top)}L${r1(x + w - inset)} ${r1(top + 22)}L${r1(x + w)} ${r1(top + 22)}`;
    } else if (style < 0.3) {
      // Spire.
      const mid = x + w / 2;
      d += `L${r1(x)} ${r1(top)}L${r1(mid - 2)} ${r1(top)}L${r1(mid)} ${r1(top - 46)}L${r1(mid + 2)} ${r1(top)}L${r1(x + w)} ${r1(top)}`;
      beacons += `<circle cx="${r1(mid)}" cy="${r1(top - 48)}" r="2.6" class="beacon" style="--d:${r1(rand() * 2)}s"/>`;
    } else if (style < 0.4) {
      // Slanted roof.
      d += `L${r1(x)} ${r1(top + 30)}L${r1(x + w)} ${r1(top)}`;
    } else {
      d += `L${r1(x)} ${r1(top)}L${r1(x + w)} ${r1(top)}`;
    }
    d += `L${r1(x + w)} ${HORIZON}`;
    if (windows) {
      const palette = ["#3ff3e6", "#ff5fae", "#ffc46b", "#b98cff"];
      const tint = palette[Math.floor(rand() * palette.length)];
      for (let wy = top + 34; wy < HORIZON - 10; wy += 14) {
        for (let wx = x + 5; wx < x + w - 7; wx += 9) {
          if (rand() < 0.16) {
            lights += `<rect x="${r1(wx)}" y="${r1(wy)}" width="4" height="6" fill="${tint}"/>`;
          }
        }
      }
    }
    x += w + (rand() < 0.25 ? 4 + rand() * 10 : 0);
  }
  d += `L${r1(x)} ${HORIZON}Z`;
  return { d, lights, beacons };
}

// A palm: a tapering curved trunk and drooping serrated fronds.
function palm(rand, { x, lean, height, scale = 1 }) {
  const base = { x, y: H + 10 };
  const crown = { x: x + lean, y: H - height };
  const ctrl = { x: x + lean * 0.15, y: H - height * 0.55 };
  const pts = [];
  const steps = 24;
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    const px = (1 - t) ** 2 * base.x + 2 * (1 - t) * t * ctrl.x + t * t * crown.x;
    const py = (1 - t) ** 2 * base.y + 2 * (1 - t) * t * ctrl.y + t * t * crown.y;
    const w = (24 - 13 * t) * scale;
    pts.push({ px, py, w });
  }
  const left = pts.map((p) => `${r1(p.px - p.w / 2)} ${r1(p.py)}`);
  const right = pts.map((p) => `${r1(p.px + p.w / 2)} ${r1(p.py)}`).reverse();
  let out = `<path d="M${left.join("L")}L${right.join("L")}Z"/>`;
  // Trunk rings.
  for (let i = 2; i < steps; i += 2) {
    const p = pts[i];
    out += `<path d="M${r1(p.px - p.w / 2)} ${r1(p.py)}l${r1(p.w)} -3" stroke="#0a0414" stroke-width="2" fill="none"/>`;
  }
  const angles = [-175, -152, -126, -98, -74, -50, -24, 0, 200, 165];
  for (const deg of angles) {
    const a = ((deg + (rand() - 0.5) * 14) * Math.PI) / 180;
    const len = (170 + rand() * 80) * scale;
    const dir = { x: Math.cos(a), y: Math.sin(a) };
    const end = { x: crown.x + dir.x * len, y: crown.y + dir.y * len * 0.45 + len * 0.62 };
    const c = { x: crown.x + dir.x * len * 0.6, y: crown.y + dir.y * len * 0.6 - len * 0.22 };
    const rib = `M${r1(crown.x)} ${r1(crown.y)}Q${r1(c.x)} ${r1(c.y)} ${r1(end.x)} ${r1(end.y)}`;
    let leaflets = "";
    const n = 36;
    for (let i = 2; i <= n; i++) {
      const t = i / n;
      const px = (1 - t) ** 2 * crown.x + 2 * (1 - t) * t * c.x + t * t * end.x;
      const py = (1 - t) ** 2 * crown.y + 2 * (1 - t) * t * c.y + t * t * end.y;
      const tx = 2 * (1 - t) * (c.x - crown.x) + 2 * t * (end.x - c.x);
      const ty = 2 * (1 - t) * (c.y - crown.y) + 2 * t * (end.y - c.y);
      const l = Math.hypot(tx, ty) || 1;
      const ux = tx / l;
      const uy = ty / l;
      // Leaflets on both sides of the rib, swept towards the tip and
      // hanging down, longest in the middle of the frond.
      const size = Math.sin(Math.PI * Math.min(1, t * 1.1)) * 46 * scale;
      for (const side of [1, -1]) {
        const lx = ux * 0.75 - uy * side * 0.55;
        const ly = uy * 0.75 + ux * side * 0.55 + 0.6;
        const m = Math.hypot(lx, ly);
        leaflets += `M${r1(px)} ${r1(py)}l${r1((lx / m) * size)} ${r1((ly / m) * size)}`;
      }
    }
    out += `<path d="${rib}" fill="none" stroke="#07030d" stroke-width="${r1(5 * scale)}" stroke-linecap="round"/>`;
    out += `<path d="${leaflets}" fill="none" stroke="#07030d" stroke-width="${r1(4.2 * scale)}" stroke-linecap="round"/>`;
  }
  return out;
}

function reflection(rand) {
  let out = "";
  const colours = ["#ffd36e", "#ffa04d", "#ff6f6a", "#ff3f8e", "#d93fb0", "#9b3fd0"];
  for (let i = 0; i < 18; i++) {
    const y = HORIZON + 8 + i * 13 + i * i * 0.45;
    const w = SUN.r * 1.55 * (1 - i / 24) * (0.75 + rand() * 0.4);
    const x = SUN.x - w / 2 + (rand() - 0.5) * 24;
    const colour = colours[Math.min(colours.length - 1, Math.floor(i / 3))];
    out += `<rect class="ripple" style="--d:${r1(i * 0.37)}s" x="${r1(x)}" y="${r1(y)}" width="${r1(w)}" height="${r1(3 + i * 0.45)}" rx="3" fill="${colour}" opacity="${r1(0.9 - i * 0.04)}"/>`;
  }
  return out;
}

// Streaks of the city's lights on the water.
function cityLights(rand) {
  let out = "";
  const palette = ["#3ff3e6", "#ff5fae", "#ffc46b", "#b98cff"];
  for (let i = 0; i < 60; i++) {
    const x = 60 + rand() * 780;
    const y = HORIZON + 6 + rand() * 120;
    const w = 6 + rand() * 26;
    out += `<rect x="${r1(x)}" y="${r1(y)}" width="${r1(w)}" height="2" fill="${palette[i % 4]}" opacity="${r1(0.15 + rand() * 0.35)}"/>`;
  }
  return out;
}

// The headland on the right, behind which the coast bends away.
function headland() {
  return `M1080 ${HORIZON}C1200 ${HORIZON - 20} 1280 ${HORIZON - 52} 1380 ${HORIZON - 58}S1540 ${HORIZON - 84} 1620 ${HORIZON - 80}L1620 ${HORIZON}Z`;
}

const rand = rng(0x0bacf4b1);
const far = skyline(rand, { minH: 30, maxH: 240, minW: 26, maxW: 60, from: -20, to: 1060, windows: false });
const near = skyline(rand, { minH: 30, maxH: 320, minW: 34, maxW: 78, from: 40, to: 860, windows: true });
const starField = stars(rand);
const palms =
  palm(rand, { x: 110, lean: 120, height: 560 }) +
  palm(rand, { x: 260, lean: 40, height: 420, scale: 0.8 }) +
  palm(rand, { x: 1520, lean: -150, height: 600 }) +
  palm(rand, { x: 1400, lean: -60, height: 400, scale: 0.75 });

const svg = `<svg class="scene" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMax slice" aria-hidden="true" focusable="false">
<defs>
<linearGradient id="sun" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffe27a"/><stop offset=".45" stop-color="#ff8a3d"/><stop offset=".8" stop-color="#ff2f7e"/><stop offset="1" stop-color="#c51f8f"/></linearGradient>
<radialGradient id="glow"><stop offset="0" stop-color="#ff6a7f" stop-opacity=".75"/><stop offset=".45" stop-color="#ff3f8e" stop-opacity=".25"/><stop offset="1" stop-color="#ff3f8e" stop-opacity="0"/></radialGradient>
<linearGradient id="sea" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3b1366"/><stop offset=".35" stop-color="#1c0b3a"/><stop offset="1" stop-color="#07030f"/></linearGradient>
<linearGradient id="haze" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff5fa8" stop-opacity="0"/><stop offset="1" stop-color="#ff7a59" stop-opacity=".45"/></linearGradient>
<mask id="bands"><rect x="0" y="0" width="${W}" height="${H}" fill="#fff"/>${Array.from({ length: 8 }, (_, i) => `<rect x="0" y="${SUN.y + 10 + i * 26}" width="${W}" height="${4 + i * 2.2}" fill="#000"/>`).join("")}</mask>
<clipPath id="above"><rect x="0" y="0" width="${W}" height="${HORIZON}"/></clipPath>
</defs>
<g class="layer layer-stars">${starField}</g>
<g class="layer layer-sun">
<circle cx="${SUN.x}" cy="${SUN.y}" r="${SUN.r * 2.6}" fill="url(#glow)"/>
<circle cx="${SUN.x}" cy="${SUN.y}" r="${SUN.r}" fill="url(#sun)" mask="url(#bands)" clip-path="url(#above)"/>
</g>
<rect x="0" y="${HORIZON - 220}" width="${W}" height="220" fill="url(#haze)"/>
<g class="layer layer-far"><path d="${headland()}" fill="#2d0f52"/><path d="${far.d}" fill="#4a1b72" opacity=".85"/></g>
<g class="layer layer-near"><path d="${near.d}" fill="#1a0933"/><g class="windows">${near.lights}</g><g fill="#ff3b5c">${near.beacons}</g></g>
<rect x="0" y="${HORIZON}" width="${W}" height="${H - HORIZON}" fill="url(#sea)"/>
<g class="layer layer-sea">${reflection(rand)}${cityLights(rand)}</g>
<rect x="0" y="${HORIZON - 1}" width="${W}" height="2" fill="#3ff3e6" class="horizon"/>
<g class="layer layer-palms" fill="#07030d">${palms}</g>
</svg>`;

export default { svg };
