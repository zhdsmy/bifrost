// Non-modal confirmation popover anchored to the triggering control (PLAN 13.2 fallback).
// Kumo Dialog (Base UI 1.9.0) was tested inside Shadow DOM first: its backdrop covered the shell
// and Escape cleared it, but Tab escaped the ShadowRoot into the host document (#hidden_frame).
import { useId } from "react";
import { Banner } from "@cloudflare/kumo/components/banner";
import { Button } from "@cloudflare/kumo/components/button";
import { Popover } from "@cloudflare/kumo/components/popover";
import { useApp } from "../app/context";

export interface ConfirmDialogProps {
  open: boolean;
  anchor: HTMLElement | null;
  onOpenChange: (open: boolean) => void;
  title: string;
  description: string;
  confirmLabel?: string;
  confirmVariant?: "primary" | "destructive";
  disruptive?: boolean;
  onConfirm: () => void | Promise<void>;
}

export function ConfirmDialog({
  open,
  anchor,
  onOpenChange,
  title,
  description,
  confirmLabel,
  confirmVariant = "primary",
  disruptive = false,
  onConfirm,
}: ConfirmDialogProps) {
  const { overlays, t } = useApp();
  const titleId = useId();
  const descId = useId();

  return (
    <Popover.Root modal={false} open={open} onOpenChange={onOpenChange}>
      <Popover.Content
        anchor={anchor}
        container={overlays}
        positionMethod="fixed"
        side="bottom"
        align="end"
        className="z-50 w-80 max-w-[calc(100vw-2rem)] p-4"
      >
        <div
          role="alertdialog"
          aria-labelledby={titleId}
          aria-describedby={descId}
          className="grid gap-3 text-pretty"
        >
          <div className="grid gap-1">
            <Popover.Title id={titleId} className="text-sm font-semibold text-kumo-strong">
              {title}
            </Popover.Title>
            <Popover.Description id={descId} className="text-xs leading-relaxed text-kumo-subtle">
              {description}
            </Popover.Description>
          </div>
          {disruptive && (
            <Banner variant="alert" size="sm" description={t("common.disruptNotice")} />
          )}
          <div className="flex flex-wrap justify-end gap-2 pt-0.5">
            <Popover.Close
              render={(props) => (
                <Button {...props} size="sm" variant="secondary">
                  {t("common.cancel")}
                </Button>
              )}
            />
            <Button
              size="sm"
              variant={confirmVariant}
              onClick={() => {
                void onConfirm();
              }}
            >
              {confirmLabel ?? t("common.confirm")}
            </Button>
          </div>
        </div>
      </Popover.Content>
    </Popover.Root>
  );
}
