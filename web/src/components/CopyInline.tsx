// Clipboard components backed by copyText(), so copying also works over plain HTTP
// router origins without navigator.clipboard and tooltips stay inside the Shadow DOM.
import { useEffect, useRef, useState } from "react";
import { CheckIcon } from "@phosphor-icons/react/dist/csr/Check";
import { CopyIcon } from "@phosphor-icons/react/dist/csr/Copy";
import { CopySimpleIcon } from "@phosphor-icons/react/dist/csr/CopySimple";
import { Button } from "@cloudflare/kumo/components/button";
import { KUMO_INLINE_COPY_TEXT_STYLING } from "@cloudflare/kumo/components/inline-copy-text";
import { Tooltip } from "@cloudflare/kumo/components/tooltip";
import { copyText } from "../core/clipboard";
import { useApp } from "../app/context";

export function useCopy(text: string) {
  const { notify, t } = useApp();
  const [copied, setCopied] = useState(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const mountedRef = useRef(false);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      if (timerRef.current !== null) clearTimeout(timerRef.current);
    };
  }, []);

  async function handleCopy() {
    const ok = await copyText(text);
    if (!mountedRef.current) return;
    if (!ok) {
      notify({ title: t("common.copyFailed"), variant: "error" });
      return;
    }
    if (timerRef.current !== null) clearTimeout(timerRef.current);
    setCopied(true);
    timerRef.current = setTimeout(() => {
      setCopied(false);
      timerRef.current = null;
    }, 1500);
  }
  return { copied, handleCopy };
}

export function CopyInline({
  value,
}: {
  value: string;
}) {
  const { t } = useApp();
  const { copied, handleCopy } = useCopy(value);

  return (
    <button
      type="button"
      className={KUMO_INLINE_COPY_TEXT_STYLING.baseClasses}
      aria-label={copied ? t("common.copied") : t("common.copyAction")}
      onClick={() => {
        void handleCopy();
      }}
    >
      <span
        data-raw-value="true"
        className="truncate font-mono text-sm text-kumo-subtle group-hover/inline-copy:text-kumo-default group-focus-visible/inline-copy:text-kumo-default"
      >
        {value}
      </span>
      {copied ? (
        <CheckIcon size={14} aria-hidden className="shrink-0 text-kumo-success" />
      ) : (
        <CopySimpleIcon
          size={14}
          aria-hidden
          className="shrink-0 text-kumo-subtle opacity-0 transition-opacity motion-reduce:transition-none group-hover/inline-copy:opacity-100 group-focus-visible/inline-copy:opacity-100 group-focus-within:opacity-100 group-hover:opacity-100"
        />
      )}
      <span className="sr-only" aria-live="polite">
        {copied ? t("common.copied") : ""}
      </span>
    </button>
  );
}

export function CopyField({ text }: { text: string }) {
  const { overlays, t } = useApp();
  const { copied, handleCopy } = useCopy(text);

  return (
    <div className="flex items-center overflow-hidden rounded-lg border border-kumo-line bg-kumo-base font-mono text-xs">
      <span data-raw-value="true" className="min-w-0 flex-1 truncate ps-3 pe-2 text-kumo-default">
        {text}
      </span>
      <Tooltip asChild container={overlays} content={copied ? t("common.copied") : t("common.copy")}>
        <Button
          size="sm"
          variant="ghost"
          className="shrink-0 rounded-none border-l border-kumo-line px-2.5"
          aria-label={t("common.copyAction")}
          onClick={() => {
            void handleCopy();
          }}
        >
          {copied ? (
            <CheckIcon size={14} aria-hidden className="text-kumo-success" />
          ) : (
            <CopyIcon size={14} aria-hidden />
          )}
        </Button>
      </Tooltip>
      <span className="sr-only" aria-live="polite">
        {copied ? t("common.copied") : ""}
      </span>
    </div>
  );
}
