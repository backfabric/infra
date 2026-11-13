// Client-side behaviour of backfabric.dev: the cloth behind the hero and the
// finale (WebGL), blocks that come in as they are scrolled to, the stack's
// active layer, the terminal that types. No dependencies, and nothing newer
// than requestAnimationFrame and WebGL 1. Every page reads the same without
// it: the stylesheet hides nothing until the last line here has run.
const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
const clamp = (n) => Math.min(Math.max(n, 0), 1);

// Whatever depends on where the page is scrolled to registers here and runs
// once per frame in which the page moved.
const onMove = [];
let queued = false;
function moved() {
  queued = false;
  for (const run of onMove) run();
}
function queue() {
  if (queued) return;
  queued = true;
  requestAnimationFrame(moved);
}

// ---------- Blocks come in as they are scrolled to ----------

let waiting = [...document.querySelectorAll(".reveal")];
onMove.push(() => {
  waiting = waiting.filter((block) => {
    if (block.getBoundingClientRect().top > innerHeight * 0.94) return true;
    block.classList.add("is-in");
    return false;
  });
});

// ---------- The cloth ----------

// A plane of woven threads that runs to a horizon, under a sky that goes
// from sunset (uNight 0) to night (1). Sines only: cheap enough for a phone.
const FRAGMENT = `#extension GL_OES_standard_derivatives : enable
precision highp float;
uniform vec2 uRes;
uniform float uTime;
uniform vec2 uPointer;
uniform float uHorizon;
uniform float uNight;
uniform float uSeed;
uniform float uRoom;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}
float hash1(float x) { return fract(sin(x * 127.1) * 43758.5453); }
mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }

// Cloth coordinates: the plane, pulled about by slow waves. Threads run
// along x, at constant y.
vec2 cloth(vec2 p, float t) {
  vec2 q = rot(0.42) * p;
  q += 0.30 * sin(q.yx * vec2(0.9, 1.1) + vec2(t * 0.10, -t * 0.08) + uSeed);
  q += 0.16 * sin(q.yx * vec2(2.1, 1.7) + vec2(-t * 0.12, t * 0.07) + 1.7 + uSeed);
  q += 0.06 * sin(q.yx * vec2(4.3, 4.9) + vec2(t * 0.15, t * 0.11) + 4.1);
  return q;
}
float height(vec2 q, float t) {
  float h = 0.6 * sin(q.x * 2.3 + 0.9 * sin(q.y * 0.8 + t * 0.07));
  h += 0.25 * sin(q.x * 5.3 + q.y * 1.4 + 1.3 * sin(q.y * 1.7 - t * 0.05));
  h += 0.08 * sin(q.x * 11.0 - q.y * 3.0 + t * 0.1);
  return h;
}
// y: 0 at the horizon, 1 at the top.
vec3 sky(float y) {
  vec3 day = mix(vec3(1.0, 0.74, 0.40), vec3(1.0, 0.34, 0.42), smoothstep(0.0, 0.16, y));
  day = mix(day, vec3(0.62, 0.14, 0.62), smoothstep(0.08, 0.40, y));
  day = mix(day, vec3(0.17, 0.07, 0.44), smoothstep(0.28, 0.72, y));
  day = mix(day, vec3(0.035, 0.02, 0.12), smoothstep(0.6, 1.1, y));
  vec3 night = mix(vec3(0.20, 0.12, 0.52), vec3(0.07, 0.04, 0.24), smoothstep(0.0, 0.35, y));
  night = mix(night, vec3(0.027, 0.02, 0.10), smoothstep(0.25, 0.9, y));
  night += vec3(0.05, 0.5, 0.55) * exp(-y * 9.0) * 0.35;
  return mix(day, night, uNight);
}

void main() {
  vec2 uv = gl_FragCoord.xy / uRes;
  float aspect = uRes.x / uRes.y;
  float t = uTime;
  float sunUp = 1.0 - uNight;
  vec2 sun = vec2(0.72 + uPointer.x * 0.02, uHorizon + 0.006 - uNight * 0.16);
  vec3 col;

  float below = uHorizon - uv.y;
  if (below > 0.0) {
    // The plane of cloth, seen from just above it.
    float d = 0.34 / below;
    vec2 p = vec2((uv.x - 0.5) * aspect * d * 1.9, d + t * 0.03);
    vec2 q = cloth(p, t);
    float e = 0.01;
    float h = height(q, t);
    float hx = height(cloth(p + vec2(e, 0.0), t), t);
    float hy = height(cloth(p + vec2(0.0, e), t), t);
    vec3 n = normalize(vec3((h - hx) / e, (h - hy) / e, 2.2));

    vec3 v = normalize(vec3(-(uv.x - 0.5) * aspect * 0.6, -1.0, 0.42));
    vec3 l = normalize(vec3((sun.x - uv.x) * aspect * 1.4 + uPointer.x * 0.25, 1.0, 0.16 + uPointer.y * 0.08));
    float diff = max(dot(n, l), 0.0);
    float spec = pow(max(dot(n, normalize(l + v)), 0.0), 34.0);
    float fres = pow(1.0 - max(dot(n, v), 0.0), 3.0);

    // Threads with dark between them. Each catches the light differently,
    // and where they get too fine to tell apart they merge into a sheen.
    float f = 260.0;
    float id = floor(q.y * f / 6.2832);
    float seen = clamp(1.5 - fwidth(q.y) * f * 0.9, 0.0, 1.0);
    float line = smoothstep(0.30, 0.92, 0.5 + 0.5 * sin(q.y * f));
    float strand = mix(0.36, line * (0.5 + 0.95 * hash1(id)), seen);
    float weft = mix(0.5, 0.5 + 0.5 * sin(q.x * 70.0), clamp(1.5 - fwidth(q.x) * 70.0, 0.0, 1.0));

    // Lights that travel along a few of the threads.
    float lit = step(0.93, hash1(id + 7.0));
    float along = fract(q.x * 0.11 + t * (0.03 + 0.03 * hash1(id + 3.0)) + hash1(id));
    float bead = lit * exp(-pow((along - 0.5) * 34.0, 2.0)) * seen * line;

    vec3 base = mix(vec3(0.20, 0.07, 0.48), vec3(0.95, 0.16, 0.5), smoothstep(-0.6, 0.7, h));
    base = mix(base, mix(vec3(0.07, 0.06, 0.36), vec3(0.22, 0.20, 0.85), smoothstep(-0.6, 0.7, h)), uNight);
    vec3 warm = mix(vec3(1.0, 0.48, 0.25), vec3(0.15, 0.75, 0.9), uNight);
    col = base * (0.10 + 0.5 * diff);
    col += warm * diff * diff * mix(0.55, 0.30, uNight);
    col += sky(0.03) * spec * mix(1.9, 2.6, uNight);
    col += sky(0.22) * fres * 0.35;
    col += vec3(0.1, 0.85, 0.9) * pow(max(0.1 - n.x * 0.8, 0.0), 2.0) * 0.16;
    col *= 0.22 + 1.3 * strand;
    col *= 0.88 + 0.24 * weft;
    col *= 0.4 + 0.6 * smoothstep(-0.8, 0.3, h);
    col += mix(vec3(1.0, 0.85, 0.6), vec3(0.6, 1.0, 0.95), uNight) * bead * 1.4;

    // Haze towards the horizon; the page's dark near the viewer; and room
    // for the words: on the left, or all over where they span a phone.
    float haze = 1.0 - smoothstep(0.0, 0.3, below);
    col = mix(col, sky(0.02) * 0.9, pow(haze, 5.0) * 0.85);
    col *= smoothstep(-0.02, 0.26, uv.y);
    float side = smoothstep(0.28, 0.78, uv.x + 0.3 * below);
    float phone = smoothstep(1.3, 0.75, aspect);
    col *= mix(1.0, mix(0.2, 1.0, mix(side, 0.3 * smoothstep(0.0, 0.5, haze) + 0.25, phone)), uRoom);
  } else {
    float y = -below / max(1.0 - uHorizon, 0.001);
    col = sky(y);
    vec2 away = (uv - sun) * vec2(aspect, 1.0);
    float r = length(away);
    col += vec3(1.0, 0.88, 0.66) * smoothstep(0.066, 0.056, r) * sunUp;
    col += vec3(1.0, 0.55, 0.3) * exp(-r * 5.0) * 0.7 * sunUp;
    // Stars come out as the sun goes.
    vec2 cell = floor(gl_FragCoord.xy / 2.5);
    float star = step(0.9965, hash(cell)) * (0.4 + 0.6 * hash(cell + 3.1));
    col += vec3(0.9, 0.9, 1.0) * star * smoothstep(0.15, 0.7, y) * (0.25 + 0.75 * uNight);
  }
  col += mix(vec3(1.0, 0.5, 0.3), vec3(0.2, 0.7, 0.9), uNight) * exp(-abs(below) * 26.0) * mix(0.28, 0.14, uNight);

  col += (hash(gl_FragCoord.xy + fract(t)) - 0.5) * 0.028;
  gl_FragColor = vec4(pow(max(col, 0.0), vec3(0.92)), 1.0);
}`;

function cloth(canvas) {
  const gl = canvas.getContext("webgl", { antialias: false, alpha: false, powerPreference: "high-performance" });
  if (!gl || !gl.getExtension("OES_standard_derivatives")) return;
  const shader = (type, source) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, source);
    gl.compileShader(s);
    return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
  };
  const vertex = shader(gl.VERTEX_SHADER, "attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}");
  const fragment = shader(gl.FRAGMENT_SHADER, FRAGMENT);
  if (!vertex || !fragment) return;
  const program = gl.createProgram();
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return;
  gl.useProgram(program);
  // One triangle that covers the canvas.
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  const uniform = Object.fromEntries(
    ["uRes", "uTime", "uPointer", "uHorizon", "uNight", "uSeed", "uRoom"].map((name) => [name, gl.getUniformLocation(program, name)]),
  );

  const { seed = "0", night = "0", room = "0", horizon = "0.6", horizonBelow, sets } = canvas.dataset;
  const anchor = horizonBelow ? document.querySelector(horizonBelow) : null;
  const pointer = { x: 0, y: 0, tx: 0, ty: 0 };
  let time = Number(seed) * 40;
  let last = 0;
  let frame = 0;

  const draw = (now = 0) => {
    frame = 0;
    if (!reduced && last) time += Math.min((now - last) / 1000, 0.1);
    last = now;
    const box = canvas.getBoundingClientRect();
    const dpr = Math.min(devicePixelRatio || 1, 1.75);
    const w = Math.round(box.width * dpr);
    const h = Math.round(box.height * dpr);
    if (!w || !h) return;
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
      gl.viewport(0, 0, w, h);
    }
    // The horizon sits a little below the anchor (the wordmark), wherever
    // the layout puts it.
    let line = Number(horizon);
    if (anchor) {
      const gap = Math.max(72, box.height * 0.1);
      line = 1 - (anchor.getBoundingClientRect().bottom - box.top + gap) / box.height;
    }
    // Scrolled away, the sun goes down.
    const gone = sets && !reduced ? clamp(-box.top / (box.height * 0.8)) : 0;
    pointer.x += (pointer.tx - pointer.x) * 0.05;
    pointer.y += (pointer.ty - pointer.y) * 0.05;
    gl.uniform2f(uniform.uRes, w, h);
    gl.uniform1f(uniform.uTime, time);
    gl.uniform2f(uniform.uPointer, pointer.x, pointer.y);
    gl.uniform1f(uniform.uHorizon, Math.min(Math.max(line, 0.2), 0.9));
    gl.uniform1f(uniform.uNight, Math.min(Number(night) + gone, 1));
    gl.uniform1f(uniform.uSeed, Number(seed));
    gl.uniform1f(uniform.uRoom, Number(room));
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    canvas.dataset.live = "";
    // Keeps moving only while it can be seen.
    const seen = box.bottom > 0 && box.top < innerHeight && !document.hidden;
    if (seen && !reduced) frame = requestAnimationFrame(draw);
  };
  const wake = () => {
    if (frame) return;
    last = 0;
    frame = requestAnimationFrame(draw);
  };

  onMove.push(wake);
  document.addEventListener("visibilitychange", wake);
  document.fonts?.ready.then(wake);
  if (!reduced) {
    addEventListener("pointermove", (event) => {
      pointer.tx = (event.clientX / innerWidth) * 2 - 1;
      pointer.ty = 1 - (event.clientY / innerHeight) * 2;
    });
  }
}
for (const canvas of document.querySelectorAll("canvas[data-cloth]")) {
  try {
    cloth(canvas);
  } catch {
    // The stylesheet's gradient stays.
  }
}

// ---------- Cards: a light under the pointer ----------

for (const card of document.querySelectorAll("[data-glow]")) {
  card.addEventListener("pointermove", (event) => {
    const box = card.getBoundingClientRect();
    card.style.setProperty("--mx", `${event.clientX - box.left}px`);
    card.style.setProperty("--my", `${event.clientY - box.top}px`);
  });
}

// ---------- The statement: lit word by word as it is scrolled through ----------

const statement = document.querySelector("[data-read]");
if (statement && !reduced) {
  const words = statement.children.length;
  onMove.push(() => {
    const box = statement.getBoundingClientRect();
    const through = clamp((innerHeight * 0.88 - box.top) / (innerHeight * 0.5 + box.height));
    statement.style.setProperty("--read", (through * (words + 6)).toFixed(2));
  });
}

// ---------- The stack: the layer being read lights up in the tower ----------

const tower = document.querySelector("[data-tower]");
if (tower) {
  const layers = [...document.querySelectorAll("[data-layer-text]")];
  onMove.push(() => {
    // The layer nearest the middle of the screen.
    let nearest = layers[0];
    let distance = Infinity;
    for (const layer of layers) {
      const box = layer.getBoundingClientRect();
      const d = Math.abs((box.top + box.bottom - innerHeight) / 2);
      if (d < distance) {
        distance = d;
        nearest = layer;
      }
    }
    if (tower.dataset.active === nearest.dataset.layerText) return;
    tower.dataset.active = nearest.dataset.layerText;
    for (const layer of layers) layer.classList.toggle("is-active", layer === nearest);
  });
}

// ---------- The terminal: commands are typed when it comes into view ----------

for (const terminal of document.querySelectorAll("[data-typed]")) {
  let delay = 300;
  for (const line of terminal.querySelectorAll("[data-line]")) {
    const typed = line.querySelector("[data-cmd]");
    line.style.setProperty("--at", `${delay}ms`);
    if (typed) {
      const length = typed.textContent.length;
      typed.style.setProperty("--n", length);
      typed.style.setProperty("--for", `${length * 26}ms`);
      delay += length * 26 + 380;
    } else {
      delay += 160;
    }
  }
  onMove.push(() => {
    if (terminal.getBoundingClientRect().top < innerHeight * 0.7) terminal.classList.add("is-typing");
  });
}

// ---------- The bar: solid once the page has moved ----------

const bar = document.querySelector("[data-bar]");
if (bar) onMove.push(() => bar.classList.toggle("is-moved", scrollY > 24));

// ---------- Go ----------

addEventListener("scroll", queue, { passive: true });
addEventListener("resize", queue);
addEventListener("load", queue);
moved();
// Only now may the stylesheet hide what the script brings in.
document.documentElement.classList.add("js");
