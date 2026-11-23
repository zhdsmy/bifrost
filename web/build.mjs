// Adapted from po0fw asus-merlin (MIT), commit 0d9532d.
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, unlink, writeFile } from "node:fs/promises";
import { relative, resolve } from "node:path";
import { gzipSync } from "node:zlib";
import { build, transform } from "esbuild";
import postcss from "postcss";
import tailwind from "@tailwindcss/postcss";

const JS_LIMIT = 800_000;
const CSS_LIMIT = 160_000;
const PLACEHOLDER = "__BIFROST_ASSETS__";

process.chdir(import.meta.dirname);

const script = await build({
  entryPoints: ["src/main.tsx"],
  bundle: true,
  preserveSymlinks: true,
  minify: true,
  charset: "utf8",
  format: "iife",
  target: "es2022",
  define: { "process.env.NODE_ENV": '"production"' },
  legalComments: "inline",
  metafile: true,
  write: false,
});

// Restrict Tailwind's scanner to the Kumo modules that actually ship.
const shippedModules = Object.values(script.metafile.outputs)[0].inputs;
const sources = Object.entries(shippedModules)
  .filter(([path, item]) => path.startsWith("node_modules/@cloudflare/kumo/") && item.bytesInOutput > 0)
  .map(([path]) => `@source "${relative("src", path)}";`);

const from = resolve("src/styles.css");
const source = [await readFile(from, "utf8"), ...sources].join("\n");
const css = await postcss([tailwind({ optimize: false })]).process(source, { from });

// Browsers ignore @property inside a shadow tree. Supply each non-inherited
// Tailwind variable's own initial value at the lowest cascade layer instead.
const defaults = postcss.rule({ selector: "*,::before,::after,::backdrop" });
css.root.walkAtRules("property", (rule) => {
  const initial = rule.nodes.find((node) => node.prop === "initial-value");
  if (rule.params.startsWith("--tw-")) {
    defaults.append({ prop: rule.params, value: initial?.value ?? "initial" });
    rule.remove();
  }
});
const layer = postcss.atRule({ name: "layer", params: "properties" });
layer.append(defaults);
css.root.prepend(layer);

const styles = await transform(css.root.toString(), {
  loader: "css",
  minify: true,
  legalComments: "inline",
});

const assets = [
  { extension: "js", data: script.outputFiles[0].contents, limit: JS_LIMIT },
  { extension: "css", data: Buffer.from(styles.code), limit: CSS_LIMIT },
];

for (const { extension, data, limit } of assets) {
  console.log(`bifrost-app.${extension}: ${data.length} bytes (gzip ${gzipSync(data).length})`);
  if (data.length > limit) {
    throw new Error(`bifrost-app.${extension} (${data.length} bytes) exceeds ${limit} bytes`);
  }
}

// A CSS-only rebuild must also invalidate the URL of the script that links it.
const hash = createHash("sha256");
for (const asset of assets) hash.update(asset.data);
const revision = hash.digest("hex").slice(0, 20);

const template = await readFile("../plugin/bifrost/webs/Module_bifrost.asp", "utf8");
if (!template.includes(PLACEHOLDER)) {
  throw new Error(`Missing ${PLACEHOLDER} placeholder in Module_bifrost.asp`);
}

const outRes = "dist/res";
await mkdir(outRes, { recursive: true });
const bundle = `bifrost-app.${revision}`;
for (const { extension, data } of assets) {
  await writeFile(`${outRes}/${bundle}.${extension}`, data);
}
await writeFile("dist/Module_bifrost.asp", template.replace(PLACEHOLDER, revision));

// Keep only the current fingerprinted pair in dist/res.
for (const name of await readdir(outRes)) {
  if (/^bifrost-app(?:\.[0-9a-f]{20})?\.(js|css)$/.test(name) && !name.startsWith(bundle + ".")) {
    await unlink(`${outRes}/${name}`);
  }
}

console.log(`revision: ${revision}`);
console.log("Largest JS inputs (bytes in output):");
for (const [path, input] of Object.entries(shippedModules)
  .sort((a, b) => b[1].bytesInOutput - a[1].bytesInOutput)
  .slice(0, 8)) {
  console.log(`${input.bytesInOutput}  ${path}`);
}
