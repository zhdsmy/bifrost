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
  ALL_JOBS,
  ApiError,
  DEFAULT_UI_CONFIG,
  JOB_POLL_INTERVAL_MS,
  LOGIN_STATUS_POLL_INTERVAL_MS,
  STATUS_POLL_INTERVAL_MS,
  pollJob,
  readJob,
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
  runJob: <TData = unknown>(
    job: JobName,
    trigger: () => Promise<unknown>,
    options?: {
      onDone?: (finalState: JobState<TData>) => void;
      suppressLoginFailure?: boolean;
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
  const toastManagerRef = useRef(toastManager);
  toastManagerRef.current = toastManager;

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
  const suppressLoginErrRef = useRef(false);
  const jobAbortRefs = useRef<Partial<Record<JobName, AbortController>>>({});
  const mountedRef = useRef(true);

  const statusInFlightRef = useRef<Promise<StatusData | null> | null>(null);
  const statusQueuedRef = useRef<Promise<StatusData | null> | null>(null);
  useEffect(() => {
    mountedRef.current = true;
    const controllers = jobAbortRefs.current;
    return () => {
      mountedRef.current = false;
      for (const ctrl of Object.values(controllers)) ctrl?.abort();
    };
  }, []);

  // A finished login belongs to the login screen that requested it.
  useEffect(() => {
    if (!status || status.state === "needs_login" || !jobs.login || jobs.login.running) return;
    setJobs((prev) => {
      if (!prev.login || prev.login.running) return prev;
      const { login: _login, ...rest } = prev;
      return rest;
    });
  }, [status?.state, jobs.login]);

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

  const tError = useCallback((err: unknown) => {
    if (err instanceof ApiError) {
      return translateError(langRef.current, err.code, err.httpStatus);
    }
    if (err instanceof Error && err.message) {
      return err.message;
    }
    return translateError(langRef.current, "internal");
  }, []);

  const tPhase = useCallback((phase: string) => translatePhase(lang, phase), [lang]);
  const tState = useCallback((s: string) => translateState(lang, s), [lang]);
  const tCheck = useCallback((code: string) => translateCheck(lang, code), [lang]);

  const notify = useCallback(
    (opts: { title: string; description?: string; variant?: "success" | "error" | "warning" | "info" | "default" }) => {
      toastManagerRef.current.add({
        title: opts.title,
        description: opts.description,
        variant: opts.variant ?? "default",
      });
    },
    [],
  );

  const reloadStatus = useCallback((afterAction = true): Promise<StatusData | null> => {
    if (statusInFlightRef.current) {
      if (!afterAction) return statusInFlightRef.current;
      // Coalesce callers, but make a fresh request after the current one: an
      // action may have committed after the current refresh took its snapshot.
      statusQueuedRef.current ??= statusInFlightRef.current.then(() => {
        statusQueuedRef.current = null;
        return mountedRef.current ? reloadStatus() : null;
      });
      return statusQueuedRef.current;
    }

    const run = refreshStatus()
      .then((next) => {
        if (mountedRef.current) {
          setStatus(next);
          setStatusLoadError(null);
        }
        return next;
      })
      .catch((err) => {
        if (mountedRef.current) setStatusLoadError(tError(err));
        return null;
      })
      .finally(() => { statusInFlightRef.current = null; });
    statusInFlightRef.current = run;
    return run;
  }, [tError]);

  const attachJobPoll = useCallback(
    async <TData = unknown>(
      job: JobName,
      options?: {
        onDone?: (finalState: JobState<TData>) => void;
      },
    ): Promise<JobState<TData> | null> => {
      jobAbortRefs.current[job]?.abort();
      const ctrl = new AbortController();
      jobAbortRefs.current[job] = ctrl;

      function releaseProgress(err: unknown) {
        if (ctrl.signal.aborted) return;
        setJobs((prev) => {
          const next = { ...prev };
          delete next[job];
          return next;
        });
        notify({ title: tError(err), variant: "error" });
      }

      try {
        const finalState = await pollJob<TData>(job, {
          intervalMs: JOB_POLL_INTERVAL_MS,
          signal: ctrl.signal,
          onUnavailable: releaseProgress,
          onUpdate: (state) => {
            if (ctrl.signal.aborted || !state.running) return;
            setJobs((prev) => ({ ...prev, [job]: state as JobState }));
          },
        });
        if (ctrl.signal.aborted) return null;
        const fresh = await reloadStatus();
        if (ctrl.signal.aborted) return null;
        if (job === "login" && finalState.ok === false &&
            (suppressLoginErrRef.current || (fresh && fresh.state !== "needs_login"))) {
          setJobs(({ login: _login, ...rest }) => rest);
          return finalState;
        }
        setJobs((prev) => ({ ...prev, [job]: finalState as JobState }));
        options?.onDone?.(finalState);
        if (finalState.ok === false && finalState.code) {
          notify({
            title: translateError(langRef.current, finalState.code),
            variant: "error",
          });
        }
        return finalState;
      } catch (err) {
        if (ctrl.signal.aborted) return null;
        releaseProgress(err);
        await reloadStatus();
        return null;
      } finally {
        if (jobAbortRefs.current[job] === ctrl) {
          delete jobAbortRefs.current[job];
        }
      }
    },
    [notify, reloadStatus, tError],
  );

  // Initial boot sequence:
  // 1. Read UI config, cached status snapshot, and any existing job files in parallel.
  // 2. Resume polling for any job already running on the router.
  // 3. Refresh live status via bifrost_status.sh before unlocking mutating controls.
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
        setStatusSettled(true);
      })
      .catch((err) => {
        if (err instanceof DOMException && err.name === "AbortError") return;
      });

    const jobsTask = Promise.all(
      ALL_JOBS.map((job) =>
        readJob(job, controller.signal)
          .then((state) => [job, state] as const)
          .catch(() => null),
      ),
    );
    Promise.all([uiTask, snapshotTask, jobsTask]).then(async ([, , entries]) => {
      if (controller.signal.aborted) return;
      const loaded: Partial<Record<JobName, JobState>> = {};
      for (const entry of entries) {
        if (!entry) continue;
        const [job, state] = entry;
        if (state.running || job !== "login") loaded[job] = state;
      }
      setJobs(loaded);
      for (const entry of entries) {
        if (entry?.[1].running) void attachJobPoll(entry[0]);
      }
      const fresh = await reloadStatus();
      if (controller.signal.aborted) return;
      if (!fresh && !initialSnapshotFound) {
        setStatusLoadError((prev) => prev ?? translateError(langRef.current, "network_error"));
      }
      setStatusSettled(true);
      setInitializing(false);
    });

    return () => controller.abort();
  }, [attachJobPoll, reloadStatus]);

  // Only state-locking jobs block other actions (contract §2: login & netcheck do not hold the state lock).
  const lockingJobRunning = Boolean(
    jobs.daemon?.running || jobs.migrate?.running || jobs.update?.running,
  );
  const loginPolling = status?.state === "needs_login" || jobs.login?.running === true;

  // Single-loop visibility-aware status polling: every 3s (2s while awaiting login), paused when hidden or saving UI prefs.
  useEffect(() => {
    if (initializing || savingUi) return;

    let timer: ReturnType<typeof setTimeout> | null = null;
    let generation = 0;
    const interval = loginPolling ? LOGIN_STATUS_POLL_INTERVAL_MS : STATUS_POLL_INTERVAL_MS;

    const clearTimer = () => {
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
      }
    };

    const schedule = (gen: number) => {
      if (gen !== generation || document.visibilityState !== "visible") return;
      clearTimer();
      timer = setTimeout(async () => {
        timer = null;
        if (gen !== generation || document.visibilityState !== "visible") return;
        await reloadStatus(false);
        schedule(gen);
      }, interval);
    };

    const onVisibility = () => {
      generation++;
      clearTimer();
      if (document.visibilityState === "visible") {
        const gen = generation;
        void reloadStatus(false).then(() => schedule(gen));
      }
    };

    document.addEventListener("visibilitychange", onVisibility);
    schedule(generation);

    return () => {
      generation++;
      clearTimer();
      document.removeEventListener("visibilitychange", onVisibility);
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
    async <TData = unknown>(
      job: JobName,
      trigger: () => Promise<unknown>,
      options?: {
        onDone?: (finalState: JobState<TData>) => void;
        suppressLoginFailure?: boolean;
      },
    ): Promise<JobState<TData> | null> => {
      if (job === "login") {
        suppressLoginErrRef.current = false;
      } else if (options?.suppressLoginFailure) {
        suppressLoginErrRef.current = true;
      }

      // Do NOT abort any existing poller for `job` until `trigger()` succeeds,
      // so a `busy` rejection leaves the in-flight job poller intact.
      try {
        await trigger();
      } catch (err) {
        if (options?.suppressLoginFailure) suppressLoginErrRef.current = false;
        notify({ title: tError(err), variant: "error" });
        return null;
      }

      return attachJobPoll<TData>(job, options);
    },
    [attachJobPoll, notify, tError],
  );

  const busy = initializing || savingUi || lockingJobRunning;

  const value = useMemo<AppContextValue>(
    () => ({
      lang,
      mode,
      resolvedMode,
      overlays,
      tab,
      setTab,
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
