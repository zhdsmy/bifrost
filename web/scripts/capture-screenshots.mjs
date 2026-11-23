// Captures the 8 README screenshots (docs/images/*.png, each <= 300 KB)
// plus extra state screenshots into gitignored web/test-results/shots/.
import { once } from "node:events";
import { mkdir, stat } from "node:fs/promises";
import { resolve } from "node:path";
import { chromium } from "playwright-core";
import { createPreviewServer } from "../preview/server.mjs";

const DOCS_IMAGES = resolve(import.meta.dirname, "../../docs/images");
const EXTRA_SHOTS = resolve(import.meta.dirname, "../test-results/shots");
const MAX_README_BYTES = 300 * 1024;

await mkdir(DOCS_IMAGES, { recursive: true });
await mkdir(EXTRA_SHOTS, { recursive: true });

const browser = await chromium.launch();

async function capture({
  outPath,
  initialState = "running",
  lang = "zh-CN",
  mode = "dark",
  viewport = { width: 1120, height: 860 },
  tab,
  afterReady,
  fullPage = false,
}) {
  const server = createPreviewServer({ initialState, lang, mode, fastJobPoll: true, jobStepMs: 20 });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const url = `http://127.0.0.1:${server.address().port}/Module_bifrost.asp`;
  const context = await browser.newContext({ viewport, colorScheme: mode === "light" ? "light" : "dark", reducedMotion: "reduce" });
  const page = await context.newPage();
  try {
    await page.goto(url);
    await page.locator("#bifrost-ui-lang:not([disabled])").waitFor();
    if (tab) {
      await page.getByRole("tab", { name: tab, exact: true }).click();
    }
    if (afterReady) await afterReady(page);
    await page.waitForTimeout(150);
    await page.screenshot({ path: outPath, animations: "disabled", fullPage });
  } finally {
    await context.close();
    await new Promise((r) => server.close(r));
  }
}

try {
  // 8 committed README screenshots (dark zh-CN 5 tabs + overview-light + overview-en + narrow 420px).
  const readmeTargets = [
    { file: "overview.png", tab: "概览", fullPage: true },
    { file: "devices.png", tab: "设备", fullPage: true },
    { file: "settings.png", tab: "设置", fullPage: true },
    { file: "core.png", tab: "核心", fullPage: true },
    {
      file: "diagnostics.png",
      tab: "诊断",
      fullPage: true,
      afterReady: async (page) => {
        await page.getByRole("log").getByText(/== bifrost\.log ==/).waitFor();
      },
    },
    { file: "overview-light.png", mode: "light", tab: "概览", fullPage: true },
    { file: "overview-en.png", lang: "en", tab: "Overview", fullPage: true },
    { file: "narrow.png", viewport: { width: 420, height: 860 }, tab: "概览", fullPage: true },
  ];

  for (const item of readmeTargets) {
    const outPath = resolve(DOCS_IMAGES, item.file);
    await capture({ ...item, outPath });
    const info = await stat(outPath);
    console.log(`${item.file}: ${info.size} bytes`);
    if (info.size > MAX_README_BYTES) {
      throw new Error(`${item.file} is ${info.size} bytes (exceeds ${MAX_README_BYTES} bytes)`);
    }
  }

  // Extra state screenshots into gitignored web/test-results/shots/.
  for (const state of ["disabled", "conflict", "core_missing", "starting", "needs_login_qr", "needs_approval", "stopped", "error"]) {
    await capture({
      outPath: resolve(EXTRA_SHOTS, `state-${state}.png`),
      initialState: state,
    });
  }
  await capture({
    outPath: resolve(EXTRA_SHOTS, "narrow-settings.png"),
    viewport: { width: 420, height: 860 },
    tab: "设置",
    fullPage: true,
  });
  console.log("All screenshots captured successfully.");
} finally {
  await browser.close();
}
