// Client-side behaviour of backfabric.dev: the hero's picture moves in depth
// with the scroll and the pointer, blocks come in as they are scrolled to,
// the stack lights the layer being read, the terminal types. No dependencies,
// and nothing newer than requestAnimationFrame. Every page reads the same
// without it: the stylesheet hides nothing until the last line here has run.
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

// ---------- The picture: its layers move apart ----------

// --p runs from 0 to 1 while the hero leaves the screen, --px and --py follow
// the pointer from -1 to 1; the stylesheet turns them into offsets by layer.
const scene = document.querySelector("[data-scene]");
if (scene && !reduced) {
  onMove.push(() => {
    const box = scene.getBoundingClientRect();
    if (box.bottom > 0) scene.style.setProperty("--p", clamp(-box.top / box.height).toFixed(3));
  });
  scene.addEventListener("pointermove", (event) => {
    scene.style.setProperty("--px", ((event.clientX / innerWidth) * 2 - 1).toFixed(3));
    scene.style.setProperty("--py", ((event.clientY / innerHeight) * 2 - 1).toFixed(3));
  });
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
