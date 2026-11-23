// Adapted from po0fw asus-merlin (MIT), commit 0d9532d.
import { createRoot } from "react-dom/client";
import { KumoPortalProvider } from "@cloudflare/kumo/utils";
import { App } from "./app/App";

const UNSUPPORTED_MESSAGE =
  "当前浏览器版本过低，请升级至 Chrome / Edge 123、Safari 17.5 或 Firefox 128 及以上版本。\n" +
  "Unsupported browser version. Please upgrade to Chrome / Edge 123, Safari 17.5, or Firefox 128 or newer.";

const STYLE_ERROR_MESSAGE = "样式加载失败，请刷新。 / Failed to load styles, please refresh.";

function isSupportedBrowser(): boolean {
  if (typeof Element === "undefined" || typeof Element.prototype.attachShadow !== "function") {
    return false;
  }
  if (typeof CSS === "undefined" || typeof CSS.supports !== "function") {
    return false;
  }
  if (typeof CSSPropertyRule === "undefined") {
    return false;
  }
  return (
    CSS.supports("color", "light-dark(#000, #fff)") &&
    CSS.supports("container-type", "inline-size")
  );
}

const host = document.getElementById("bifrost-app");
if (host) {
  if (!isSupportedBrowser()) {
    host.textContent = UNSUPPORTED_MESSAGE;
  } else {
    const shadow = host.attachShadow({ mode: "open" });
    const stylesheet = document.createElement("link");
    stylesheet.rel = "stylesheet";
    const script = document.currentScript as HTMLScriptElement | null;
    if (script?.src) {
      stylesheet.href = script.src.replace(/\.js$/, ".css");
    }

    const theme = document.createElement("div");
    theme.dataset.mode = "dark";
    theme.style.colorScheme = "dark";

    const root = document.createElement("div");
    const overlays = document.createElement("div");
    overlays.className = "bifrost-overlays";
    theme.append(root, overlays);

    // Render only after the local stylesheet is ready to avoid flashing unstyled controls.
    stylesheet.addEventListener("load", () => {
      createRoot(root).render(
        <KumoPortalProvider container={overlays}>
          <App themeRoot={theme} overlays={overlays} />
        </KumoPortalProvider>,
      );
    });
    stylesheet.addEventListener("error", () => {
      root.textContent = STYLE_ERROR_MESSAGE;
    });
    shadow.append(stylesheet, theme);
  }
}
