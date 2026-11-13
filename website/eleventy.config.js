export default function (eleventyConfig) {
  eleventyConfig.addPassthroughCopy({ "src/assets": "assets", "src/CNAME": "CNAME" });
  // The pages under /docs/ are rendered from these files (src/_data/repo.js).
  eleventyConfig.addWatchTarget("../docs/");
  eleventyConfig.addWatchTarget("../README.md");
  eleventyConfig.addWatchTarget("../nix/templates/default/README.md");

  return {
    dir: { input: "src", output: "_site" },
    templateFormats: ["njk"],
    htmlTemplateEngine: "njk",
  };
}
