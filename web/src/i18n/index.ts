import type { KumoTranslationsPartial } from "@cloudflare/kumo/utils";
import type { UiLang } from "../core/types";
import { en } from "./en.ts";
import { zhCN, type MessageKey } from "./zh-CN.ts";

export type { MessageKey };

const catalogs: Record<UiLang, Record<MessageKey, string>> = {
  "zh-CN": zhCN,
  en,
};

export function t(lang: UiLang, key: MessageKey, vars?: Record<string, string | number>): string {
  const template = catalogs[lang][key];
  if (!vars) return template;
  return template.replace(/\{([A-Za-z0-9_]+)\}/g, (match, name: string) =>
    Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : match,
  );
}

function hasKey(key: string): key is MessageKey {
  return Object.prototype.hasOwnProperty.call(zhCN, key);
}

export function translateError(lang: UiLang, code: string, httpStatus?: number): string {
  if (code === "http_error" && httpStatus !== undefined) {
    return t(lang, "err.http_error", { status: httpStatus });
  }
  const key = `err.${code}`;
  if (hasKey(key)) return t(lang, key);
  return t(lang, "err.unknown", { code });
}

export function translatePhase(lang: UiLang, phase: string): string {
  const key = `phase.${phase}`;
  if (hasKey(key)) return t(lang, key);
  return t(lang, "phase.unknown", { code: phase });
}

export function translateState(lang: UiLang, state: string): string {
  const key = `state.${state}`;
  if (hasKey(key)) return t(lang, key);
  return t(lang, "state.unknown", { code: state });
}

export function translateCheck(lang: UiLang, code: string): string {
  const key = `check.${code}`;
  if (hasKey(key)) return t(lang, key);
  return t(lang, "check.unknown", { code });
}

export function getKumoTranslations(lang: UiLang): KumoTranslationsPartial {
  return {
    label: {
      optional: t(lang, "common.optional"),
      tooltip: t(lang, "common.moreInfo"),
    },
    layerDialog: {
      close: t(lang, "common.close"),
      cancel: t(lang, "common.cancel"),
    },
    breadcrumbs: {
      label: t(lang, "kumo.breadcrumbLabel"),
      copy: t(lang, "common.copy"),
      copyTooltip: t(lang, "common.copyAction"),
    },
  };
}
