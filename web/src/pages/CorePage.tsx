import { useState } from "react";
import { ArrowSquareOutIcon } from "@phosphor-icons/react/dist/csr/ArrowSquareOut";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { Collapsible } from "@cloudflare/kumo/components/collapsible";
import { useApp } from "../app/context";
import { ConfirmDialog } from "../components/ConfirmDialog";
import { CopyField } from "../components/CopyInline";
import { JobProgress } from "../components/JobProgress";
import { DetailItem, DetailList, SectionCard } from "../components/SectionCard";
import { api } from "../core/api";
import { CORE_VERIFY_COMMAND, formatBytes, formatDateTime, isCoreUpToDate } from "../core/format";
import type { CoreArch, CoreStorageKind, CoreVariant, JobProgressState, UpdateJobData } from "../core/types";

type CoreConfirmKind = "update" | "rollback" | "dropPrev" | { arch: CoreArch } | { variant: CoreVariant };

const STORAGE_KIND_KEYS = {
  internal: "core.storage.internal",
  external: "core.storage.external",
  unknown: "core.storage.unknown",
} as const satisfies Record<CoreStorageKind, string>;

interface CoreConfirmState {
  kind: CoreConfirmKind;
  anchor: HTMLElement;
}

export function CorePage() {
  const { status, busy, jobs, runJob, reloadStatus, notify, lang, t, tError } = useApp();
  const [confirmState, setConfirmState] = useState<CoreConfirmState | null>(null);
  const [droppingPrev, setDroppingPrev] = useState(false);

  if (!status) return null;

  const core = status.core;
  const build = core.build;
  const omit = Array.isArray(build?.omit) ? build.omit : null;
  const updateJob = jobs.update as JobProgressState<UpdateJobData> | undefined;
  // An update that found no newer core shows the up-to-date notice, not an error.
  const shownJob = updateJob?.code === "up_to_date" ? undefined : updateJob;
  const checkedLatest = updateJob?.ok && updateJob.data.action === "check" ? updateJob.data.latest : null;
  const latest = core.update ?? (checkedLatest && checkedLatest.serial > core.serial ? checkedLatest : null);
  const canSwitchArch = core.kernel_arch === "aarch64";
  const targetArch: CoreArch = core.arch === "arm64" ? "arm" : "arm64";
  const currentVariant: CoreVariant = core.variant ?? "normal";
  const targetVariant: CoreVariant = currentVariant === "upx" ? "normal" : "upx";
  const variantLabel = (v: CoreVariant) => t(v === "upx" ? "core.variant.upx" : "core.variant.normal");
  const upToDate = isCoreUpToDate(status, updateJob);
  const storage = core.storage;
  const internal = storage?.kind === "internal";
  const prevSize = core.prev_size ?? 0;
  const prevInfo = core.prev ? core.prev_info ?? null : null;
  const prevVersion = prevInfo?.tailscale
    ? prevInfo.revision > 0
      ? `${prevInfo.tailscale} r${prevInfo.revision}`
      : prevInfo.tailscale
    : null;
  // Internal flash never keeps a backup (the hint below explains it), so only
  // a skipped backup on other storage is unexpected enough for an alert.
  const lostPrev = Boolean(
    !internal &&
      updateJob &&
      !updateJob.running &&
      updateJob.ok === true &&
      updateJob.data?.action === "update" &&
      updateJob.data?.kept_prev === false,
  );
  const storageKind = t(STORAGE_KIND_KEYS[storage?.kind ?? "unknown"] ?? STORAGE_KIND_KEYS.unknown);
  const compressingFlash = internal && (storage?.fs === "jffs2" || storage?.fs === "ubifs");
  // Chinese sentences end with "。" and need no space between them.
  const upxHint = [
    t("core.variant.cost"),
    compressingFlash ? t("core.variant.internal") : "",
    storage?.kind === "external" ? t("core.variant.external") : "",
  ]
    .filter(Boolean)
    .join(lang === "zh-CN" ? "" : " ");

  async function runCoreMutation(trigger: () => Promise<unknown>) {
    await runJob<UpdateJobData>("update", trigger, {
      onDone: (final) => {
        if (final.ok) notify({ title: t("common.actionSuccess"), variant: "success" });
      },
    });
  }

  async function dropPrev() {
    setDroppingPrev(true);
    try {
      await api.coreDropPrev();
      await reloadStatus();
      notify({ title: t("common.actionSuccess"), variant: "success" });
    } catch (err) {
      notify({ title: tError(err), variant: "error" });
    } finally {
      setDroppingPrev(false);
    }
  }

  async function executeConfirm(kind: CoreConfirmKind) {
    setConfirmState(null);
    if (kind === "dropPrev") {
      await dropPrev();
    } else if (kind === "update") {
      await runCoreMutation(() => api.coreUpdate());
    } else if (kind === "rollback") {
      await runCoreMutation(() => api.coreRollback());
    } else {
      await runCoreMutation(() => "arch" in kind ? api.coreArch(kind.arch) : api.coreType(kind.variant));
    }
  }

  return (
    <div className="grid gap-4">
      <SectionCard title={t("core.section.current")}>
        <DetailList>
          <DetailItem label={t("core.field.version")}>{core.tailscale || "—"}</DetailItem>
          <DetailItem label={t("core.field.revision")}>
            {core.revision ? `r${core.revision} (#${core.serial})` : "—"}
          </DetailItem>
          <DetailItem label={t("core.field.arch")}>{core.arch || "—"}</DetailItem>
          <DetailItem label={t("core.field.kernelArch")}>{core.kernel_arch || "—"}</DetailItem>
          <DetailItem label={t("core.field.variant")}>{variantLabel(currentVariant)}</DetailItem>
          <DetailItem label={t("core.field.size")}>
            {core.size > 0 ? formatBytes(core.size) : "—"}
          </DetailItem>
          <DetailItem label={t("core.field.installed")}>
            {formatDateTime(core.installed)}
          </DetailItem>
          <DetailItem label={t("core.field.prev")}>
            {core.prev ? (
              <div className="flex flex-wrap items-center gap-2">
                <span>
                  {[
                    prevVersion ?? t("core.prev.available"),
                    prevInfo ? variantLabel(prevInfo.variant) : "",
                    prevInfo?.arch ?? "",
                    prevSize > 0 ? formatBytes(prevSize) : "",
                  ]
                    .filter(Boolean)
                    .join(" · ")}
                </span>
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={busy || droppingPrev}
                  loading={droppingPrev}
                  onClick={(e) => setConfirmState({ kind: "dropPrev", anchor: e.currentTarget })}
                >
                  {t("core.action.dropPrev")}
                </Button>
              </div>
            ) : (
              <span className="text-kumo-subtle">{t("core.prev.missing")}</span>
            )}
          </DetailItem>
          <DetailItem label={t("core.field.storage")}>
            {storageKind}
            {storage?.fs && (
              <>
                {" · "}
                <span data-raw-value="true">{storage.fs}</span>
              </>
            )}
          </DetailItem>
          <DetailItem label={t("core.field.free")}>
            {storage?.free != null && storage.total != null
              ? t("core.storage.free", { free: formatBytes(storage.free), total: formatBytes(storage.total) })
              : "—"}
          </DetailItem>
        </DetailList>
      </SectionCard>

      <SectionCard title={t("core.section.actions")}>
        {latest && (
          <Banner
            variant="default"
            title={t("core.latestBanner", {
              version: latest.tailscale,
              revision: latest.revision,
              serial: latest.serial,
            })}
            action={
              <a
                href={`https://github.com/zhdsmy/bifrost/releases/tag/${encodeURIComponent(latest.tag)}`}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 text-sm font-medium text-kumo-link underline"
              >
                {t("core.releaseNotesLink")}
                <ArrowSquareOutIcon size={14} aria-hidden />
              </a>
            }
          />
        )}

        {status.plugin.update && (
          <Banner
            variant="default"
            title={t("core.pluginUpdateBanner", { version: status.plugin.update.version })}
            action={
              <a
                href={status.plugin.update.url}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 text-sm font-medium text-kumo-link underline"
              >
                {t("core.pluginReleaseLink")}
                <ArrowSquareOutIcon size={14} aria-hidden />
              </a>
            }
          />
        )}

        {upToDate && <Banner variant="secondary" size="sm" title={t("core.upToDateNotice")} />}

        {lostPrev && <Banner variant="alert" size="sm" title={t("core.noPrevAfterUpdate")} />}

        <JobProgress
          job={shownJob}
          label={t("core.progressLabel")}
          hideSuccess={upToDate || updateJob?.data?.action === "check"}
        />

        <div className="flex flex-wrap gap-2">
          <Button
            variant="secondary"
            disabled={busy}
            loading={updateJob?.running && updateJob.data?.action === "check"}
            onClick={() => {
              void runJob<UpdateJobData>("update", () => api.coreCheck());
            }}
          >
            {t("core.action.check")}
          </Button>
          <Button
            variant={latest ? "primary" : "secondary"}
            disabled={busy || upToDate}
            loading={updateJob?.running && updateJob.data?.action === "update"}
            onClick={(e) => setConfirmState({ kind: "update", anchor: e.currentTarget })}
          >
            {t("core.action.update")}
          </Button>
          <Button
            variant="secondary"
            disabled={busy || droppingPrev || !core.prev}
            loading={updateJob?.running && updateJob.data?.action === "rollback"}
            onClick={(e) => setConfirmState({ kind: "rollback", anchor: e.currentTarget })}
          >
            {t("core.action.rollback")}
          </Button>
        </div>

        {!core.prev && (
          <p className="text-xs text-kumo-subtle">{t(internal ? "core.noPrevInternal" : "core.noPrevHint")}</p>
        )}

        {(core.variant || canSwitchArch) && (
          <div className="grid gap-3 border-t border-kumo-hairline pt-4">
            <span className="text-xs font-medium text-kumo-subtle">{t("core.switch.title")}</span>
            <div className="flex flex-wrap gap-2">
              {core.variant && (
                <Button
                  variant="secondary"
                  disabled={busy}
                  loading={updateJob?.running && updateJob.data?.action === "type"}
                  onClick={(e) => setConfirmState({ kind: { variant: targetVariant }, anchor: e.currentTarget })}
                >
                  {targetVariant === "upx" ? t("core.action.switchUpx") : t("core.action.switchNormal")}
                </Button>
              )}
              {canSwitchArch && (
                <Button
                  variant="secondary"
                  disabled={busy}
                  loading={updateJob?.running && updateJob.data?.action === "arch"}
                  onClick={(e) => setConfirmState({ kind: { arch: targetArch }, anchor: e.currentTarget })}
                >
                  {targetArch === "arm64" ? t("core.action.switchArm64") : t("core.action.switchArm")}
                </Button>
              )}
            </div>
            {core.variant && <p className="text-xs text-kumo-subtle">{upxHint}</p>}
            {canSwitchArch && <p className="text-xs text-kumo-subtle">{t("core.arch.hint")}</p>}
          </div>
        )}
      </SectionCard>

      <SectionCard title={t("core.section.recipe")} description={t("core.recipe.desc")}>
        <DetailList>
          <DetailItem label={t("core.recipe.go")}>
            {build?.go ? <span data-raw-value="true">{build.go}</span> : t("common.unknown")}
          </DetailItem>
          <DetailItem label={t("core.recipe.commit")}>
            {build?.commit ? (
              <code data-raw-value="true" className="font-mono text-xs">
                {build.commit.slice(0, 12)}
              </code>
            ) : (
              t("common.unknown")
            )}
          </DetailItem>
        </DetailList>

        {omit && omit.length > 0 ? (
          <Collapsible.Root className="rounded-lg border border-kumo-line bg-kumo-recessed/50 px-3 py-2">
            <Collapsible.DefaultTrigger className="w-full py-1 text-sm font-medium text-kumo-default">
              {t("core.recipe.omit", { count: omit.length })}
            </Collapsible.DefaultTrigger>
            <Collapsible.DefaultPanel className="pt-3 pb-2">
              <div data-raw-value="true" className="flex flex-wrap gap-1.5">
                {omit.map((tag) => (
                  <Badge key={tag} variant="outline" className="border-kumo-line">
                    {tag}
                  </Badge>
                ))}
              </div>
            </Collapsible.DefaultPanel>
          </Collapsible.Root>
        ) : (
          <div className="grid gap-0.5">
            <span className="text-xs font-medium text-kumo-subtle">{t("core.recipe.omitLabel")}</span>
            <span className="text-sm text-kumo-subtle">{omit ? t("common.none") : t("common.unknown")}</span>
          </div>
        )}

        <div className="grid gap-1.5">
          <span className="text-xs font-medium text-kumo-subtle">{t("core.recipe.verify")}</span>
          <CopyField text={CORE_VERIFY_COMMAND} />
        </div>

        <div className="grid gap-1.5">
          <span className="text-xs font-medium text-kumo-subtle">{t("core.recipe.expected")}</span>
          {core.sha256 ? (
            <code
              data-raw-value="true"
              className="rounded-lg border border-kumo-line bg-kumo-recessed px-3 py-2 font-mono text-xs text-kumo-default [overflow-wrap:anywhere]"
            >
              {core.sha256}
            </code>
          ) : (
            <span className="text-sm text-kumo-subtle">{t("common.unknown")}</span>
          )}
        </div>
      </SectionCard>

      {confirmState && (
        <ConfirmDialog
          open={true}
          anchor={confirmState.anchor}
          onOpenChange={(open) => {
            if (!open) setConfirmState(null);
          }}
          title={
            confirmState.kind === "dropPrev"
              ? t("core.confirm.dropPrevTitle")
              : confirmState.kind === "update"
              ? t("core.confirm.updateTitle")
              : confirmState.kind === "rollback"
                ? t("core.confirm.rollbackTitle")
                : "arch" in confirmState.kind
                  ? t("core.confirm.archTitle", { arch: confirmState.kind.arch })
                  : t("core.confirm.typeTitle", { type: variantLabel(confirmState.kind.variant) })
          }
          description={
            confirmState.kind === "dropPrev"
              ? t("core.confirm.dropPrevDesc")
              : confirmState.kind === "update"
              ? t("core.confirm.updateDesc")
              : confirmState.kind === "rollback"
                ? prevVersion && prevInfo?.arch
                  ? t("core.confirm.rollbackDescTarget", {
                      version: prevVersion,
                      type: variantLabel(prevInfo.variant),
                      arch: prevInfo.arch,
                    })
                  : t("core.confirm.rollbackDesc")
                : "arch" in confirmState.kind
                  ? t("core.confirm.archDesc", { arch: confirmState.kind.arch })
                  : t("core.confirm.typeDesc", { type: variantLabel(confirmState.kind.variant) })
          }
          disruptive={confirmState.kind !== "dropPrev"}
          confirmVariant={confirmState.kind === "dropPrev" ? "destructive" : "primary"}
          onConfirm={() => executeConfirm(confirmState.kind)}
        />
      )}
    </div>
  );
}
