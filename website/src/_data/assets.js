// URLs of the site's own stylesheet and script with a hash of their content.
// Browsers and the CDN keep assets for hours, pages for minutes: without the
// hash a deployment pairs new pages with the stylesheet of the previous one.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

function versioned(name) {
  const content = readFileSync(path.resolve(import.meta.dirname, "../assets", name));
  return `/assets/${name}?v=${createHash("sha256").update(content).digest("hex").slice(0, 10)}`;
}

export default {
  css: versioned("site.css"),
  js: versioned("site.js"),
};
