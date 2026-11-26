import { useEffect, useRef, useState } from "react";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Select } from "@cloudflare/kumo/components/select";
import { useApp } from "../app/context";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { JobProgress } from "../components/JobProgress";
import { SectionCard } from "../components/SectionCard";
import { SwitchSettingRow, TextSettingRow } from "../components/SettingRows";
import { api } from "../core/api";
import type { SettingKey, SnatMode } from "../core/types";
import {
  findOverlappingPeerRoutes,
  isAccessingFromTailnet,
  validHostname,
  validMirror,
  validPort,
} from "../core/validate";
import { AdvertiseRoutesField } from "./settings/AdvertiseRoutesField";

interface PendingConfirm {
  anchor: HTMLElement | null;
  title: string;
  description: string;
  disruptive: boolean;
  confirmVariant?: "primary" | "destructive";
  run: () => Promise<void>;
}

export function SettingsPage() {
  const { status, overlays, busy, jobs, runJob, reloadStatus, notify, t, tError } = useApp();

  const daemonRunning = status?.daemon.running ?? false;
  const prefs = status?.prefs ?? null;
  const prefsReady = daemonRunning && prefs !== null;
  const settings = status?.settings;
  const lanCidr = status?.lan.cidr ?? "";

  const [readBackRoutes, setReadBackRoutes] = useState<string[] | null>(prefs?.advertise_routes ?? null);
  const [routesDraft, setRoutesDraft] = useState<string[]>([]);
  const [hostnameDraft, setHostnameDraft] = useState("");
  const [portDraft, setPortDraft] = useState("41641");
  const [mirrorDraft, setMirrorDraft] = useState("");

  const [savingKey, setSavingKey] = useState<SettingKey | null>(null);
  const [fieldErrors, setFieldErrors] = useState<Partial<Record<SettingKey, string>>>({});
  const [pendingConfirm, setPendingConfirm] = useState<PendingConfirm | null>(null);

  const acceptRoutesRef = useRef<HTMLSpanElement>(null);
  const localAccessRef = useRef<HTMLSpanElement>(null);
  const noLogsRef = useRef<HTMLSpanElement>(null);

  const syncedRoutesKey = prefs?.advertise_routes.join(",") ?? null;
  useEffect(() => {
    const routes = syncedRoutesKey ? syncedRoutesKey.split(",") : [];
    setReadBackRoutes(syncedRoutesKey === null ? null : routes);
    setRoutesDraft(routes);
  }, [syncedRoutesKey]);

  const syncedHostname = prefs?.hostname ?? "";
  useEffect(() => {
    setHostnameDraft(syncedHostname);
  }, [syncedHostname]);

  const syncedPort = settings ? String(settings.port) : "41641";
  useEffect(() => {
    setPortDraft(syncedPort);
  }, [syncedPort]);

  const syncedMirror = settings?.mirror ?? "";
  useEffect(() => {
    setMirrorDraft(syncedMirror);
  }, [syncedMirror]);

  if (!status || !settings) return null;

  const isDisabled = busy || savingKey !== null;
  const prefsDisabled = !prefsReady || isDisabled;

  function setFieldError(key: SettingKey, message: string | undefined) {
    setFieldErrors((prev) => ({ ...prev, [key]: message }));
  }

  async function commitSetting(key: SettingKey, value: string) {
    setFieldError(key, undefined);
    setSavingKey(key);
    try {
      const res = await api.set(key, value);
      if (res.job) {
        await runJob(res.job, async () => res);
      } else {
        if (key === "advertise_routes" && Array.isArray(res.value)) {
          setRoutesDraft(res.value);
          setReadBackRoutes(res.value);
        } else if (key === "hostname" && typeof res.value === "string") {
          setHostnameDraft(res.value);
        } else if (key === "port" && typeof res.value === "number") {
          setPortDraft(String(res.value));
        } else if (key === "mirror" && typeof res.value === "string") {
          setMirrorDraft(res.value);
        }
        await reloadStatus();
        notify({ title: t("common.saved"), variant: "success" });
      }
    } catch (err) {
      const msg = tError(err);
      setFieldError(key, msg);
      notify({ title: msg, variant: "error" });
    } finally {
      setSavingKey(null);
    }
  }

  function handleToggleAcceptRoutes(checked: boolean) {
    if (!checked) {
      void commitSetting("accept_routes", "0");
      return;
    }
    const overlaps = findOverlappingPeerRoutes(lanCidr, status!.peers);
    if (overlaps.length > 0) {
      const conflicts = overlaps.map((o) => `${o.peer} (${o.cidr})`).join(", ");
      setPendingConfirm({
        anchor: acceptRoutesRef.current,
        title: t("settings.acceptRoutes.overlapTitle"),
        description: t("settings.acceptRoutes.overlapDesc", { lan: lanCidr, conflicts }),
        disruptive: true,
        confirmVariant: "destructive",
        run: () => commitSetting("accept_routes", "1"),
      });
      return;
    }
    void commitSetting("accept_routes", "1");
  }

  function handleToggleLocalAccess(checked: boolean) {
    if (checked) {
      void commitSetting("local_access", "1");
      return;
    }
    if (isAccessingFromTailnet(window.location.hostname, status!.self)) {
      setPendingConfirm({
        anchor: localAccessRef.current,
        title: t("settings.localAccess.tailnetWarnTitle"),
        description: t("settings.localAccess.tailnetWarnDesc"),
        disruptive: true,
        confirmVariant: "destructive",
        run: () => commitSetting("local_access", "0"),
      });
      return;
    }
    void commitSetting("local_access", "0");
  }

  function handleSaveHostname() {
    const trimmed = hostnameDraft.trim();
    if (trimmed !== "" && !validHostname(trimmed)) {
      setFieldError("hostname", t("validate.hostname"));
      return;
    }
    void commitSetting("hostname", trimmed);
  }

  function handleSavePort(anchor: HTMLElement) {
    const trimmed = portDraft.trim();
    if (!validPort(trimmed)) {
      setFieldError("port", t("validate.port"));
      return;
    }
    setPendingConfirm({
      anchor,
      title: t("settings.port.confirmTitle"),
      description: t("settings.port.confirmDesc", { port: trimmed }),
      disruptive: true,
      run: () => commitSetting("port", trimmed),
    });
  }

  function handleToggleNoLogs(checked: boolean) {
    if (settings!.no_logs_forced) return;
    setPendingConfirm({
      anchor: noLogsRef.current,
      title: t("settings.noLogs.confirmTitle"),
      description: t("settings.noLogs.confirmDesc"),
      disruptive: true,
      run: () => commitSetting("no_logs", checked ? "1" : "0"),
    });
  }

  function handleSaveMirror() {
    const trimmed = mirrorDraft.trim();
    if (trimmed !== "" && !validMirror(trimmed)) {
      setFieldError("mirror", t("validate.mirror"));
      return;
    }
    void commitSetting("mirror", trimmed);
  }

  const snatItems: Record<SnatMode, string> = {
    auto: t("settings.snat.auto"),
    on: t("settings.snat.on"),
    off: t("settings.snat.off"),
  };

  return (
    <div className="grid gap-4">
      {!daemonRunning ? (
        <Banner variant="alert" description={t("settings.daemonRequiredBanner")} />
      ) : (
        !prefsReady && (
          <Banner variant="alert" description={t("settings.prefsUnavailableBanner")} />
        )
      )}

      {jobs.daemon?.running && <JobProgress job={jobs.daemon} />}

      <SectionCard title={t("settings.group.routing")}>
        <div className="grid gap-5">
          <AdvertiseRoutesField
            lanCidr={lanCidr}
            routesDraft={routesDraft}
            readBackRoutes={readBackRoutes}
            routeStatuses={status.routes}
            disabled={prefsDisabled}
            saving={savingKey === "advertise_routes"}
            error={fieldErrors.advertise_routes}
            onChangeDraft={setRoutesDraft}
            onError={(msg) => setFieldError("advertise_routes", msg)}
            onSave={() => void commitSetting("advertise_routes", routesDraft.join(","))}
          />
          <SwitchSettingRow
            label={t("settings.exitNode.label")}
            description={t("settings.exitNode.desc")}
            checked={prefs?.advertise_exit_node ?? null}
            disabled={prefsDisabled}
            error={fieldErrors.advertise_exit_node}
            onCheckedChange={(checked) => {
              void commitSetting("advertise_exit_node", checked ? "1" : "0");
            }}
          />
          <SwitchSettingRow
            label={t("settings.acceptRoutes.label")}
            description={t("settings.acceptRoutes.desc")}
            checked={prefs?.accept_routes ?? null}
            disabled={prefsDisabled}
            error={fieldErrors.accept_routes}
            divider={false}
            anchorRef={acceptRoutesRef}
            onCheckedChange={handleToggleAcceptRoutes}
          />
        </div>
      </SectionCard>

      <SectionCard title={t("settings.group.access")}>
        <div className="grid gap-5">
          <SwitchSettingRow
            label={t("settings.localAccess.label")}
            description={t("settings.localAccess.desc")}
            checked={settings.local_access}
            disabled={isDisabled}
            error={fieldErrors.local_access}
            anchorRef={localAccessRef}
            onCheckedChange={handleToggleLocalAccess}
          />
          <SwitchSettingRow
            label={t("settings.lanMasq.label")}
            description={t("settings.lanMasq.desc")}
            checked={settings.lan_masq}
            disabled={isDisabled}
            error={fieldErrors.lan_masq}
            onCheckedChange={(checked) => {
              void commitSetting("lan_masq", checked ? "1" : "0");
            }}
          />
          <div className="grid gap-2 border-b border-kumo-line pb-5">
            <Select<SnatMode>
              id="setting-snat"
              label={t("settings.snat.label")}
              description={t("settings.snat.desc", {
                effective: settings.snat_effective ? t("common.enabled") : t("common.disabled"),
              })}
              items={snatItems}
              value={settings.snat}
              modal={false}
              container={overlays}
              disabled={isDisabled}
              className="w-full @md:w-72"
              onValueChange={(next) => {
                if (next && next !== settings.snat) {
                  void commitSetting("snat", next);
                }
              }}
            />
            {fieldErrors.snat && (
              <Banner variant="error" role="alert" size="sm" title={fieldErrors.snat} />
            )}
          </div>
          <SwitchSettingRow
            label={t("settings.magicdns.label")}
            description={
              status.dns.conf_dir ? t("settings.magicdns.desc") : t("settings.magicdns.noConfDir")
            }
            checked={settings.magicdns}
            disabled={!status.dns.conf_dir || isDisabled}
            error={fieldErrors.magicdns}
            divider={false}
            onCheckedChange={(checked) => {
              void commitSetting("magicdns", checked ? "1" : "0");
            }}
          />
        </div>
      </SectionCard>

      <SectionCard title={t("settings.group.other")}>
        <div className="grid gap-5">
          <TextSettingRow
            id="setting-hostname"
            label={t("settings.hostname.label")}
            description={t("settings.hostname.desc")}
            placeholder={t("settings.hostname.placeholder")}
            value={hostnameDraft}
            savedValue={syncedHostname}
            disabled={prefsDisabled}
            saving={savingKey === "hostname"}
            error={fieldErrors.hostname}
            onChange={(v) => {
              setHostnameDraft(v);
              setFieldError("hostname", undefined);
            }}
            onSave={() => handleSaveHostname()}
          />
          <TextSettingRow
            id="setting-port"
            label={t("settings.port.label")}
            description={t("settings.port.desc")}
            value={portDraft}
            savedValue={syncedPort}
            inputMode="numeric"
            disabled={isDisabled}
            saving={savingKey === "port"}
            error={fieldErrors.port}
            onChange={(v) => {
              setPortDraft(v);
              setFieldError("port", undefined);
            }}
            onSave={(anchor) => handleSavePort(anchor)}
          />
          <SwitchSettingRow
            label={t("settings.noLogs.label")}
            description={
              settings.no_logs_forced
                ? t("settings.noLogs.forcedNote")
                : t("settings.noLogs.desc")
            }
            checked={settings.no_logs_forced ? true : settings.no_logs}
            disabled={settings.no_logs_forced || isDisabled}
            error={fieldErrors.no_logs}
            anchorRef={noLogsRef}
            onCheckedChange={handleToggleNoLogs}
          />
          <TextSettingRow
            id="setting-mirror"
            label={t("settings.mirror.label")}
            description={t("settings.mirror.desc")}
            placeholder={t("settings.mirror.placeholder")}
            value={mirrorDraft}
            savedValue={syncedMirror}
            disabled={isDisabled}
            saving={savingKey === "mirror"}
            error={fieldErrors.mirror}
            divider={false}
            onChange={(v) => {
              setMirrorDraft(v);
              setFieldError("mirror", undefined);
            }}
            onSave={() => handleSaveMirror()}
          />
        </div>
      </SectionCard>

      {pendingConfirm && (
        <ConfirmDialog
          open={true}
          anchor={pendingConfirm.anchor}
          onOpenChange={(open) => {
            if (!open) setPendingConfirm(null);
          }}
          title={pendingConfirm.title}
          description={pendingConfirm.description}
          disruptive={pendingConfirm.disruptive}
          confirmVariant={pendingConfirm.confirmVariant}
          onConfirm={async () => {
            const action = pendingConfirm.run;
            setPendingConfirm(null);
            await action();
          }}
        />
      )}
    </div>
  );
}
