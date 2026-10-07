export type DomainErrorCode =
  | "validation_error"
  | "authentication_required"
  | "authorization_denied"
  | "step_up_required"
  | "conflict"
  | "not_found"
  | "invariant_violation"
  | "internal_error";

export type DomainErrorDetails = Readonly<Record<string, unknown>>;

export class DomainError extends Error {
  readonly code: DomainErrorCode;
  readonly retryable: boolean;
  readonly details: DomainErrorDetails;

  constructor(
    code: DomainErrorCode,
    message: string,
    options: {
      retryable?: boolean;
      details?: DomainErrorDetails;
      cause?: unknown;
    } = {},
  ) {
    super(message, { cause: options.cause });
    this.name = "DomainError";
    this.code = code;
    this.retryable = options.retryable ?? false;
    this.details = options.details ?? {};
  }

  toJSON(): {
    code: DomainErrorCode;
    message: string;
    retryable: boolean;
    details: DomainErrorDetails;
  } {
    return {
      code: this.code,
      message: this.message,
      retryable: this.retryable,
      details: this.details,
    };
  }
}
