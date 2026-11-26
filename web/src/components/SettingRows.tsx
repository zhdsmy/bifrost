import type { RefObject } from "react";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { Input } from "@cloudflare/kumo/components/input";
import { Switch } from "@cloudflare/kumo/components/switch";
import { useApp } from "../app/context";

export function SwitchSettingRow({
  label,
  description,
  checked,
  disabled,
  error,
  divider = true,
  anchorRef,
  onCheckedChange,
}: {
  label: string;
  description: string;
  checked: boolean | null;
  disabled: boolean;
  error?: string;
  divider?: boolean;
  anchorRef?: RefObject<HTMLSpanElement | null>;
  onCheckedChange: (checked: boolean) => void;
}) {
  const { t } = useApp();
  return (
    <div className={divider ? "grid gap-2 border-b border-kumo-line pb-5" : "grid gap-2"}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="grid min-w-0 flex-1 gap-0.5">
          <span className="text-sm font-medium text-kumo-strong">{label}</span>
          <span className="text-xs text-kumo-subtle">{description}</span>
        </div>
        <span ref={anchorRef}>
          {checked === null ? (
            <span className="text-xs text-kumo-subtle">{t("common.unknown")}</span>
          ) : (
            <Switch
              aria-label={label}
              checked={checked}
              disabled={disabled}
              onCheckedChange={onCheckedChange}
            />
          )}
        </span>
      </div>
      {error && <Banner variant="error" role="alert" size="sm" title={error} />}
    </div>
  );
}

export function TextSettingRow({
  id,
  label,
  description,
  placeholder,
  value,
  savedValue,
  inputMode,
  disabled,
  saving,
  error,
  divider = true,
  onChange,
  onSave,
}: {
  id: string;
  label: string;
  description: string;
  placeholder?: string;
  value: string;
  /** The stored value; Save stays disabled until the trimmed input differs. */
  savedValue: string;
  inputMode?: "text" | "numeric";
  disabled: boolean;
  saving: boolean;
  error?: string;
  divider?: boolean;
  onChange: (value: string) => void;
  onSave: (anchor: HTMLElement) => void;
}) {
  const { t } = useApp();
  return (
    <div className={divider ? "grid gap-1.5 border-b border-kumo-line pb-5" : "grid gap-1.5"}>
      <label htmlFor={id} className="text-sm font-medium text-kumo-strong">
        {label}
      </label>
      <div className="flex flex-wrap items-center gap-2">
        <div className="min-w-0 flex-1">
          <Input
            id={id}
            aria-label={label}
            placeholder={placeholder}
            className="w-full"
            value={value}
            inputMode={inputMode}
            disabled={disabled}
            onChange={(e) => onChange(e.target.value)}
            autoComplete="off"
            spellCheck={false}
          />
        </div>
        <Button
          variant="secondary"
          loading={saving}
          disabled={disabled || value.trim() === savedValue}
          aria-label={`${t("common.save")} ${label}`}
          onClick={(e) => onSave(e.currentTarget)}
        >
          {t("common.save")}
        </Button>
      </div>
      <p className="text-xs text-kumo-subtle">{description}</p>
      {error && <Banner variant="error" role="alert" size="sm" title={error} />}
    </div>
  );
}
