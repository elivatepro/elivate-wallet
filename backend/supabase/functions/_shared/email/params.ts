// Shared pieces of the email renderers: result and context types, the
// template error, and strict param readers. Params come from the database
// and are display values only.

export interface RenderedEmail {
  readonly subject: string;
  readonly html: string;
  readonly text: string;
}

export interface RenderContext {
  /** Join link, built by the worker from the invitation's token id. */
  readonly joinUrl?: string;
  /** App origin (APP_ORIGIN), for "Open Wallet" buttons. */
  readonly appUrl?: string;
}

export type Params = Readonly<Record<string, unknown>>;

export class TemplateError extends Error {
  constructor(readonly code: string) {
    super(code);
    this.name = "TemplateError";
  }
}

/** Header-safe single line (subjects): no control characters, bounded length. */
export function oneLine(value: string, max: number): string {
  // deno-lint-ignore no-control-regex
  return value.replace(/[\u0000-\u001f\u007f]+/g, " ").trim().slice(0, max);
}

export function param(params: Params, name: string, max = 200): string {
  const value = params[name];
  if (typeof value !== "string" || value.trim() === "" || value.length > max) {
    throw new TemplateError("template.param_invalid");
  }
  return value;
}

export function onlyParams(params: Params, allowed: readonly string[]): void {
  for (const key of Object.keys(params)) {
    if (!allowed.includes(key)) throw new TemplateError("template.param_unknown");
  }
}

/** App origin for buttons and images; required by every template. */
export function appOrigin(context: RenderContext): string {
  const appUrl = context.appUrl;
  if (!appUrl || !/^https?:\/\/[^\s"'<>#?]+$/.test(appUrl)) {
    throw new TemplateError("template.link_missing");
  }
  return appUrl.replace(/\/+$/, "");
}

/** "8 October 2026" in UTC. */
export function longDate(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) throw new TemplateError("template.param_invalid");
  return date.toLocaleDateString("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  });
}

/** "8 October 2026, 14:05 UTC". */
export function longDateTime(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) throw new TemplateError("template.param_invalid");
  const time = date.toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: "UTC",
  });
  return `${longDate(iso)}, ${time} UTC`;
}
