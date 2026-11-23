// Kumo 2.19 does not expose locale props for the Toasty viewport, its close
// button, or the Loader inside a loading Button. All three live in our shadow tree.
import type { UiLang } from "../core/types";
import { t } from "./index";

export function localizeKumoLabels(root: HTMLElement, lang: UiLang) {
  const labels = [
    ['.bifrost-overlays [role="region"][aria-live="polite"]', t(lang, "common.notifications")],
    ['.bifrost-overlays [data-kumo-part="close"]', t(lang, "common.close")],
    ['button[data-kumo-component="Button"] svg[role="status"]', t(lang, "common.loadingAction")],
  ] as const;

  function apply(node: Element) {
    for (const [selector, label] of labels) {
      if (node.matches(selector)) node.setAttribute("aria-label", label);
      for (const element of node.querySelectorAll(selector)) element.setAttribute("aria-label", label);
    }
  }

  apply(root);
  const observer = new MutationObserver((records) => {
    for (const record of records) {
      for (const node of record.addedNodes) if (node instanceof Element) apply(node);
    }
  });
  observer.observe(root, { childList: true, subtree: true });
  return () => observer.disconnect();
}
