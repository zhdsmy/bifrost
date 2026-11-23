import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { KumoLocaleProvider } from "@cloudflare/kumo/utils";
import { Toasty, useKumoToastManager } from "@cloudflare/kumo/components/toast";
import { TooltipProvider } from "@cloudflare/kumo/components/tooltip";
import {
  ApiError,
  DEFAULT_UI_CONFIG,
  JOB_POLL_INTERVAL_MS,
  LOGIN_STATUS_POLL_INTERVAL_MS,
  STATUS_POLL_INTERVAL_MS,
  pollJob,
  readStatusFile,
  readUiConfig,
  refreshStatus,
  saveUiConfig,
} from "../core/api";
import type { JobName, JobState, StatusData, UiLang, UiMode } from "../core/types";
import {
  getKumoTranslations,
  t as translate,
  translateCheck,
  translateError,
  translatePhase,
  translateState,
  type MessageKey,
} from "../i18n";

export type TabId = "overview" | "devices" | "settings" | "core" | "diagnostics";

export interface AppContextValue {
  lang: UiLang;
  mode: UiMode;
  resolvedMode: "dark" | "light";
  overlays: HTMLElement;
  tab: TabId;
  setTab: (tab: TabId) => void;
  status: StatusData | null;
  setStatus: (status: StatusData) => void;
  initializing: boolean;
  uiLoaded: boolean;
  uiLoadError: boolean;
  statusLoadError: string | null;
  uiError: string | null;
  savingUi: boolean;
  jobs: Partial<Record<JobName, JobState>>;
  busy: boolean;
  changeLang: (next: UiLang) => Promise<void>;
  changeMode: (next: UiMode) => Promise<void>;
  reloadStatus: () => Promise<StatusData | null>;
  runJob: <TData = Record<string, unknown>>(
    job: JobName,
    trigger: () => Promise<unknown>,
    options?: {
      onDone?: (finalState: JobState<TData>) => void;
      refreshWhileRunning?: boolean;
    },
  ) => Promise<JobState<TData> | null>;
  t: (key: MessageKey, vars?: Record<string, string | number>) => string;
  tError: (err: unknown) => string;
  tErrorCode: (code: string, httpStatus?: number) => string;
  tPhase: (phase: string) => string;
  tState: (state: string) => string;
  tCheck: (code: string) => string;
  notify: (opts: { title: string; description?: string; variant?: "success" | "error" | "warning" | "info" | "default" }) => void;
}

const AppContext = createContext<AppContextValue | null>(null);

function resolveSystemMode(): "dark" | "light" {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") return "dark";
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function AppContextInner({
  themeRoot,
  overlays,
  children,
}: {
  themeRoot: HTMLElement;
  overlays: HTMLElement;
  children: ReactNode;
}) {
  const toastManager = useKumoToastManager();

  const [lang, setLang] = useState<UiLang>(DEFAULT_UI_CONFIG.lang);
  const [mode, setMode] = useState<UiMode>(DEFAULT_UI_CONFIG.mode);
  const [systemDark, setSystemDark] = useState<boolean>(() => resolveSystemMode() === "dark");
  const [tab, setTab] = useState<TabId>("overview");

  const [uiLoaded, setUiLoaded] = useState(false);
  const [uiSettled, setUiSettled] = useState(false);
  const [uiLoadError, setUiLoadError] = useState(false);
  const [statusSettled, setStatusSettled] = useState(false);
  const [initializing, setInitializing] = useState(true);
  const [status, setStatus] = useState<StatusData | null>(null);
  const [statusLoadError, setStatusLoadError] = useState<string | null>(null);

  const [uiError, setUiError] = useState<string | null>(null);
  const [savingUi, setSavingUi] = useState(false);
  const [jobs, setJobs] = useState<Partial<Record<JobName, JobState>>>({});

  const langRef = useRef(lang);
  langRef.current = lang;
  const modeRef = useRef(mode);
  modeRef.current = mode;
  const jobAbortRefs = useRef<Partial<Record<JobName, AbortController>>>({});
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    const controllers = jobAbortRefs.current;
    return () => {
      mountedRef.current = false;
      for (const ctrl of Object.values(controllers)) ctrl?.abort();
    };
  }, []);

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const update = () => setSystemDark(mq.matches);
    update();
    mq.addEventListener("change", update);
    return () => mq.removeEventListener("change", update);
  }, []);

  const resolvedMode: "dark" | "light" = mode === "system" ? (systemDark ? "dark" : "light") : mode;

  useLayoutEffect(() => {
    if (!uiSettled) return;
    themeRoot.dataset.mode = resolvedMode;
    themeRoot.style.colorScheme = resolvedMode;
  }, [themeRoot, resolvedMode, uiSettled]);

  const t = useCallback(
    (key: MessageKey, vars?: Record<string, string | number>) => translate(lang, key, vars),
    [lang],
  );

  const tErrorCode = useCallback(
    (code: string, httpStatus?: number) => translateError(lang, code, httpStatus),
    [lang],
  );

  const tError = useCallback(
    (err: unknown) => {
      if (err instanceof ApiError) {
        return translateError(langRef.current, err.code, err.httpStatus);
      }
      if (err instanceof Error && err.message) {
        return err.message;
      }
      return translateError(langRef.current, "internal");
    },
    [],
  );

  const tPhase = useCallback((phase: string) => translatePhase(lang, phase), [lang]);
  const tState = useCallback((s: string) => translateState(lang, s), [lang]);
  const tCheck = useCallback((code: string) => translateCheck(lang, code), [lang]);

  const notify = useCallback(
    (opts: { title: string; description?: string; variant?: "success" | "error" | "warning" | "info" | "default" }) => {
      toastManager.add({
        title: opts.title,
        description: opts.description,
        variant: opts.variant ?? "default",
      });
    },
    [toastManager],
  );

  const reloadStatus = useCallback(async (): Promise<StatusData | null> => {
    try {
      const next = await refreshStatus();
      if (!mountedRef.current) return null;
      setStatus(next);
      setStatusLoadError(null);
      return next;
    } catch (err) {
      if (!mountedRef.current) return null;
      setStatusLoadError(tError(err));
      return null;
    }
  }, [tError]);

  // Initial boot sequence:
  // 1. Read UI config (/_api/bifrost) and last status snapshot (/_temp/bifrost_status.json) in parallel.
  //    First paint waits for both so neither theme/language nor initial state flashes.
  // 2. Refresh live status via bifrost_status.sh before unlocking action buttons.
  useEffect(() => {
    const controller = new AbortController();
    let initialSnapshotFound = false;

    const uiTask = readUiConfig(controller.signal)
      .then((cfg) => {
        if (controller.signal.aborted) return;
        setLang(cfg.lang);
        setMode(cfg.mode);
        setUiLoaded(true);
      })
      .catch((err) => {
        if (err instanceof DOMException && err.name === "AbortError") return;
        setUiLoadError(true);
      })
      .finally(() => {
        if (!controller.signal.aborted) setUiSettled(true);
      });

    const snapshotTask = readStatusFile(controller.signal)
      .then((data) => {
        if (controller.signal.aborted) return;
        initialSnapshotFound = true;
        setStatus(data);
        setStatusLoadError(null);
        setStatusSettled(true);
      })
      .catch((err) => {
        if (err instanceof DOMException && err.name === "AbortError") return;
        // Missing snapshot on fresh boot is recovered by refreshStatus() below.
      });

    Promise.all([uiTask, snapshotTask]).then(async () => {
      if (controller.signal.aborted) return;
      try {
        const fresh = await refreshStatus(controller.signal);
        if (controller.signal.aborted) return;
        setStatus(fresh);
        setStatusLoadError(null);
      } catch (err) {
        if (err instanceof DOMException && err.name === "AbortError") return;
        if (!initialSnapshotFound) {
          setStatusLoadError(
            err instanceof ApiError
              ? translateError(langRef.current, err.code, err.httpStatus)
              : translateError(langRef.current, "network_error"),
          );
        }
      } finally {
        if (!controller.signal.aborted) {
          setStatusSettled(true);
          setInitializing(false);
        }
      }
    });

    return () => controller.abort();
  }, []);

  const anyJobRunning = useMemo(
    () => Object.values(jobs).some((j) => j?.running === true),
    [jobs],
  );
  const loginPolling = status?.state === "needs_login" || jobs.login?.running === true;

  // Visibility-aware status polling: every 3s (2s while waiting for login), paused when hidden or saving UI prefs.
  useEffect(() => {
    if (initializing || savingUi) return;

    let timer: ReturnType<typeof setTimeout> | null = null;
    let active = true;
    const interval = loginPolling ? LOGIN_STATUS_POLL_INTERVAL_MS : STATUS_POLL_INTERVAL_MS;

    const schedule = () => {
      if (!active || document.visibilityState !== "visible") return;
      timer = setTimeout(async () => {
        if (!active || document.visibilityState !== "visible") return;
        await reloadStatus();
        schedule();
      }, interval);
    };

    const onVisibility = () => {
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
      }
      if (document.visibilityState === "visible" && active) {
        void reloadStatus().then(schedule);
      }
    };

    document.addEventListener("visibilitychange", onVisibility);
    schedule();

    return () => {
      active = false;
      document.removeEventListener("visibilitychange", onVisibility);
      if (timer !== null) clearTimeout(timer);
    };
  }, [initializing, savingUi, loginPolling, reloadStatus]);

  const saveUiPref = useCallback(
    async (nextLang: UiLang, nextMode: UiMode) => {
      const prevLang = langRef.current;
      const prevMode = modeRef.current;
      if (nextLang === prevLang && nextMode === prevMode) return;
      if (!uiLoaded || initializing || savingUi) return;

      setUiError(null);
      setSavingUi(true);
      setLang(nextLang);
      setMode(nextMode);
      try {
        await saveUiConfig(nextLang, nextMode);
      } catch (err) {
        if (!mountedRef.current) return;
        setLang(prevLang);
        setMode(prevMode);
        const msg =
          err instanceof ApiError
            ? translateError(prevLang, err.code, err.httpStatus)
            : translateError(prevLang, "internal");
        setUiError(msg);
      } finally {
        if (mountedRef.current) setSavingUi(false);
      }
    },
    [uiLoaded, initializing, savingUi],
  );

  const changeLang = useCallback(
    (next: UiLang) => saveUiPref(next, modeRef.current),
    [saveUiPref],
  );

  const changeMode = useCallback(
    (next: UiMode) => saveUiPref(langRef.current, next),
    [saveUiPref],
  );

  const runJob = useCallback(
    async <TData = Record<string, unknown>>(
      job: JobName,
      trigger: () => Promise<unknown>,
      options?: {
        onDone?: (finalState: JobState<TData>) => void;
        refreshWhileRunning?: boolean;
      },
    ): Promise<JobState<TData> | null> => {
      jobAbortRefs.current[job]?.abort();
      const ctrl = new AbortController();
      jobAbortRefs.current[job] = ctrl;

      try {
        await trigger();
      } catch (err) {
        const msg = tError(err);
        notify({ title: msg, variant: "error" });
        return null;
      }

      try {
        const finalState = await pollJob<TData>(job, {
          intervalMs: JOB_POLL_INTERVAL_MS,
          signal: ctrl.signal,
          onUpdate: (state) => {
            if (!mountedRef.current) return;
            setJobs((prev) => ({ ...prev, [job]: state as JobState }));
            if (options?.refreshWhileRunning && state.running) {
              void reloadStatus();
            }
          },
        });
        if (!mountedRef.current) return null;
        setJobs((prev) => ({ ...prev, [job]: finalState as JobState }));
        await reloadStatus();
        options?.onDone?.(finalState);
        if (finalState.ok === false && finalState.code && finalState.code !== "up_to_date") {
          notify({
            title: translateError(langRef.current, finalState.code),
            variant: "error",
          });
        }
        return finalState;
      } catch (err) {
        if (err instanceof DOMException && err.name === "AbortError") return null;
        if (!mountedRef.current) return null;
        notify({ title: tError(err), variant: "error" });
        return null;
      }
    },
    [notify, reloadStatus, tError],
  );

  const busy = initializing || savingUi || anyJobRunning;

  const value = useMemo<AppContextValue>(
    () => ({
      lang,
      mode,
      resolvedMode,
      overlays,
      tab,
      setTab,
      status,
      setStatus,
      initializing,
      uiLoaded,
      uiLoadError,
      statusLoadError,
      uiError,
      savingUi,
      jobs,
      busy,
      changeLang,
      changeMode,
      reloadStatus,
      runJob,
      t,
      tError,
      tErrorCode,
      tPhase,
      tState,
      tCheck,
      notify,
    }),
    [
      lang,
      mode,
      resolvedMode,
      overlays,
      tab,
      status,
      initializing,
      uiLoaded,
      uiLoadError,
      statusLoadError,
      uiError,
      savingUi,
      jobs,
      busy,
      changeLang,
      changeMode,
      reloadStatus,
      runJob,
      t,
      tError,
      tErrorCode,
      tPhase,
      tState,
      tCheck,
      notify,
    ],
  );

  // Do not paint until UI preferences and initial status read settle.
  if (!uiSettled || !statusSettled) return null;

  return (
    <KumoLocaleProvider translations={getKumoTranslations(lang)}>
      <TooltipProvider>
        <AppContext.Provider value={value}>{children}</AppContext.Provider>
      </TooltipProvider>
    </KumoLocaleProvider>
  );
}

export function AppProvider({
  themeRoot,
  overlays,
  children,
}: {
  themeRoot: HTMLElement;
  overlays: HTMLElement;
  children: ReactNode;
}) {
  return (
    <Toasty container={overlays}>
      <AppContextInner themeRoot={themeRoot} overlays={overlays}>
        {children}
      </AppContextInner>
    </Toasty>
  );
}

export function useApp(): AppContextValue {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error("useApp must be used inside AppProvider");
  return ctx;
}
