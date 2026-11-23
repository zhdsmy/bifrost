// Adapted from po0fw asus-merlin (MIT), commit 0d9532d.
import type {
  CoreArch,
  DiagData,
  JobName,
  JobStartResult,
  JobState,
  PingResult,
  SetResult,
  SettingKey,
  StatusData,
  UiConfig,
  UiLang,
  UiMode,
} from "./types";
import { validLang, validMode } from "./validate.ts";

export const DEFAULT_UI_CONFIG: UiConfig = {
  lang: "zh-CN",
  mode: "dark",
};

export const JOB_POLL_INTERVAL_MS = 2000;
export const STATUS_POLL_INTERVAL_MS = 3000;
export const LOGIN_STATUS_POLL_INTERVAL_MS = 2000;

export class ApiError extends Error {
  readonly code: string;
  readonly httpStatus?: number;

  constructor(code: string, httpStatus?: number, message?: string) {
    super(message ?? code);
    this.name = "ApiError";
    this.code = code;
    this.httpStatus = httpStatus;
  }
}

export function dash(value: string): string {
  return value === "" ? "-" : value;
}

function nextRequestId(): number {
  return 1 + Math.floor(Math.random() * 99_999_999);
}

async function rawRequest(path: string, body?: object, signal?: AbortSignal): Promise<Response> {
  let response: Response;
  try {
    response = await fetch(path, {
      cache: "no-store",
      method: body ? "POST" : "GET",
      headers: {
        "X-Requested-With": "XMLHttpRequest",
        ...(body && { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" }),
      },
      body: body ? JSON.stringify(body) : undefined,
      signal,
    });
  } catch (err) {
    if (err instanceof DOMException && err.name === "AbortError") throw err;
    throw new ApiError("network_error");
  }
  if (!response.ok) {
    throw new ApiError("http_error", response.status);
  }
  return response;
}

export function parseActionPayload<T extends object>(body: unknown): T {
  let inner: unknown = body;
  if (body && typeof body === "object" && "result" in body) {
    const raw = (body as { result: unknown }).result;
    if (typeof raw === "string") {
      try {
        inner = JSON.parse(raw);
      } catch {
        throw new ApiError("invalid_response");
      }
    } else {
      inner = raw;
    }
  }
  if (!inner || typeof inner !== "object" || typeof (inner as { ok?: unknown }).ok !== "boolean") {
    throw new ApiError("invalid_response");
  }
  const obj = inner as { ok: boolean; code?: unknown; msg?: unknown } & T;
  if (!obj.ok) {
    const code = typeof obj.code === "string" && obj.code ? obj.code : "internal";
    const msg = typeof obj.msg === "string" ? obj.msg : undefined;
    throw new ApiError(code, undefined, msg);
  }
  return obj;
}

export async function postScript<T extends object = Record<string, unknown>>(
  method: "bifrost_config.sh" | "bifrost_status.sh",
  params: string[],
  signal?: AbortSignal,
): Promise<T> {
  const response = await rawRequest(
    "/_api/",
    {
      id: nextRequestId(),
      method,
      params,
      fields: {},
    },
    signal,
  );
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new ApiError("invalid_response");
  }
  return parseActionPayload<T>(body);
}

export async function readUiConfig(signal?: AbortSignal): Promise<UiConfig> {
  const response = await rawRequest("/_api/bifrost", undefined, signal);
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    throw new ApiError("invalid_response");
  }
  const result = (body as { result?: unknown[] })?.result;
  const row = (Array.isArray(result) && result[0] && typeof result[0] === "object" ? result[0] : {}) as Record<
    string,
    unknown
  >;
  const rawLang = typeof row.bifrost_ui_lang === "string" ? row.bifrost_ui_lang : "";
  const rawMode = typeof row.bifrost_ui_mode === "string" ? row.bifrost_ui_mode : "";
  return {
    lang: validLang(rawLang) ? (rawLang as UiLang) : DEFAULT_UI_CONFIG.lang,
    mode: validMode(rawMode) ? (rawMode as UiMode) : DEFAULT_UI_CONFIG.mode,
  };
}

export async function saveUiConfig(lang: UiLang, mode: UiMode, signal?: AbortSignal): Promise<void> {
  await postScript("bifrost_config.sh", ["ui", lang, mode], signal);
}

export async function readTempJson<T>(name: string, signal?: AbortSignal): Promise<T> {
  const response = await rawRequest(`/_temp/${name}`, undefined, signal);
  try {
    return (await response.json()) as T;
  } catch {
    throw new ApiError("invalid_response");
  }
}

export async function readTempText(name: string, signal?: AbortSignal): Promise<string> {
  const response = await rawRequest(`/_temp/${name}`, undefined, signal);
  return response.text();
}

export async function refreshStatus(signal?: AbortSignal): Promise<StatusData> {
  await postScript("bifrost_status.sh", [], signal);
  return readTempJson<StatusData>("bifrost_status.json", signal);
}

export function readStatusFile(signal?: AbortSignal): Promise<StatusData> {
  return readTempJson<StatusData>("bifrost_status.json", signal);
}

export function readJob<TData = Record<string, unknown>>(
  job: JobName,
  signal?: AbortSignal,
): Promise<JobState<TData>> {
  return readTempJson<JobState<TData>>(`bifrost_${job}.json`, signal);
}

export async function pollJob<TData = Record<string, unknown>>(
  job: JobName,
  options: {
    intervalMs?: number;
    maxTicks?: number;
    onUpdate?: (state: JobState<TData>) => void;
    signal?: AbortSignal;
  } = {},
): Promise<JobState<TData>> {
  const intervalMs = options.intervalMs ?? JOB_POLL_INTERVAL_MS;
  const maxTicks = options.maxTicks ?? 360;
  let missingRetries = 0;

  for (let tick = 0; tick < maxTicks; tick++) {
    if (options.signal?.aborted) {
      throw new DOMException("Aborted", "AbortError");
    }
    try {
      const state = await readJob<TData>(job, options.signal);
      missingRetries = 0;
      options.onUpdate?.(state);
      if (!state.running) return state;
    } catch (err) {
      if (err instanceof ApiError && err.httpStatus === 404 && missingRetries < 3) {
        missingRetries++;
      } else {
        throw err;
      }
    }
    await sleep(intervalMs, options.signal);
  }
  throw new ApiError("timeout");
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new DOMException("Aborted", "AbortError"));
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(new DOMException("Aborted", "AbortError"));
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

// Page action helpers matching contract section 4 verbatim.
export const api = {
  enable: (signal?: AbortSignal) => postScript<JobStartResult>("bifrost_config.sh", ["enable"], signal),
  disable: (signal?: AbortSignal) => postScript<JobStartResult>("bifrost_config.sh", ["disable"], signal),
  connect: (signal?: AbortSignal) => postScript("bifrost_config.sh", ["connect"], signal),
  login: (server: string, authKey: string, signal?: AbortSignal) =>
    postScript<JobStartResult>("bifrost_config.sh", ["login", dash(server), dash(authKey)], signal),
  relogin: (signal?: AbortSignal) => postScript<JobStartResult>("bifrost_config.sh", ["relogin"], signal),
  logout: (signal?: AbortSignal) => postScript("bifrost_config.sh", ["logout"], signal),
  purge: (signal?: AbortSignal) => postScript<JobStartResult>("bifrost_config.sh", ["purge"], signal),
  set: (key: SettingKey, value: string, signal?: AbortSignal) =>
    postScript<SetResult>("bifrost_config.sh", ["set", key, dash(value)], signal),
  migrate: (signal?: AbortSignal) => postScript<JobStartResult>("bifrost_config.sh", ["migrate"], signal),
  coreCheck: (signal?: AbortSignal) => postScript<JobStartResult>("bifrost_config.sh", ["core-check"], signal),
  coreUpdate: (signal?: AbortSignal) => postScript<JobStartResult>("bifrost_config.sh", ["core-update"], signal),
  coreRollback: (signal?: AbortSignal) => postScript<JobStartResult>("bifrost_config.sh", ["core-rollback"], signal),
  coreArch: (arch: CoreArch, signal?: AbortSignal) =>
    postScript<JobStartResult>("bifrost_config.sh", ["core-arch", arch], signal),
  netcheck: (signal?: AbortSignal) => postScript<JobStartResult>("bifrost_config.sh", ["netcheck"], signal),
  ping: (ip: string, signal?: AbortSignal) => postScript<PingResult>("bifrost_config.sh", ["ping", ip], signal),
  logs: (signal?: AbortSignal) => postScript("bifrost_config.sh", ["logs"], signal),
  readLogsText: (signal?: AbortSignal) => readTempText("bifrost_logs.txt", signal),
  readDiag: (signal?: AbortSignal) => readTempJson<DiagData>("bifrost_diag.json", signal),
};
