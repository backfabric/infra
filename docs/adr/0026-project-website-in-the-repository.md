# The project website lives in this repository and is published by CI

Amends ADR 0022 (and with it ADR 0015). The project website, <https://backfabric.dev>, is a static site generated with [Eleventy](https://www.11ty.dev/) from the top-level directory `website/`. Its documentation pages are rendered at build time from the repository's own Markdown, read in place: `README.md`, the template's `README.md`, the runbooks in `docs/` and the ADRs in `docs/adr/` (index with number, title, and the `status` of the front matter). Nothing is copied, so the site cannot drift from the docs: a change to a runbook or an ADR is a change to the site. The home page is written in `website/src/`, with what is shipped and in progress in `website/src/_data/status.js`; a PR that changes either updates them.

Nix builds the site like everything else here (`packages.<system>.website`, `nix/website.nix`, `buildNpmPackage` with the npm lockfile pinned by `npmDepsHash`). The workflow `.github/workflows/website.yml` builds it on every pull request that touches it (read-only, nothing published), and on pushes to main publishes it to GitHub Pages with the official Pages actions; only the deploy job has `pages: write` and `id-token: write`. The site is the second artifact CI builds and publishes, next to the agent image; everything else in CI stays evaluation only.

The flake's consumers download the whole repository on every `nix flake update`, so the site stays light: no image files (the artwork is drawn in the browser, by a WebGL shader in one script without dependencies, and by CSS), three OFL fonts self-hosted and subset to Latin, no video, no JavaScript framework. Every page reads the same without the script. It makes no third-party requests and has no trackers.

## Considered Options

- A separate repository `backfabric/website`: the docs would have to be copied or fetched at a commit, and drift; changes to a subsystem and its description would need two PRs.
- Cloudflare Pages or another host: a second account and a deploy token as a repository secret, where GitHub Pages deploys with the workflow's short-lived OIDC token.
- Hugo or Astro: Hugo needs its own templating and content layout for files that live outside its tree; Astro ships a JavaScript framework toolchain for what is a handful of static pages. Eleventy reads data from plain JavaScript and renders Markdown with markdown-it, with three npm dependencies.
- Serving the docs only on GitHub: no place to say what the project is to someone who does not read the repository.

## Consequences

- `website/` is a new top-level directory with `package.json` and `package-lock.json`; bumping a dependency means updating the lockfile and `npmDepsHash`.
- Links between Markdown files are rewritten to the site's pages; links to other files go to GitHub. Heading anchors follow GitHub's, so `file.md#heading` links work on both.
- GitHub Pages serves pages with a cache lifetime of minutes and assets with one of hours, so the stylesheet and the script are linked with a hash of their content (`website/src/_data/assets.js`): a deployment never pairs new pages with the previous stylesheet.
- The custom domain comes from `website/src/CNAME`. Pages, the verified domain and DNS are set up by hand by an organization owner: repository Settings, Pages, Source "GitHub Actions"; the organization's verified domains; the apex and `www` records at the registrar; "Enforce HTTPS".
