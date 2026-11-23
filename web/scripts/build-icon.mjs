// Renders web/icon-bifrost.svg into plugin/bifrost/res/icon-bifrost.png (240x240 RGBA PNG).
import { mkdir, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { chromium } from "playwright-core";

process.chdir(import.meta.dirname);
const svg = await readFile(resolve("../icon-bifrost.svg"), "utf8");
const outDir = resolve("../../plugin/bifrost/res");
await mkdir(outDir, { recursive: true });
const outPath = resolve(outDir, "icon-bifrost.png");

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 240, height: 240 }, deviceScaleFactor: 1 });
  await page.setContent(
    `<!doctype html><html><body style="margin:0;padding:0;background:transparent;width:240px;height:240px;overflow:hidden">${svg}</body></html>`,
  );
  await page.screenshot({ path: outPath, omitBackground: true });
  console.log(`Generated ${outPath}`);
} finally {
  await browser.close();
}
