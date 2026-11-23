// Adapted from po0fw asus-merlin (MIT), commit 0d9532d.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { appendFile, copyFile, cp, mkdir, mkdtemp, readdir, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { openPreview, ready } from "./fixture.mjs";

const webDir = fileURLToPath(new URL("../", import.meta.url));
const repoPluginWebs = fileURLToPath(new URL("../../plugin/bifrost/webs/", import.meta.url));

async function installBuiltFrontend(sourceWeb, targetPageFile, targetResDir) {
  const builtRes = join(sourceWeb, "dist/res");
  const names = (await readdir(builtRes)).filter((n) => /^bifrost-app\.[0-9a-f]{20}\.(js|css)$/.test(n));
  assert.equal(names.length, 2, `Expected 1 JS+CSS pair in ${builtRes}`);
  await rm(targetResDir, { recursive: true, force: true });
  await mkdir(targetResDir, { recursive: true });
  for (const name of names) {
    await copyFile(join(builtRes, name), join(targetResDir, name));
  }
  await copyFile(join(sourceWeb, "dist/Module_bifrost.asp"), targetPageFile);
}

// Browser HTTP cache stays enabled (no Playwright route interception).
test("cache upgrade: CSS-only and JS-only rebuilds bust browser cache cleanly", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "bifrost-cache-"));
  t.after(() => rm(dir, { recursive: true, force: true }));

  const pageFile = join(dir, "Module_bifrost.asp");
  const installedResDir = join(dir, "installed-res");

  // Prepare an isolated scratch copy of web/ sharing node_modules via symlink.
  const scratchRoot = join(dir, "scratch");
  const scratchWeb = join(scratchRoot, "web");
  const scratchWebs = join(scratchRoot, "plugin/bifrost/webs");
  await mkdir(scratchWeb, { recursive: true });
  await mkdir(scratchWebs, { recursive: true });
  await cp(repoPluginWebs, scratchWebs, { recursive: true });
  await cp(join(webDir, "src"), join(scratchWeb, "src"), { recursive: true });
  for (const file of ["build.mjs", "tsconfig.json", "package.json"]) {
    await copyFile(join(webDir, file), join(scratchWeb, file));
  }
  await symlink(join(webDir, "node_modules"), join(scratchWeb, "node_modules"), "dir");

  const scratchMain = join(scratchWeb, "src/main.tsx");
  const scratchCss = join(scratchWeb, "src/styles.css");
  await appendFile(scratchMain, '\ndocument.documentElement.dataset.priorPackage = "yes";\n');
  await appendFile(scratchCss, "\n:host { --prior-style: yes; }\n");

  // Build #1: both prior JS and prior CSS markers.
  execFileSync(process.execPath, ["build.mjs"], { cwd: scratchWeb, stdio: "pipe" });
  await installBuiltFrontend(scratchWeb, pageFile, installedResDir);

  const { page, server, url } = await openPreview(t, {
    pageFile,
    resources: pathToFileURL(installedResDir + "/"),
  });

  const assetRequests = [];
  server.on("request", (req) => {
    if (req.url.startsWith("/res/bifrost-app.")) assetRequests.push(req.url);
  });

  const navigate = async () => {
    await page.goto(new URL("/Module_Softcenter.asp", url).href);
    await page.goto(url);
    await ready(page);
  };

  const inspectLoaded = () =>
    page.evaluate(() => {
      const host = document.getElementById("bifrost-app");
      const script = document.querySelector('script[src^="/res/bifrost-app."]');
      const css = host.shadowRoot.querySelector('link[rel="stylesheet"]');
      return {
        js: script.getAttribute("src"),
        css: new URL(css.getAttribute("href"), location.href).pathname,
        priorScript: document.documentElement.dataset.priorPackage,
        priorStyle: getComputedStyle(host).getPropertyValue("--prior-style").trim(),
      };
    });

  // Step 1: initial build loads JS+CSS once, then revisit hits browser cache (0 new requests).
  await navigate();
  const s1 = await inspectLoaded();
  assert.equal(s1.priorScript, "yes");
  assert.equal(s1.priorStyle, "yes");
  assert.deepEqual(assetRequests, [s1.js, s1.css]);

  await navigate();
  assert.equal(assetRequests.length, 2, "revisit must reuse immutable browser cache");

  // Step 2: CSS-only change -> joint hash changes -> browser fetches both new JS and CSS.
  await copyFile(join(webDir, "src/styles.css"), scratchCss);
  execFileSync(process.execPath, ["build.mjs"], { cwd: scratchWeb, stdio: "pipe" });
  await installBuiltFrontend(scratchWeb, pageFile, installedResDir);

  await navigate();
  const s2 = await inspectLoaded();
  assert.notEqual(s2.js, s1.js);
  assert.equal(s2.priorScript, "yes");
  assert.equal(s2.priorStyle, "");
  assert.deepEqual(assetRequests.slice(2), [s2.js, s2.css]);

  // Step 3: JS-only change (current repo build) -> joint hash changes -> browser fetches new pair.
  await installBuiltFrontend(webDir, pageFile, installedResDir);

  await navigate();
  const s3 = await inspectLoaded();
  assert.notEqual(s3.js, s2.js);
  assert.equal(s3.priorScript, undefined);
  assert.equal(s3.priorStyle, "");
  assert.deepEqual(assetRequests.slice(4), [s3.js, s3.css]);
});
