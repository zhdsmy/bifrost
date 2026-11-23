import { useEffect, useRef, useState } from "react";
import { PlusIcon } from "@phosphor-icons/react/dist/csr/Plus";
import { XIcon } from "@phosphor-icons/react/dist/csr/X";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { Checkbox } from "@cloudflare/kumo/components/checkbox";
import { Input } from "@cloudflare/kumo/components/input";
import { Select } from "@cloudflare/kumo/components/select";
import { Switch } from "@cloudflare/kumo/components/switch";
import { useApp } from "../app/context";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { JobProgress } from "../components/JobProgress";
import { SectionCard } from "../components/SectionCard";
import { api } from "../core/api";
import type { SettingKey, SnatMode } from "../core/types";
import {
  findOverlappingPeerRoutes,
  isAccessingFromTailnet,
  validCidr4,
  validHostname,
  validMirror,
  validPort,
} from "../core/validate";

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
  const settings = status?.settings;
  const lanCidr = status?.lan.cidr ?? "";

  const [routesDraft, setRoutesDraft] = useState<string[]>([]);
  const [routeInput, setRouteInput] = useState("");
  const [hostnameDraft, setHostnameDraft] = useState("");
  const [portDraft, setPortDraft] = useState("41641");
  const [mirrorDraft, setMirrorDraft] = useState("");

  const [savingKey, setSavingKey] = useState<SettingKey | null>(null);
  const [fieldErrors, setFieldErrors] = useState<Partial<Record<SettingKey, string>>>({});
  const [pendingConfirm, setPendingConfirm] = useState<PendingConfirm | null>(null);
  const acceptRoutesRef = useRef<HTMLSpanElement>(null);
  const localAccessRef = useRef<HTMLSpanElement>(null);
  const noLogsRef = useRef<HTMLSpanElement>(null);

  // Sync draft text fields from read-back status values whenever they change on the router.
  const syncedRoutesKey = (prefs?.advertise_routes ?? []).join(",");
  useEffect(() => {
    setRoutesDraft(syncedRoutesKey ? syncedRoutesKey.split(",") : []);
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

  function addRoute() {
    const trimmed = routeInput.trim();
    if (!validCidr4(trimmed)) {
      setFieldError("advertise_routes", t("validate.cidr"));
      return;
    }
    if (routesDraft.includes(trimmed)) {
      setFieldError("advertise_routes", t("validate.cidrDuplicate"));
      return;
    }
    if (routesDraft.length >= 16) {
      setFieldError("advertise_routes", t("validate.cidrMax"));
      return;
    }
    setFieldError("advertise_routes", undefined);
    setRoutesDraft((prev) => [...prev, trimmed]);
    setRouteInput("");
  }

  function removeRoute(cidr: string) {
    setFieldError("advertise_routes", undefined);
    setRoutesDraft((prev) => prev.filter((item) => item !== cidr));
  }

  function toggleLanRoute(checked: boolean) {
    if (!lanCidr || !validCidr4(lanCidr)) return;
    setFieldError("advertise_routes", undefined);
    if (checked) {
      if (!routesDraft.includes(lanCidr)) {
        if (routesDraft.length >= 16) {
          setFieldError("advertise_routes", t("validate.cidrMax"));
          return;
        }
        setRoutesDraft((prev) => [lanCidr, ...prev]);
      }
    } else {
      setRoutesDraft((prev) => prev.filter((item) => item !== lanCidr));
    }
  }

  function handleSaveRoutes() {
    if (routesDraft.length > 16) {
      setFieldError("advertise_routes", t("validate.cidrMax"));
      return;
    }
    for (const cidr of routesDraft) {
      if (!validCidr4(cidr)) {
        setFieldError("advertise_routes", t("validate.cidr"));
        return;
      }
    }
    void commitSetting("advertise_routes", routesDraft.join(","));
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

  const routeApprovalMap = new Map(status.routes.map((r) => [r.cidr, r.approved]));
  const snatItems: Record<SnatMode, string> = {
    auto: t("settings.snat.auto"),
    on: t("settings.snat.on"),
    off: t("settings.snat.off"),
  };

  return (
    <div className="grid gap-4">
      {!daemonRunning && (
        <Banner variant="alert" description={t("settings.daemonRequiredBanner")} />
      )}

      {jobs.daemon?.running && <JobProgress job={jobs.daemon} />}

      {/* Group 1: Routing */}
      <SectionCard title={t("settings.group.routing")}>
        <div className="grid gap-5">
          {/* Advertise Routes */}
          <div className="grid gap-3 border-b border-kumo-line pb-5">
            <div className="grid gap-1">
              <h3 className="text-sm font-medium text-kumo-strong">
                {t("settings.advertiseRoutes.label")}
              </h3>
              <p className="text-xs text-kumo-subtle">{t("settings.advertiseRoutes.desc")}</p>
            </div>

            {lanCidr && validCidr4(lanCidr) && (
              <Checkbox
                label={t("settings.advertiseRoutes.useLan", { cidr: lanCidr })}
                checked={routesDraft.includes(lanCidr)}
                disabled={!daemonRunning || isDisabled}
                onCheckedChange={(checked) => toggleLanRoute(checked)}
              />
            )}

            <div className="flex flex-wrap items-center gap-2">
              <div className="min-w-0 flex-1">
                <Input
                  id="setting-advertise-routes-input"
                  aria-label={t("settings.advertiseRoutes.label")}
                  placeholder={t("settings.advertiseRoutes.placeholder")}
                  className="w-full"
                  value={routeInput}
                  disabled={!daemonRunning || isDisabled}
                  onChange={(e) => {
                    setRouteInput(e.target.value);
                    setFieldError("advertise_routes", undefined);
                  }}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") {
                      e.preventDefault();
                      addRoute();
                    }
                  }}
                  autoComplete="off"
                  spellCheck={false}
                />
              </div>
              <Button
                variant="secondary"
                disabled={!daemonRunning || isDisabled || routeInput.trim() === ""}
                onClick={addRoute}
              >
                <PlusIcon size={16} aria-hidden />
                {t("settings.advertiseRoutes.add")}
              </Button>
            </div>

            {routesDraft.length === 0 ? (
              <p className="text-xs text-kumo-subtle">{t("settings.advertiseRoutes.empty")}</p>
            ) : (
              <ul className="flex flex-wrap gap-2">
                {routesDraft.map((cidr) => {
                  const approved = routeApprovalMap.get(cidr);
                  return (
                    <li
                      key={cidr}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-kumo-line bg-kumo-recessed px-2.5 py-1 text-xs"
                    >
                      <span className="font-mono text-kumo-default">{cidr}</span>
                      {approved !== undefined && (
                        <Badge variant={approved ? "success" : "warning"}>
                          {approved ? t("overview.route.approved") : t("overview.route.pending")}
                        </Badge>
                      )}
                      <Button
                        size="xs"
                        variant="ghost"
                        shape="square"
                        disabled={!daemonRunning || isDisabled}
                        aria-label={t("settings.advertiseRoutes.remove", { cidr })}
                        onClick={() => removeRoute(cidr)}
                      >
                        <XIcon size={12} aria-hidden />
                      </Button>
                    </li>
                  );
                })}
              </ul>
            )}

            {fieldErrors.advertise_routes && (
              <Banner variant="error" role="alert" size="sm" title={fieldErrors.advertise_routes} />
            )}

            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className="text-xs text-kumo-subtle">
                {t("settings.advertiseRoutes.current", {
                  value: prefs?.advertise_routes.length
                    ? prefs.advertise_routes.join(", ")
                    : t("common.none"),
                })}
              </span>
              <Button
                variant="primary"
                size="sm"
                loading={savingKey === "advertise_routes"}
                disabled={!daemonRunning || isDisabled}
                onClick={handleSaveRoutes}
              >
                {t("common.save")}
              </Button>
            </div>
          </div>

          {/* Advertise Exit Node */}
          <div className="grid gap-2 border-b border-kumo-line pb-5">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="grid min-w-0 flex-1 gap-0.5">
                <span className="text-sm font-medium text-kumo-strong">
                  {t("settings.exitNode.label")}
                </span>
                <span className="text-xs text-kumo-subtle">{t("settings.exitNode.desc")}</span>
              </div>
              <Switch
                aria-label={t("settings.exitNode.label")}
                checked={prefs?.advertise_exit_node ?? false}
                disabled={!daemonRunning || isDisabled}
                onCheckedChange={(checked) => {
                  void commitSetting("advertise_exit_node", checked ? "1" : "0");
                }}
              />
            </div>
            {fieldErrors.advertise_exit_node && (
              <Banner variant="error" role="alert" size="sm" title={fieldErrors.advertise_exit_node} />
            )}
          </div>

          {/* Accept Routes */}
          <div className="grid gap-2">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="grid min-w-0 flex-1 gap-0.5">
                <span className="text-sm font-medium text-kumo-strong">
                  {t("settings.acceptRoutes.label")}
                </span>
                <span className="text-xs text-kumo-subtle">{t("settings.acceptRoutes.desc")}</span>
              </div>
              <span ref={acceptRoutesRef}>
                <Switch
                  aria-label={t("settings.acceptRoutes.label")}
                  checked={prefs?.accept_routes ?? false}
                  disabled={!daemonRunning || isDisabled}
                  onCheckedChange={handleToggleAcceptRoutes}
                />
              </span>
            </div>
            {fieldErrors.accept_routes && (
              <Banner variant="error" role="alert" size="sm" title={fieldErrors.accept_routes} />
            )}
          </div>
        </div>
      </SectionCard>

      {/* Group 2: Access Control */}
      <SectionCard title={t("settings.group.access")}>
        <div className="grid gap-5">
          {/* Local Access */}
          <div className="grid gap-2 border-b border-kumo-line pb-5">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="grid min-w-0 flex-1 gap-0.5">
                <span className="text-sm font-medium text-kumo-strong">
                  {t("settings.localAccess.label")}
                </span>
                <span className="text-xs text-kumo-subtle">{t("settings.localAccess.desc")}</span>
              </div>
              <span ref={localAccessRef}>
                <Switch
                  aria-label={t("settings.localAccess.label")}
                  checked={settings.local_access}
                  disabled={isDisabled}
                  onCheckedChange={handleToggleLocalAccess}
                />
              </span>
            </div>
            {fieldErrors.local_access && (
              <Banner variant="error" role="alert" size="sm" title={fieldErrors.local_access} />
            )}
          </div>

          {/* LAN Masq */}
          <div className="grid gap-2 border-b border-kumo-line pb-5">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="grid min-w-0 flex-1 gap-0.5">
                <span className="text-sm font-medium text-kumo-strong">
                  {t("settings.lanMasq.label")}
                </span>
                <span className="text-xs text-kumo-subtle">{t("settings.lanMasq.desc")}</span>
              </div>
              <Switch
                aria-label={t("settings.lanMasq.label")}
                checked={settings.lan_masq}
                disabled={isDisabled}
                onCheckedChange={(checked) => {
                  void commitSetting("lan_masq", checked ? "1" : "0");
                }}
              />
            </div>
            {fieldErrors.lan_masq && (
              <Banner variant="error" role="alert" size="sm" title={fieldErrors.lan_masq} />
            )}
          </div>

          {/* SNAT */}
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

          {/* MagicDNS */}
          <div className="grid gap-2">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="grid min-w-0 flex-1 gap-0.5">
                <span className="text-sm font-medium text-kumo-strong">
                  {t("settings.magicdns.label")}
                </span>
                <span className="text-xs text-kumo-subtle">
                  {status.dns.conf_dir
                    ? t("settings.magicdns.desc")
                    : t("settings.magicdns.noConfDir")}
                </span>
              </div>
              <Switch
                aria-label={t("settings.magicdns.label")}
                checked={settings.magicdns}
                disabled={!status.dns.conf_dir || isDisabled}
                onCheckedChange={(checked) => {
                  void commitSetting("magicdns", checked ? "1" : "0");
                }}
              />
            </div>
            {fieldErrors.magicdns && (
              <Banner variant="error" role="alert" size="sm" title={fieldErrors.magicdns} />
            )}
          </div>
        </div>
      </SectionCard>

      {/* Group 3: Other */}
      <SectionCard title={t("settings.group.other")}>
        <div className="grid gap-5">
          {/* Device Name */}
          <div className="grid gap-1.5 border-b border-kumo-line pb-5">
            <label htmlFor="setting-hostname" className="text-sm font-medium text-kumo-strong">
              {t("settings.hostname.label")}
            </label>
            <div className="flex flex-wrap items-center gap-2">
              <div className="min-w-0 flex-1">
                <Input
                  id="setting-hostname"
                  aria-label={t("settings.hostname.label")}
                  placeholder={t("settings.hostname.placeholder")}
                  className="w-full"
                  value={hostnameDraft}
                  disabled={!daemonRunning || isDisabled}
                  onChange={(e) => {
                    setHostnameDraft(e.target.value);
                    setFieldError("hostname", undefined);
                  }}
                  autoComplete="off"
                  spellCheck={false}
                />
              </div>
              <Button
                variant="secondary"
                loading={savingKey === "hostname"}
                disabled={!daemonRunning || isDisabled}
                aria-label={`${t("common.save")} ${t("settings.hostname.label")}`}
                onClick={handleSaveHostname}
              >
                {t("common.save")}
              </Button>
            </div>
            <p className="text-xs text-kumo-subtle">{t("settings.hostname.desc")}</p>
            {fieldErrors.hostname && (
              <Banner variant="error" role="alert" size="sm" title={fieldErrors.hostname} />
            )}
          </div>

          {/* Listen Port */}
          <div className="grid gap-1.5 border-b border-kumo-line pb-5">
            <label htmlFor="setting-port" className="text-sm font-medium text-kumo-strong">
              {t("settings.port.label")}
            </label>
            <div className="flex flex-wrap items-center gap-2">
              <div className="min-w-0 flex-1">
                <Input
                  id="setting-port"
                  aria-label={t("settings.port.label")}
                  className="w-full"
                  value={portDraft}
                  inputMode="numeric"
                  disabled={isDisabled}
                  onChange={(e) => {
                    setPortDraft(e.target.value);
                    setFieldError("port", undefined);
                  }}
                  autoComplete="off"
                  spellCheck={false}
                />
              </div>
              <Button
                variant="secondary"
                loading={savingKey === "port"}
                disabled={isDisabled}
                aria-label={`${t("common.save")} ${t("settings.port.label")}`}
                onClick={(e) => handleSavePort(e.currentTarget)}
              >
                {t("common.save")}
              </Button>
            </div>
            <p className="text-xs text-kumo-subtle">{t("settings.port.desc")}</p>
            {fieldErrors.port && (
              <Banner variant="error" role="alert" size="sm" title={fieldErrors.port} />
            )}
          </div>

          {/* No Logs */}
          <div className="grid gap-2 border-b border-kumo-line pb-5">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="grid min-w-0 flex-1 gap-0.5">
                <span className="text-sm font-medium text-kumo-strong">
                  {t("settings.noLogs.label")}
                </span>
                <span className="text-xs text-kumo-subtle">
                  {settings.no_logs_forced
                    ? t("settings.noLogs.forcedNote")
                    : t("settings.noLogs.desc")}
                </span>
              </div>
              <span ref={noLogsRef}>
                <Switch
                  aria-label={t("settings.noLogs.label")}
                  checked={settings.no_logs_forced ? true : settings.no_logs}
                  disabled={settings.no_logs_forced || isDisabled}
                  onCheckedChange={handleToggleNoLogs}
                />
              </span>
            </div>
            {fieldErrors.no_logs && (
              <Banner variant="error" role="alert" size="sm" title={fieldErrors.no_logs} />
            )}
          </div>

          {/* Mirror */}
          <div className="grid gap-1.5">
            <label htmlFor="setting-mirror" className="text-sm font-medium text-kumo-strong">
              {t("settings.mirror.label")}
            </label>
            <div className="flex flex-wrap items-center gap-2">
              <div className="min-w-0 flex-1">
                <Input
                  id="setting-mirror"
                  aria-label={t("settings.mirror.label")}
                  placeholder={t("settings.mirror.placeholder")}
                  className="w-full"
                  value={mirrorDraft}
                  disabled={isDisabled}
                  onChange={(e) => {
                    setMirrorDraft(e.target.value);
                    setFieldError("mirror", undefined);
                  }}
                  autoComplete="off"
                  spellCheck={false}
                />
              </div>
              <Button
                variant="secondary"
                loading={savingKey === "mirror"}
                disabled={isDisabled}
                aria-label={`${t("common.save")} ${t("settings.mirror.label")}`}
                onClick={handleSaveMirror}
              >
                {t("common.save")}
              </Button>
            </div>
            <p className="text-xs text-kumo-subtle">{t("settings.mirror.desc")}</p>
            {fieldErrors.mirror && (
              <Banner variant="error" role="alert" size="sm" title={fieldErrors.mirror} />
            )}
          </div>
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
