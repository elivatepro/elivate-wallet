// Error codes and typed failures (plan §5.4). The code list mirrors
// backend/supabase/functions/_shared/http.ts on main exactly; it is append-only
// there and must stay in sync here. Codes are never invented client-side.

import { Data, Schema } from 'effect';

export const ERROR_CODES = [
	'validation_error',
	'authentication_required',
	'pin_setup_required',
	'pin_required',
	'pin_incorrect',
	'pin_locked',
	'step_up_required',
	'account_blocked',
	'authorization_denied',
	'not_found',
	'idempotency_conflict',
	'conflict',
	'rate_limited',
	'internal_error',
	'workspace_invalid',
	'hierarchy_invalid',
	'role_office_mismatch',
	'membership_exists',
	'last_president',
	'last_leader',
	'network_not_active',
	'scope_exceeds_authority',
	'permission_not_grantable',
	'self_target_forbidden'
] as const;

export const ErrorCode = Schema.Literals(ERROR_CODES);
export type ErrorCode = (typeof ERROR_CODES)[number];

export const isErrorCode = (value: unknown): value is ErrorCode =>
	typeof value === 'string' && (ERROR_CODES as readonly string[]).includes(value);

/** A well-formed failure envelope from the backend (or relayed by the app server). */
export class BackendError extends Data.TaggedError('BackendError')<{
	readonly status: number;
	readonly code: ErrorCode;
	readonly message: string;
	readonly retryable: boolean;
	readonly details: Readonly<Record<string, unknown>>;
	readonly requestId: string | null;
}> {}

/**
 * The request did not produce an envelope: network failure, timeout, or a
 * non-envelope body (gateway 401 from verify_jwt, an HTML 502...).
 */
export class TransportError extends Data.TaggedError('TransportError')<{
	readonly reason: 'network' | 'timeout' | 'non_envelope' | 'aborted';
	readonly status: number | null;
}> {}

/** The backend answered with something that does not match the contract. */
export class ContractViolation extends Data.TaggedError('ContractViolation')<{
	readonly route: string;
	readonly requestId: string | null;
	readonly summary: string;
}> {}

/** The app server is missing configuration it needs (fails closed). */
export class ConfigurationMissing extends Data.TaggedError('ConfigurationMissing')<{
	readonly name: string;
}> {}

export type ApiFailure = BackendError | TransportError | ContractViolation;

/** UI categories (plan §5.4). */
export type FailureCategory =
	| 'validation'
	| 'authentication'
	| 'session_gate'
	| 'step_up'
	| 'authorization'
	| 'conflict'
	| 'not_found'
	| 'throttled'
	| 'server'
	| 'transport'
	| 'defect';

export function categorize(error: ApiFailure): FailureCategory {
	switch (error._tag) {
		case 'TransportError':
			// A gateway 401 without an envelope still means "sign in again".
			return error.status === 401 ? 'authentication' : 'transport';
		case 'ContractViolation':
			return 'defect';
		case 'BackendError':
			switch (error.code) {
				case 'validation_error':
					return 'validation';
				case 'authentication_required':
					return 'authentication';
				case 'pin_setup_required':
				case 'pin_required':
				case 'pin_locked':
				case 'account_blocked':
					return 'session_gate';
				case 'pin_incorrect':
					return 'validation';
				case 'step_up_required':
					return 'step_up';
				case 'authorization_denied':
				case 'workspace_invalid':
				case 'scope_exceeds_authority':
				case 'self_target_forbidden':
				case 'permission_not_grantable':
					return 'authorization';
				case 'conflict':
				case 'idempotency_conflict':
				case 'membership_exists':
				case 'last_president':
				case 'last_leader':
				case 'network_not_active':
				case 'hierarchy_invalid':
				case 'role_office_mismatch':
					return 'conflict';
				case 'not_found':
					return 'not_found';
				case 'rate_limited':
					return 'throttled';
				case 'internal_error':
					return 'server';
			}
	}
}

/** Reads may be retried on transport failures or envelope `retryable: true` (plan §5.5). */
export const isRetryableRead = (error: ApiFailure): boolean =>
	(error._tag === 'TransportError' && error.reason !== 'aborted' && error.status !== 401) ||
	(error._tag === 'BackendError' && error.retryable);
