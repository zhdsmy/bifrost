import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { SkeletonLine } from "@cloudflare/kumo/components/loader";
import { Select } from "@cloudflare/kumo/components/select";
import { Tabs } from "@cloudflare/kumo/components/tabs";
import { AppProvider, useApp, type TabId } from "./context";
import { describeState } from "../core/format";
import type { UiLang, UiMode } from "../core/types";
import { CorePage } from "../pages/CorePage";
import { DevicesPage } from "../pages/DevicesPage";
import { DiagnosticsPage } from "../pages/DiagnosticsPage";
import { OverviewPage } from "../pages/OverviewPage";
import { SettingsPage } from "../pages/SettingsPage";

declare global {
  interface Window {
    reload_Soft_Center?: () => void;
  }
}

function AppShell() {
  const {
    lang,
    mode,
    overlays,
    tab,
    setTab,
    status,
    initializing,
    uiLoaded,
    uiLoadError,
    statusLoadError,
    uiError,
    savingUi,
    changeLang,
    changeMode,
    t,
    tState,
  } = useApp();

  const presentation = status ? describeState(status) : null;
  const langItems: Record<UiLang, string> = {
    "zh-CN": t("header.language.zhCN"),
    en: t("header.language.en"),
  };
  const modeItems: Record<UiMode, string> = {
    dark: t("header.mode.dark"),
    light: t("header.mode.light"),
    system: t("header.mode.system"),
  };
  const tabItems: Array<{ value: TabId; label: string }> = [
    { value: "overview", label: t("tab.overview") },
    { value: "devices", label: t("tab.devices") },
    { value: "settings", label: t("tab.settings") },
    {
      value: "core",
      label: status?.core.update || status?.plugin.update ? `${t("tab.core")} •` : t("tab.core"),
    },
    { value: "diagnostics", label: t("tab.diagnostics") },
  ];

  const uiDisabled = !uiLoaded || initializing || savingUi;

  return (
    <main className="@container rounded-xl border border-kumo-line bg-kumo-base text-kumo-default">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b border-kumo-line px-6 py-5">
        <div className="flex min-w-0 items-center gap-3">
          <img
            src="/res/icon-bifrost.png"
            width={44}
            height={44}
            alt=""
            className="shrink-0"
          />
          <div className="grid min-w-0 gap-1">
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="text-xl font-semibold text-kumo-strong">
                {t("app.name")}
              </h1>
              {status && presentation && (
                <Badge appearance="dot" variant={presentation.badgeVariant}>
                  {tState(status.state)}
                </Badge>
              )}
              {status?.plugin.version && (
                <Badge variant="outline">{status.plugin.version}</Badge>
              )}
            </div>
            <p className="text-sm text-kumo-subtle">{t("app.subtitle")}</p>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <Select<UiLang>
            id="bifrost-ui-lang"
            aria-label={t("header.language")}
            items={langItems}
            value={lang}
            modal={false}
            container={overlays}
            disabled={uiDisabled}
            onValueChange={(next) => {
              if (next) void changeLang(next);
            }}
          />
          <Select<UiMode>
            id="bifrost-ui-mode"
            aria-label={t("header.mode")}
            items={modeItems}
            value={mode}
            modal={false}
            container={overlays}
            disabled={uiDisabled}
            onValueChange={(next) => {
              if (next) void changeMode(next);
            }}
          />
          <Button
            variant="secondary"
            onClick={() => window.reload_Soft_Center?.()}
          >
            {t("header.backToSoftcenter")}
          </Button>
        </div>
      </header>

      {(uiLoadError || uiError || statusLoadError) && (
        <div className="grid gap-2 border-b border-kumo-line px-6 py-3">
          {uiLoadError && (
            <Banner variant="alert" role="alert" size="sm" title={t("common.uiLoadFailed")} />
          )}
          {uiError && (
            <Banner variant="error" role="alert" size="sm" title={uiError} />
          )}
          {statusLoadError && (
            <Banner variant="error" role="alert" size="sm" title={statusLoadError} />
          )}
        </div>
      )}

      <div className="border-b border-kumo-line px-6 pt-2">
        <Tabs
          variant="underline"
          size={lang === "en" ? "sm" : "base"}
          tabs={tabItems}
          value={tab}
          onValueChange={(v) => setTab(v as TabId)}
          labels={{
            scrollStart: t("tabs.scrollLeft"),
            scrollEnd: t("tabs.scrollRight"),
          }}
        />
      </div>

      <div className="p-6">
        {!status ? (
          <div className="grid gap-3 py-4" aria-busy="true" aria-label={t("common.loading")}>
            <SkeletonLine />
            <SkeletonLine />
            <SkeletonLine />
          </div>
        ) : (
          <>
            {tab === "overview" && <OverviewPage />}
            {tab === "devices" && <DevicesPage />}
            {tab === "settings" && <SettingsPage />}
            {tab === "core" && <CorePage />}
            {tab === "diagnostics" && <DiagnosticsPage />}
          </>
        )}
      </div>
    </main>
  );
}

export function App({ themeRoot, overlays }: { themeRoot: HTMLElement; overlays: HTMLElement }) {
  return (
    <AppProvider themeRoot={themeRoot} overlays={overlays}>
      <AppShell />
    </AppProvider>
  );
}
