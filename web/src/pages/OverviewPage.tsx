import { useState } from "react";
import { InfoIcon } from "@phosphor-icons/react/dist/csr/Info";
import { Button } from "@cloudflare/kumo/components/button";
import { Loader } from "@cloudflare/kumo/components/loader";
import { Tooltip } from "@cloudflare/kumo/components/tooltip";
import { useApp } from "../app/context";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { JobProgress } from "../components/JobProgress";
import { SectionCard } from "../components/SectionCard";
import { api } from "../core/api";
import { describeState, type PrimaryActionKind } from "../core/format";
import type { LoginJobData } from "../core/types";
import { isAccessingFromTailnet } from "../core/validate";
import { HealthCard } from "./overview/HealthCard";
import { LoginCard } from "./overview/LoginCard";
import { MigrateCard } from "./overview/MigrateCard";
import { OverviewDetails } from "./overview/OverviewDetails";

type OverviewConfirmKind = "disable" | "logout" | "relogin" | "migrate";

interface OverviewConfirmState {
  kind: OverviewConfirmKind;
  anchor: HTMLElement;
}

export function OverviewPage() {
  const {
    status,
    overlays,
    busy,
    jobs,
    setTab,
    runJob,
    reloadStatus,
    notify,
    t,
    tError,
    tErrorCode,
    tState,
  } = useApp();

  const [syncActionBusy, setSyncActionBusy] = useState(false);
  const [confirmState, setConfirmState] = useState<OverviewConfirmState | null>(null);

  if (!status) return null;

  const presentation = describeState(status);
  const actionDisabled = busy || syncActionBusy;
  const fromTailnet = isAccessingFromTailnet(window.location.hostname, status.self);

  async function runSync(action: () => Promise<unknown>) {
    setSyncActionBusy(true);
    try {
      await action();
      await reloadStatus();
      notify({ title: t("common.actionSuccess"), variant: "success" });
    } catch (err) {
      notify({ title: tError(err), variant: "error" });
    } finally {
      setSyncActionBusy(false);
    }
  }

  async function executeConfirm(kind: OverviewConfirmKind) {
    setConfirmState(null);
    if (kind === "disable") {
      await runJob("daemon", () => api.disable(), {
        suppressLoginFailure: true,
      });
      return;
    }
    if (kind === "logout") {
      await runSync(api.logout);
      return;
    }
    if (kind === "relogin") {
      await runJob<LoginJobData>("login", () => api.relogin());
      return;
    }
    await runJob("migrate", api.migrate);
  }

  function stateDescription(): string {
    switch (status!.state) {
      case "disabled":
        return t("overview.desc.disabled");
      case "conflict":
        return t("overview.desc.conflict");
      case "core_missing":
        return t("overview.desc.core_missing");
      case "starting":
        return t("overview.desc.starting");
      case "needs_login":
        return t("overview.desc.needs_login");
      case "needs_approval":
        return t("overview.desc.needs_approval");
      case "stopped":
        return t("overview.desc.stopped");
      case "running":
        return t("overview.desc.running");
      case "error":
        return t("overview.desc.error", {
          reason: tErrorCode(status!.error ?? "internal"),
        });
    }
  }

  function renderAction(action: PrimaryActionKind) {
    switch (action) {
      case "enable":
        return (
          <Button
            variant="primary"
            size="sm"
            disabled={actionDisabled}
            loading={jobs.daemon?.running}
            onClick={() => {
              void runJob("daemon", () => api.enable());
            }}
          >
            {t("overview.action.enable")}
          </Button>
        );
      case "migrate":
        return (
          <Button
            variant="primary"
            size="sm"
            disabled={actionDisabled}
            onClick={(e) => setConfirmState({ kind: "migrate", anchor: e.currentTarget })}
          >
            {t("overview.action.migrate")}
          </Button>
        );
      case "goto_core":
        return (
          <Button variant="primary" size="sm" onClick={() => setTab("core")}>
            {t("overview.action.gotoCore")}
          </Button>
        );
      case "connect":
        return (
          <Button
            variant="primary"
            size="sm"
            disabled={actionDisabled}
            loading={syncActionBusy}
            onClick={() => {
              void runSync(api.connect);
            }}
          >
            {t("overview.action.connect")}
          </Button>
        );
      case "disable":
        return (
          <Button
            variant="secondary"
            size="sm"
            disabled={actionDisabled}
            loading={jobs.daemon?.running}
            onClick={(e) => setConfirmState({ kind: "disable", anchor: e.currentTarget })}
          >
            {t("overview.action.disable")}
          </Button>
        );
    }
  }

  const confirmConfig = confirmState
    ? {
        disable: {
          title: t("overview.disableConfirmTitle"),
          description: fromTailnet
            ? t("overview.disableTailnetConfirmDesc")
            : t("overview.disableConfirmDesc"),
          variant: (fromTailnet ? "destructive" : "primary") as "destructive" | "primary",
          disruptive: true,
        },
        logout: {
          title: t("overview.logoutConfirmTitle"),
          description: t("overview.logoutConfirmDesc"),
          variant: "destructive" as const,
          disruptive: false,
        },
        relogin: {
          title: t("overview.reloginConfirmTitle"),
          description: t("overview.reloginConfirmDesc"),
          variant: "primary" as const,
          disruptive: true,
        },
        migrate: {
          title: t("migrate.confirmTitle"),
          description: t("migrate.confirmDesc"),
          variant: "primary" as const,
          disruptive: true,
        },
      }[confirmState.kind]
    : null;

  return (
    <div className="grid gap-4">
      <SectionCard
        title={
          <span className="inline-flex flex-wrap items-center gap-2">
            <span>{tState(status.state)}</span>
            <Tooltip asChild container={overlays} content={t("overview.tailnetTerm")}>
              <button
                type="button"
                aria-label={t("common.moreInfo")}
                className="inline-flex items-center text-kumo-subtle hover:text-kumo-default"
              >
                <InfoIcon size={16} aria-hidden />
              </button>
            </Tooltip>
          </span>
        }
        description={
          <span className="grid gap-1">
            <span>{stateDescription()}</span>
            {status.state === "error" && (
              <span className="text-xs text-kumo-subtle">{t("overview.desc.errorAdvice")}</span>
            )}
          </span>
        }
        action={
          <>
            {status.state === "starting" && <Loader size="sm" aria-label={t("common.loadingAction")} />}
            {renderAction(presentation.primaryAction)}
            {presentation.showAuthActions && (
              <>
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={actionDisabled || jobs.login?.running}
                  onClick={(e) => setConfirmState({ kind: "relogin", anchor: e.currentTarget })}
                >
                  {t("overview.action.relogin")}
                </Button>
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={actionDisabled}
                  onClick={(e) => setConfirmState({ kind: "logout", anchor: e.currentTarget })}
                >
                  {t("overview.action.logout")}
                </Button>
              </>
            )}
            {presentation.secondaryAction && renderAction(presentation.secondaryAction)}
          </>
        }
      >
        {presentation.showAuthActions && jobs.login?.running && (
          <p className="text-sm text-kumo-subtle">{t("login.jobWaiting")}</p>
        )}
        <JobProgress job={jobs.daemon} hideSuccess />
      </SectionCard>

      {presentation.showLoginView && <LoginCard status={status} disabled={actionDisabled} />}

      {(presentation.showMigrateCard || jobs.migrate) && (
        <MigrateCard
          showAction={presentation.showMigrateCard}
          disabled={actionDisabled}
          onRequestMigrate={(anchor) => setConfirmState({ kind: "migrate", anchor })}
        />
      )}

      {presentation.showOverviewDetails ? (
        <OverviewDetails status={status} />
      ) : (
        (status.health.length > 0 || status.checks.length > 0) && (
          <HealthCard checks={status.checks} health={status.health} />
        )
      )}

      {confirmState && confirmConfig && (
        <ConfirmDialog
          open={true}
          anchor={confirmState.anchor}
          onOpenChange={(open) => {
            if (!open) setConfirmState(null);
          }}
          title={confirmConfig.title}
          description={confirmConfig.description}
          confirmVariant={confirmConfig.variant}
          disruptive={confirmConfig.disruptive}
          onConfirm={() => executeConfirm(confirmState.kind)}
        />
      )}
    </div>
  );
}
