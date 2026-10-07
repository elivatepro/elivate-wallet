export type LogLevel = "debug" | "info" | "warn" | "error";

export type LogContext = Readonly<{
  requestId?: string;
  actorUserId?: string;
  tenantId?: string;
  targetType?: string;
  targetId?: string;
  [key: string]: unknown;
}>;

export type StructuredLogRecord = Readonly<{
  timestamp: string;
  level: LogLevel;
  event: string;
  context: LogContext;
}>;

const SENSITIVE_KEY =
  /(authorization|cookie|password|secret|token|credential|evidence|receipt|raw|metadata|payout.?account|bank.?details|account.?(number|reference|holder)|institution.?code|routing.?number|iban|swift.?code|bic|provider.?reference|storage.?(bucket|object|path)|original.?filename|sha.?256|mime.?type)/i;

function redact(value: unknown, key?: string): unknown {
  if (key !== undefined && SENSITIVE_KEY.test(key)) return "[REDACTED]";
  if (Array.isArray(value)) return value.map((item) => redact(item));
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([entryKey, entryValue]) => [
        entryKey,
        redact(entryValue, entryKey),
      ]),
    );
  }
  return value;
}

export function createStructuredLogRecord(
  level: LogLevel,
  event: string,
  context: LogContext = {},
  now: Date = new Date(),
): StructuredLogRecord {
  return {
    timestamp: now.toISOString(),
    level,
    event,
    context: redact(context) as LogContext,
  };
}

export function writeStructuredLog(record: StructuredLogRecord): void {
  const serialized = JSON.stringify(record);
  if (record.level === "error") {
    console.error(serialized);
  } else if (record.level === "warn") {
    console.warn(serialized);
  } else {
    console.log(serialized);
  }
}
