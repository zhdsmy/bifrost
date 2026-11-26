import { useState } from "react";
import { ArrowSquareOutIcon } from "@phosphor-icons/react/dist/csr/ArrowSquareOut";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { Collapsible } from "@cloudflare/kumo/components/collapsible";
import { Input } from "@cloudflare/kumo/components/input";
import { Loader } from "@cloudflare/kumo/components/loader";
import { useApp } from "../../app/context";
import { CopyField } from "../../components/CopyInline";
import { JobProgress } from "../../components/JobProgress";
import { QrCode } from "../../components/QrCode";
import { SectionCard } from "../../components/SectionCard";
import { api } from "../../core/api";
import type { JobProgressState, LoginJobData, StatusData } from "../../core/types";
import {
  isHttpLoginServer,
  isSafeHttpUrl,
  validAuthKey,
  validLoginServer,
} from "../../core/validate";

export function LoginCard({
  status,
  disabled,
}: {
  status: StatusData;
  disabled: boolean;
}) {
  const { jobs, runJob, notify, t } = useApp();
  const [serverDraft, setServerDraft] = useState("");
  const [authKeyDraft, setAuthKeyDraft] = useState("");
  const [validationError, setValidationError] = useState<string | null>(null);
  const [advancedOpen, setAdvancedOpen] = useState(false);

  const loginJob = jobs.login as JobProgressState<LoginJobData> | undefined;
  const loginDisabled = disabled || Boolean(loginJob?.running);
  const isCustomControl =
    status.self?.official === false ||
    loginJob?.data?.official === false ||
    serverDraft.trim() !== "";
  const loginExpired = !loginJob?.running && loginJob?.code === "login_expired";
  const hasAuthUrl = Boolean(status.auth_url) && !loginExpired;
  const safeAuthUrl = hasAuthUrl && isSafeHttpUrl(status.auth_url);

  async function handleStartLogin() {
    const server = serverDraft.trim();
    const authKey = authKeyDraft.trim();
    if (server !== "" && !validLoginServer(server)) {
      setValidationError(t("validate.server"));
      return;
    }
    if (authKey !== "" && !validAuthKey(authKey)) {
      setValidationError(t("validate.authKey"));
      return;
    }
    setValidationError(null);
    await runJob<LoginJobData>("login", () => api.login(server, authKey), {
      onDone: (final) => {
        if (final.ok) {
          setAuthKeyDraft("");
          notify({ title: t("common.actionSuccess"), variant: "success" });
        }
      },
    });
  }

  return (
    <SectionCard title={t("login.title")} description={t("login.subtitle")}>
      {loginExpired && (
        <Banner variant="alert" role="alert" title={t("login.expiredBanner")} />
      )}

      {hasAuthUrl && !safeAuthUrl && (
        <Banner variant="error" role="alert" title={t("login.unsafeUrlWarning")} />
      )}

      {safeAuthUrl && (
        <div className="grid gap-4 rounded-lg border border-kumo-line bg-kumo-recessed p-4">
          <div className="flex flex-wrap items-start gap-4">
            <QrCode value={status.auth_url} alt={t("login.qrAlt")} fallback={t("login.qrUnavailable")} />
            <div className="grid min-w-0 flex-1 gap-3">
              <h3 className="text-sm font-semibold text-kumo-strong">
                {t("login.qrHeading")}
              </h3>
              <CopyField text={status.auth_url} />
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
                <Loader size="sm" aria-label={t("common.loadingAction")} />
                <span>{t("login.waitingAuth")}</span>
              </div>
            </div>
          </div>
          {isCustomControl && (
            <Banner variant="default" size="sm" description={t("login.customServerNotice")} />
          )}
        </div>
      )}

      {loginJob && !loginExpired && !hasAuthUrl && (
        <JobProgress job={loginJob} label={t("login.startingNotice")} hideSuccess />
      )}

      {loginJob?.running && <p className="text-sm text-kumo-subtle">{t("login.jobWaiting")}</p>}

      <Collapsible.Root
        open={advancedOpen}
        onOpenChange={setAdvancedOpen}
        className="rounded-lg border border-kumo-line bg-kumo-recessed/50 px-3 py-2"
      >
        <Collapsible.DefaultTrigger className="w-full py-1 text-sm font-medium text-kumo-default">
          {t("login.advancedToggle")}
        </Collapsible.DefaultTrigger>
        <Collapsible.Panel className="grid gap-4 pt-3 pb-2">
          <Input
            id="login-control-server"
            label={t("login.serverLabel")}
            placeholder={t("login.serverPlaceholder")}
            description={t("login.serverDesc")}
            value={serverDraft}
            disabled={loginDisabled}
            onChange={(e) => {
              setServerDraft(e.target.value);
              setValidationError(null);
            }}
            autoComplete="off"
            spellCheck={false}
          />
          {isHttpLoginServer(serverDraft.trim()) && (
            <Banner variant="alert" size="sm" description={t("login.serverHttpWarn")} />
          )}
          <Input
            type="password"
            id="login-auth-key"
            label={t("login.authKeyLabel")}
            placeholder={t("login.authKeyPlaceholder")}
            description={t("login.authKeyDesc")}
            value={authKeyDraft}
            disabled={loginDisabled}
            onChange={(e) => {
              setAuthKeyDraft(e.target.value);
              setValidationError(null);
            }}
            autoComplete="off"
            passwordManagerIgnore
            spellCheck={false}
          />
        </Collapsible.Panel>
      </Collapsible.Root>

      {validationError && (
        <Banner variant="error" role="alert" size="sm" title={validationError} />
      )}

      <div className="flex flex-wrap gap-2">
        <Button
          variant="primary"
          disabled={loginDisabled}
          onClick={() => {
            void handleStartLogin();
          }}
        >
          {authKeyDraft.trim()
            ? t("login.startWithKeyButton")
            : loginExpired || hasAuthUrl
              ? t("login.retryButton")
              : t("login.startButton")}
        </Button>
      </div>
    </SectionCard>
  );
}
