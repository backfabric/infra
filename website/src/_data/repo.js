// The repository's own documentation, read in place at build time: the
// README, the template's README, the runbooks in docs/ and the ADRs in
// docs/adr/. Nothing is copied into website/.
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import yaml from "js-yaml";
import markdownIt from "markdown-it";

import site from "./site.js";

const root = path.resolve(import.meta.dirname, "../../..");

// Pages rendered from Markdown files of the repository, by repository path.
const pages = new Map();

// `title` replaces the file's own heading where that is a repository name.
function addPage(source, url, kind, title) {
  pages.set(source, { source, url, kind, title });
}

addPage("README.md", "/docs/overview/", "overview", "Overview");
addPage("nix/templates/default/README.md", "/docs/template/", "template", "The private repository template");
for (const name of readdirSync(path.join(root, "docs")).sort()) {
  if (name.endsWith(".md")) {
    addPage(`docs/${name}`, `/docs/${name.slice(0, -3)}/`, "runbook");
  }
}
for (const name of readdirSync(path.join(root, "docs/adr")).sort()) {
  if (name.endsWith(".md")) {
    addPage(`docs/adr/${name}`, `/docs/adr/${name.slice(0, -3)}/`, "adr");
  }
}

// GitHub's heading anchors, so that links like `secrets.md#admin-keys` keep
// working on the site.
function slug(text, seen) {
  const base = text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\p{M}\- ]/gu, "")
    .replace(/ /g, "-");
  const count = seen.get(base) ?? 0;
  seen.set(base, count + 1);
  return count ? `${base}-${count}` : base;
}

// A link in a Markdown file, resolved against the file's directory: to the
// page rendered from the target, or else to the file on GitHub.
function rewrite(href, source) {
  if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith("#") || href.startsWith("//")) {
    return href;
  }
  const [target, fragment] = href.split("#", 2);
  const isDir = target.endsWith("/");
  const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(source), target));
  const hash = fragment === undefined ? "" : `#${fragment}`;
  const page = pages.get(resolved);
  if (page) return page.url + hash;
  if (resolved === "docs/adr" || resolved === "docs") return `/docs/${hash || "#decisions"}`;
  return `${site.repo}/${isDir ? "tree" : "blob"}/main/${resolved}${hash}`;
}

const md = markdownIt({ html: false, linkify: false, typographer: false });

md.core.ruler.push("github_anchors", (state) => {
  const seen = new Map();
  const tokens = state.tokens;
  for (let i = 0; i < tokens.length; i++) {
    if (tokens[i].type === "heading_open") {
      const text = tokens[i + 1].children
        .filter((t) => t.type === "text" || t.type === "code_inline")
        .map((t) => t.content)
        .join("");
      tokens[i].attrSet("id", slug(text, seen));
    }
  }
});

const defaultLink =
  md.renderer.rules.link_open ?? ((tokens, idx, options, env, self) => self.renderToken(tokens, idx, options));
md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
  const href = tokens[idx].attrGet("href");
  if (href) tokens[idx].attrSet("href", rewrite(href, env.source));
  return defaultLink(tokens, idx, options, env, self);
};
md.renderer.rules.table_open = () => '<div class="table-scroll" tabindex="0"><table>\n';
md.renderer.rules.table_close = () => "</table></div>\n";

function frontMatter(text) {
  const match = /^---\n([\s\S]*?)\n---\n/.exec(text);
  if (!match) return { data: {}, body: text };
  return { data: yaml.load(match[1]) ?? {}, body: text.slice(match[0].length) };
}

function plain(markdown) {
  return markdown
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[`*_]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function load(page) {
  const text = readFileSync(path.join(root, page.source), "utf8");
  const { data, body } = frontMatter(text);
  const heading = /^# (.+)$/m.exec(body);
  const title = page.title ?? (heading ? plain(heading[1]) : page.source);
  // The title is the page's heading; the body starts after it.
  const content = heading ? body.slice(heading.index + heading[0].length) : body;
  const firstParagraph = content
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .find((p) => p && !/^(#|```|- |\||>|---)/.test(p));
  const summary = firstParagraph ? plain(firstParagraph) : "";
  const number = page.kind === "adr" ? path.basename(page.source).slice(0, 4) : undefined;
  return {
    ...page,
    title,
    number,
    status: data.status,
    summary: summary.length > 220 ? `${summary.slice(0, 217).replace(/\s+\S*$/, "")}…` : summary,
    html: md.render(content, { source: page.source }),
    github: `${site.repo}/blob/main/${page.source}`,
  };
}

const all = [...pages.values()].map(load);

export default {
  all,
  overview: all.find((p) => p.kind === "overview"),
  template: all.find((p) => p.kind === "template"),
  runbooks: all.filter((p) => p.kind === "runbook"),
  adrs: all.filter((p) => p.kind === "adr"),
};
