import { Checkbox } from "@cloudflare/kumo/components/checkbox";
import { useApp } from "../../app/context";
import { CHECKBOX_RING } from "../../components/checkbox";
import type { JobState, LoginJobData } from "../../core/types";

// A login that requested tags can succeed without them: headscale drops them
// for an existing node logging in with a user's auth key.
export function loginTagsMissing(final: JobState<LoginJobData>): boolean {
  return final.ok === true && final.data?.tags === true && final.data.tags_applied === false;
}

// PLAN 7.5: request the tags the device had, so a login does not make it user-owned.
export function KeepTagsCheckbox({
  tags,
  checked,
  disabled,
  dense = false,
  onCheckedChange,
}: {
  tags: string[];
  checked: boolean;
  disabled?: boolean;
  // Popovers use text-xs for descriptions.
  dense?: boolean;
  onCheckedChange: (checked: boolean) => void;
}) {
  const { t } = useApp();
  return (
    <div className="grid gap-1">
      <Checkbox
        className={CHECKBOX_RING}
        // Kumo sets the label in text-base, which the page keeps for titles.
        label={<span className="text-sm">{t("login.keepTags", { tags: tags.join(", ") })}</span>}
        checked={checked}
        disabled={disabled}
        onCheckedChange={(value) => onCheckedChange(value === true)}
      />
      <p className={`${dense ? "text-xs leading-relaxed" : "text-sm"} text-kumo-subtle`}>
        {t("login.keepTagsDesc")}
      </p>
    </div>
  );
}
