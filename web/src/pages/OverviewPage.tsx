import { useMemo, useState } from "react";
import { ArrowSquareOutIcon } from "@phosphor-icons/react/dist/csr/ArrowSquareOut";
import { InfoIcon } from "@phosphor-icons/react/dist/csr/Info";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { ClipboardText } from "@cloudflare/kumo/components/clipboard-text";
import { Collapsible } from "@cloudflare/kumo/components/collapsible";
import { InlineCopyText } from "@cloudflare/kumo/components/inline-copy-text";
import { Input } from "@cloudflare/kumo/components/input";
import { Loader } from "@cloudflare/kumo/components/loader";
import { SensitiveInput } from "@cloudflare/kumo/components/sensitive-input";
import { Tooltip } from "@cloudflare/kumo/components/tooltip";
import { useApp } from "../app/context";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { JobProgress } from "../components/JobProgress";
import { QrCode } from "../components/QrCode";
import { DetailItem, DetailList, SectionCard } from "../components/SectionCard";
import { api } from "../core/api";
import { analyzeKeyExpiry, describeState, formatIsoDate } from "../core/format";
import type {
  JobState,
  LoginJobData,
  MigrateJobData,
  NetcheckJobData,
} from "../core/types";
import { isHttpLoginServer, validAuthKey, validLoginServer } from "../core/validate";

const OFFICIAL_CONSOLE_URL = "https://login.tailscale.com/admin/machines";

type OverviewConfirmKind = "logout" | "relogin" | "migrate";

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
    tCheck,
  } = useApp();

  const [serverDraft, setServerDraft] = useState("");
  const [authKeyDraft, setAuthKeyDraft] = useState("");
  const [loginValidationError, setLoginValidationError] = useState<string | null>(null);
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [syncActionBusy, setSyncActionBusy] = useState(false);
  const [confirmState, setConfirmState] = useState<OverviewConfirmState | null>(null);

  const copyLabels = useMemo(
    () => ({ copyAction: t("common.copyAction"), copied: t("common.copied") }),
    [t],
  );

  if (!status) return null;

  const presentation = describeState(status);
  const loginJob = jobs.login as JobState<LoginJobData> | undefined;
  const migrateJob = jobs.migrate as JobState<MigrateJobData> | undefined;
  const netcheckJob = jobs.netcheck as JobState<NetcheckJobData> | undefined;
  const netcheckReport = netcheckJob?.data?.report ?? null;

  const actionDisabled = busy || syncActionBusy;

  async function handleConnect() {
    setSyncActionBusy(true);
    try {
      await api.connect();
      await reloadStatus();
      notify({ title: t("common.actionSuccess"), variant: "success" });
    } catch (err) {
      notify({ title: tError(err), variant: "error" });
    } finally {
      setSyncActionBusy(false);
    }
  }

  async function handleStartLogin() {
    const server = serverDraft.trim();
    const authKey = authKeyDraft.trim();
    if (server !== "" && !validLoginServer(server)) {
      setLoginValidationError(t("validate.server"));
      return;
    }
    if (authKey !== "" && !validAuthKey(authKey)) {
      setLoginValidationError(t("validate.authKey"));
      return;
    }
    setLoginValidationError(null);
    await runJob<LoginJobData>("login", () => api.login(server, authKey), {
      refreshWhileRunning: true,
      onDone: (final) => {
        if (final.ok) {
          setAuthKeyDraft("");
          notify({ title: t("common.actionSuccess"), variant: "success" });
        }
      },
    });
  }

  async function executeConfirm(kind: OverviewConfirmKind) {
    setConfirmState(null);
    if (kind === "logout") {
      setSyncActionBusy(true);
      try {
        await api.logout();
        await reloadStatus();
        notify({ title: t("common.actionSuccess"), variant: "success" });
      } catch (err) {
        notify({ title: tError(err), variant: "error" });
      } finally {
        setSyncActionBusy(false);
      }
      return;
    }
    if (kind === "relogin") {
      await runJob<LoginJobData>("login", () => api.relogin(), {
        refreshWhileRunning: true,
      });
      return;
    }
    await runJob<MigrateJobData>("migrate", () => api.migrate(), {
      onDone: (final) => {
        if (final.ok) notify({ title: t("migrate.doneSuccess"), variant: "success" });
      },
    });
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

  const self = status.self;
  const keyExpiry = self ? analyzeKeyExpiry(self.key_expiry, status.time * 1000) : null;
  const preferredDerpLatency =
    netcheckReport && self?.relay
      ? netcheckReport.derp.find((d) => d.code === self.relay)?.latency_ms
      : undefined;
  const isCustomControl =
    self?.official === false ||
    loginJob?.data?.official === false ||
    serverDraft.trim() !== "";
  const loginExpired = !loginJob?.running && loginJob?.code === "login_expired";
  const anyRoutePending =
    status.routes.some((r) => !r.approved) ||
    (status.exit_node.advertised && !status.exit_node.approved);

  return (
    <div className="grid gap-4">
      {/* Top Status & Primary Actions */}
      <SectionCard
        title={
          <span className="inline-flex flex-wrap items-center gap-2">
            <span>{tState(status.state)}</span>
            <Tooltip container={overlays} content={t("overview.tailnetTerm")}>
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
            {status.state === "starting" && <Loader size="sm" />}
            {(status.state === "disabled" || status.state === "error") && (
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
            )}
            {status.state === "conflict" && (
              <Button
                variant="primary"
                size="sm"
                disabled={actionDisabled}
                onClick={(e) => setConfirmState({ kind: "migrate", anchor: e.currentTarget })}
              >
                {t("overview.action.migrate")}
              </Button>
            )}
            {status.state === "core_missing" && (
              <Button variant="primary" size="sm" onClick={() => setTab("core")}>
                {t("overview.action.gotoCore")}
              </Button>
            )}
            {status.state === "stopped" && (
              <Button
                variant="primary"
                size="sm"
                disabled={actionDisabled}
                loading={syncActionBusy}
                onClick={() => {
                  void handleConnect();
                }}
              >
                {t("overview.action.connect")}
              </Button>
            )}
            {status.state === "running" && (
              <>
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={actionDisabled}
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
            {(status.state === "running" ||
              status.state === "starting" ||
              status.state === "needs_login" ||
              status.state === "needs_approval" ||
              status.state === "stopped") && (
              <Button
                variant="secondary"
                size="sm"
                disabled={actionDisabled}
                loading={jobs.daemon?.running}
                onClick={() => {
                  void runJob("daemon", () => api.disable());
                }}
              >
                {t("overview.action.disable")}
              </Button>
            )}
          </>
        }
      >
        <JobProgress job={jobs.daemon} hideSuccess />
      </SectionCard>

      {/* Login View (when needs_login) */}
      {presentation.showLoginView && (
        <SectionCard title={t("login.title")} description={t("login.subtitle")}>
          {loginExpired && (
            <Banner variant="alert" role="alert" title={t("login.expiredBanner")} />
          )}

          {status.auth_url && (
            <div className="grid gap-4 rounded-lg border border-kumo-line bg-kumo-recessed p-4">
              <div className="flex flex-wrap items-start gap-4">
                <QrCode value={status.auth_url} alt={t("login.qrAlt")} />
                <div className="grid min-w-0 flex-1 gap-3">
                  <h3 className="text-sm font-semibold text-kumo-strong">
                    {t("login.qrHeading")}
                  </h3>
                  <ClipboardText
                    size="sm"
                    text={status.auth_url}
                    tooltip={{ text: t("common.copy"), copiedText: t("common.copied") }}
                    labels={{
                      copyAction: t("common.copyAction"),
                      revealAction: t("common.reveal"),
                      hideAction: t("common.hide"),
                    }}
                  />
                  <div className="flex flex-wrap items-center gap-3">
                    <a
                      href={status.auth_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex items-center gap-1 text-sm font-medium text-kumo-link underline"
                    >
                      {t("login.openLink")}
                      <ArrowSquareOutIcon size={14} aria-hidden />
                    </a>
                  </div>
                  <div className="flex items-center gap-2 text-xs text-kumo-subtle">
                    <Loader size="sm" />
                    <span>{t("login.waitingAuth")}</span>
                  </div>
                </div>
              </div>
              {isCustomControl && (
                <Banner variant="default" size="sm" description={t("login.customServerNotice")} />
              )}
            </div>
          )}

          {loginJob && !status.auth_url && (
            <JobProgress job={loginJob} label={t("login.startingNotice")} hideSuccess />
          )}

          <Collapsible.Root
            open={advancedOpen}
            onOpenChange={setAdvancedOpen}
            className="rounded-lg border border-kumo-line bg-kumo-recessed/50 px-3 py-2"
          >
            <Collapsible.DefaultTrigger className="w-full py-1 text-sm font-medium text-kumo-default">
              {t("login.advancedToggle")}
            </Collapsible.DefaultTrigger>
            <Collapsible.DefaultPanel className="grid gap-4 pt-3 pb-2">
              <Input
                id="login-control-server"
                label={t("login.serverLabel")}
                placeholder={t("login.serverPlaceholder")}
                description={t("login.serverDesc")}
                value={serverDraft}
                disabled={actionDisabled}
                onChange={(e) => {
                  setServerDraft(e.target.value);
                  setLoginValidationError(null);
                }}
                autoComplete="off"
                spellCheck={false}
              />
              {isHttpLoginServer(serverDraft.trim()) && (
                <Banner variant="alert" size="sm" description={t("login.serverHttpWarn")} />
              )}
              <SensitiveInput
                id="login-auth-key"
                label={t("login.authKeyLabel")}
                placeholder={t("login.authKeyPlaceholder")}
                description={t("login.authKeyDesc")}
                value={authKeyDraft}
                disabled={actionDisabled}
                onValueChange={(v) => {
                  setAuthKeyDraft(v);
                  setLoginValidationError(null);
                }}
                autoComplete="off"
                spellCheck={false}
              />
            </Collapsible.DefaultPanel>
          </Collapsible.Root>

          {loginValidationError && (
            <Banner variant="error" role="alert" size="sm" title={loginValidationError} />
          )}

          <div className="flex flex-wrap gap-2">
            <Button
              variant="primary"
              disabled={actionDisabled}
              loading={loginJob?.running}
              onClick={() => {
                void handleStartLogin();
              }}
            >
              {authKeyDraft.trim()
                ? t("login.startWithKeyButton")
                : loginExpired || status.auth_url
                  ? t("login.retryButton")
                  : t("login.startButton")}
            </Button>
          </div>
        </SectionCard>
      )}

      {/* Migration Entry & Progress */}
      {(presentation.showMigrateCard || migrateJob) && (
        <SectionCard
          title={t("migrate.title")}
          description={t("migrate.desc")}
          action={
            presentation.showMigrateCard && (
              <Button
                variant="primary"
                disabled={actionDisabled}
                loading={migrateJob?.running}
                onClick={(e) => setConfirmState({ kind: "migrate", anchor: e.currentTarget })}
              >
                {t("migrate.button")}
              </Button>
            )
          }
        >
          <p className="text-xs text-kumo-subtle">{t("migrate.note")}</p>
          {migrateJob?.running && migrateJob.data?.manual_stop && (
            <Banner variant="alert" title={t("migrate.manualStopNotice")} />
          )}
          {migrateJob && !migrateJob.running && migrateJob.ok === true && (
            <Banner variant="default" title={t("migrate.doneSuccess")} />
          )}
          {migrateJob && !migrateJob.running && migrateJob.ok === false && migrateJob.data?.rolled_back && (
            <Banner variant="alert" role="alert" title={t("migrate.doneRolledBack")} />
          )}
          <JobProgress job={migrateJob} hideSuccess />
        </SectionCard>
      )}

      {/* Running / Active Details */}
      {presentation.showOverviewDetails && (
        <>
          {/* Self Info */}
          {self && (
            <SectionCard title={t("overview.section.self")}>
              {keyExpiry?.expired && (
                <Banner variant="error" role="alert" title={t("overview.keyExpired")} />
              )}
              {keyExpiry?.expiringSoon && (
                <Banner
                  variant="alert"
                  title={t("overview.keyExpiringSoon", { days: keyExpiry.daysLeft })}
                />
              )}
              <DetailList>
                <DetailItem label={t("overview.field.hostname")}>
                  <span className="font-medium text-kumo-strong">{self.hostname || "—"}</span>
                </DetailItem>
                <DetailItem label={t("overview.field.tailnet")}>
                  {self.tailnet || "—"}
                </DetailItem>
                <DetailItem label={t("overview.field.tailnetIps")}>
                  <div className="flex flex-wrap gap-2">
                    {self.ips.length > 0 ? (
                      self.ips.map((ip) => (
                        <InlineCopyText key={ip} value={ip} labels={copyLabels}>
                          {ip}
                        </InlineCopyText>
                      ))
                    ) : (
                      <span>—</span>
                    )}
                  </div>
                </DetailItem>
                <DetailItem label={t("overview.field.magicdns")}>
                  {self.dns_name ? (
                    <InlineCopyText value={self.dns_name} labels={copyLabels}>
                      {self.dns_name}
                    </InlineCopyText>
                  ) : (
                    <span>—</span>
                  )}
                </DetailItem>
                {!self.official && self.control && (
                  <DetailItem label={t("overview.field.control")}>
                    <span className="font-mono text-xs">{self.control}</span>
                  </DetailItem>
                )}
                <DetailItem label={t("overview.field.keyExpiry")}>
                  {formatIsoDate(self.key_expiry)}
                </DetailItem>
              </DetailList>
            </SectionCard>
          )}

          {/* Connectivity & Routing */}
          <div className="grid gap-4 @xl:grid-cols-2">
            <SectionCard
              title={t("overview.section.connection")}
              action={
                !netcheckReport && (
                  <Button size="sm" variant="ghost" onClick={() => setTab("diagnostics")}>
                    {t("overview.connection.runNetcheck")}
                  </Button>
                )
              }
            >
              <DetailList>
                <DetailItem label={t("overview.field.online")}>
                  <Badge appearance="dot" variant={self?.online ? "success" : "secondary"}>
                    {self?.online ? t("overview.connection.online") : t("overview.connection.offline")}
                  </Badge>
                </DetailItem>
                <DetailItem label={t("overview.field.preferredDerp")}>
                  {self?.relay ? (
                    <span className="font-mono">
                      {self.relay}
                      {preferredDerpLatency !== undefined ? ` (${preferredDerpLatency} ms)` : ""}
                    </span>
                  ) : (
                    "—"
                  )}
                </DetailItem>
                <DetailItem label={t("overview.field.udp")}>
                  {netcheckReport ? (
                    <Badge variant={netcheckReport.udp ? "success" : "warning"}>
                      {netcheckReport.udp ? t("common.yes") : t("common.no")}
                    </Badge>
                  ) : (
                    <span className="text-kumo-subtle">—</span>
                  )}
                </DetailItem>
                <DetailItem label={t("overview.field.portmap")}>
                  {netcheckReport ? (
                    <span>{netcheckReport.portmap || t("common.none")}</span>
                  ) : (
                    <span className="text-kumo-subtle">—</span>
                  )}
                </DetailItem>
              </DetailList>
            </SectionCard>

            <SectionCard title={t("overview.section.routes")}>
              <div className="grid gap-3">
                <div className="grid gap-1.5">
                  <span className="text-xs font-medium text-kumo-subtle">
                    {t("overview.field.advertisedRoutes")}
                  </span>
                  {status.routes.length > 0 ? (
                    <ul className="flex flex-wrap gap-2">
                      {status.routes.map((route) => (
                        <li
                          key={route.cidr}
                          className="inline-flex items-center gap-1.5 rounded-md border border-kumo-line bg-kumo-recessed px-2 py-1 text-xs"
                        >
                          <span className="font-mono">{route.cidr}</span>
                          <Badge variant={route.approved ? "success" : "warning"}>
                            {route.approved
                              ? t("overview.route.approved")
                              : t("overview.route.pending")}
                          </Badge>
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <span className="text-sm text-kumo-subtle">{t("common.none")}</span>
                  )}
                </div>

                <DetailList>
                  <DetailItem label={t("overview.field.exitNode")}>
                    {!status.exit_node.advertised ? (
                      <span className="text-kumo-subtle">{t("overview.exitNode.off")}</span>
                    ) : (
                      <Badge variant={status.exit_node.approved ? "success" : "warning"}>
                        {status.exit_node.approved
                          ? t("overview.exitNode.approved")
                          : t("overview.exitNode.pending")}
                      </Badge>
                    )}
                  </DetailItem>
                  <DetailItem label={t("overview.field.acceptRoutes")}>
                    <Badge variant={status.prefs?.accept_routes ? "info" : "secondary"}>
                      {status.prefs?.accept_routes ? t("common.enabled") : t("common.disabled")}
                    </Badge>
                  </DetailItem>
                </DetailList>

                {anyRoutePending && (
                  <div className="text-xs text-kumo-subtle">
                    {self?.official !== false ? (
                      <a
                        href={OFFICIAL_CONSOLE_URL}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="inline-flex items-center gap-1 font-medium text-kumo-link underline"
                      >
                        {t("overview.route.approveOfficial")}
                        <ArrowSquareOutIcon size={12} aria-hidden />
                      </a>
                    ) : (
                      <span>{t("overview.route.approveCustom")}</span>
                    )}
                  </div>
                )}
              </div>
            </SectionCard>
          </div>

          {/* Version & Health */}
          <div className="grid gap-4 @xl:grid-cols-2">
            <SectionCard title={t("overview.section.version")}>
              <DetailList>
                <DetailItem label={t("overview.field.pluginVersion")}>
                  {status.plugin.version}
                </DetailItem>
                <DetailItem label={t("overview.field.coreVersion")}>
                  {status.core.tailscale} (r{status.core.revision} · {status.core.arch})
                </DetailItem>
              </DetailList>
              {status.core.update ? (
                <Banner
                  variant="default"
                  size="sm"
                  title={t("overview.coreUpdateAvailable", {
                    version: status.core.update.tailscale,
                    revision: status.core.update.revision,
                  })}
                  action={
                    <Button size="sm" variant="secondary" onClick={() => setTab("core")}>
                      {t("overview.action.gotoCore")}
                    </Button>
                  }
                />
              ) : (
                <p className="text-xs text-kumo-subtle">{t("overview.coreUpToDate")}</p>
              )}
            </SectionCard>

            <SectionCard title={t("overview.section.health")}>
              {status.health.length === 0 && status.checks.length === 0 ? (
                <p className="text-sm text-kumo-success">{t("overview.health.clean")}</p>
              ) : (
                <div className="grid gap-2">
                  {status.checks.length > 0 && (
                    <div className="grid gap-1.5">
                      <span className="text-xs font-medium text-kumo-subtle">
                        {t("overview.health.checksHeading")}
                      </span>
                      {status.checks.map((code) => (
                        <Banner
                          key={code}
                          variant={code === "watchdog_gave_up" ? "error" : "alert"}
                          size="sm"
                          description={tCheck(code)}
                        />
                      ))}
                    </div>
                  )}
                  {status.health.length > 0 && (
                    <div className="grid gap-1.5">
                      <span className="text-xs font-medium text-kumo-subtle">
                        {t("overview.health.daemonHeading")}
                      </span>
                      <ul
                        data-raw-health="true"
                        className="grid gap-1 rounded-lg border border-kumo-line bg-kumo-recessed p-2.5 font-mono text-xs text-kumo-default"
                      >
                        {status.health.map((line, i) => (
                          <li key={i} className="[overflow-wrap:anywhere]">
                            {line}
                          </li>
                        ))}
                      </ul>
                    </div>
                  )}
                </div>
              )}
            </SectionCard>
          </div>
        </>
      )}

      {/* Health banners still visible in non-running error/conflict states when present */}
      {!presentation.showOverviewDetails && (status.health.length > 0 || status.checks.length > 0) && (
        <SectionCard title={t("overview.section.health")}>
          <div className="grid gap-2">
            {status.checks.map((code) => (
              <Banner
                key={code}
                variant={code === "watchdog_gave_up" ? "error" : "alert"}
                size="sm"
                description={tCheck(code)}
              />
            ))}
            {status.health.length > 0 && (
              <ul
                data-raw-health="true"
                className="grid gap-1 rounded-lg border border-kumo-line bg-kumo-recessed p-2.5 font-mono text-xs text-kumo-default"
              >
                {status.health.map((line, i) => (
                  <li key={i} className="[overflow-wrap:anywhere]">
                    {line}
                  </li>
                ))}
              </ul>
            )}
          </div>
        </SectionCard>
      )}

      {confirmState && (
        <ConfirmDialog
          open={true}
          anchor={confirmState.anchor}
          onOpenChange={(open) => {
            if (!open) setConfirmState(null);
          }}
          title={
            confirmState.kind === "logout"
              ? t("overview.logoutConfirmTitle")
              : confirmState.kind === "relogin"
                ? t("overview.reloginConfirmTitle")
                : t("migrate.confirmTitle")
          }
          description={
            confirmState.kind === "logout"
              ? t("overview.logoutConfirmDesc")
              : confirmState.kind === "relogin"
                ? t("overview.reloginConfirmDesc")
                : t("migrate.confirmDesc")
          }
          confirmVariant={confirmState.kind === "logout" ? "destructive" : "primary"}
          disruptive={confirmState.kind !== "logout"}
          onConfirm={() => executeConfirm(confirmState.kind)}
        />
      )}
    </div>
  );
}
