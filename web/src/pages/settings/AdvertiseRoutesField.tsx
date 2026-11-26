import { useState } from "react";
import { PlusIcon } from "@phosphor-icons/react/dist/csr/Plus";
import { XIcon } from "@phosphor-icons/react/dist/csr/X";
import { Badge } from "@cloudflare/kumo/components/badge";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { Checkbox } from "@cloudflare/kumo/components/checkbox";
import { Input } from "@cloudflare/kumo/components/input";
import { useApp } from "../../app/context";
import { CHECKBOX_RING } from "../../components/checkbox";
import type { RouteStatus } from "../../core/types";
import { validCidr4 } from "../../core/validate";

export function AdvertiseRoutesField({
  lanCidr,
  routesDraft,
  readBackRoutes,
  routeStatuses,
  disabled,
  saving,
  error,
  onChangeDraft,
  onError,
  onSave,
}: {
  lanCidr: string;
  routesDraft: string[];
  readBackRoutes: string[] | null;
  routeStatuses: readonly RouteStatus[];
  disabled: boolean;
  saving: boolean;
  error?: string;
  onChangeDraft: (next: string[]) => void;
  onError: (msg: string | undefined) => void;
  onSave: () => void;
}) {
  const { t } = useApp();
  const [routeInput, setRouteInput] = useState("");
  const routeApprovalMap = new Map(routeStatuses.map((r) => [r.cidr, r.approved]));
  const unchanged = readBackRoutes !== null && routesDraft.join(",") === readBackRoutes.join(",");

  function addRoute() {
    const trimmed = routeInput.trim();
    if (!validCidr4(trimmed)) {
      onError(t("validate.cidr"));
      return;
    }
    if (routesDraft.includes(trimmed)) {
      onError(t("validate.cidrDuplicate"));
      return;
    }
    if (routesDraft.length >= 16) {
      onError(t("validate.cidrMax"));
      return;
    }
    onError(undefined);
    onChangeDraft([...routesDraft, trimmed]);
    setRouteInput("");
  }

  function toggleLanRoute(checked: boolean) {
    if (!lanCidr || !validCidr4(lanCidr)) return;
    onError(undefined);
    if (checked) {
      if (!routesDraft.includes(lanCidr)) {
        if (routesDraft.length >= 16) {
          onError(t("validate.cidrMax"));
          return;
        }
        onChangeDraft([lanCidr, ...routesDraft]);
      }
    } else {
      onChangeDraft(routesDraft.filter((item) => item !== lanCidr));
    }
  }

  return (
    <div className="grid gap-3 border-b border-kumo-line pb-5">
      <div className="grid gap-1">
        <h3 className="text-sm font-medium text-kumo-strong">
          {t("settings.advertiseRoutes.label")}
        </h3>
        <p className="text-xs text-kumo-subtle">{t("settings.advertiseRoutes.desc")}</p>
      </div>

      {lanCidr && validCidr4(lanCidr) && (
        <Checkbox
          className={CHECKBOX_RING}
          label={t("settings.advertiseRoutes.useLan", { cidr: lanCidr })}
          checked={routesDraft.includes(lanCidr)}
          disabled={disabled}
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
            disabled={disabled}
            onChange={(e) => {
              setRouteInput(e.target.value);
              onError(undefined);
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
          disabled={disabled || routeInput.trim() === ""}
          onClick={addRoute}
        >
          <PlusIcon size={16} aria-hidden />
          {t("settings.advertiseRoutes.add")}
        </Button>
      </div>

      {routesDraft.length === 0 && readBackRoutes !== null ? (
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
                  disabled={disabled}
                  aria-label={t("settings.advertiseRoutes.remove", { cidr })}
                  onClick={() => {
                    onError(undefined);
                    onChangeDraft(routesDraft.filter((item) => item !== cidr));
                  }}
                >
                  <XIcon size={12} aria-hidden />
                </Button>
              </li>
            );
          })}
        </ul>
      )}

      {error && <Banner variant="error" role="alert" size="sm" title={error} />}

      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-xs text-kumo-subtle">
          {t("settings.advertiseRoutes.current", {
            value: readBackRoutes === null ? t("common.unknown") : readBackRoutes.join(", ") || t("common.none"),
          })}
        </span>
        <Button
          variant="secondary"
          loading={saving}
          disabled={disabled || unchanged}
          aria-label={`${t("common.save")} ${t("settings.advertiseRoutes.label")}`}
          onClick={onSave}
        >
          {t("common.save")}
        </Button>
      </div>
    </div>
  );
}
