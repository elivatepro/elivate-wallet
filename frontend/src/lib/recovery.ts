// Unknown-outcome recovery for commands (F-03, W-00, Blueprint 08 B5).
// Pure rules shared by every command form; the stateful runner is
// #lib/client/command-attempt.svelte.ts.
//
// A command whose answer never arrived (timeout, dropped connection, reload,
// an app-server 502) has an UNKNOWN outcome: it may or may not have committed.
// The attempt (idempotency key + body, never the PIN) is kept so the person
// can recover authoritatively:
//   1. ask the backend what happened to that key (GET /api/commands/outcome);
//   2. committed → show it (a same-key replay returns the full result under
//      current authority); not found → re-send with the SAME key and body,
//      which is safe because the backend replays instead of acting twice.
// A new key is used only after a definitive answer (success or refusal).

import { Schema } from 'effect';
import type { ApiFailure } from '#lib/contract/errors.js';
import type { CommandOutcome } from '#lib/contract/ledger.js';
import { IDEMPOTENCY_KEY_PATTERN } from '#lib/contract/common.js';

/** Storage prefix; sign-out erases every `ew:attempt:` entry (device-cache purgeAll). */
export const ATTEMPT_PREFIX = 'ew:attempt:v1:';
/** Kept at most this long on the device. */
export const ATTEMPT_MAX_AGE_MS = 24 * 60 * 60 * 1000;
/**
 * Without the original body (after a reload of a form that keeps none), "not
 * found" is trusted only once the original request can no longer be running
 * anywhere: well past every timeout on the way (browser 20 s, app server 20 s).
 */
export const ATTEMPT_SETTLE_MS = 60_000;

/** Body fields that are never stored or replayed from storage. */
const SECRET_FIELDS = new Set(['pin', 'password', 'token', 'accountNumber']);

/**
 * True when the command may have run: no envelope came back (network,
 * timeout, aborted, a non-JSON 5xx), the app server answered 502 because the
 * Edge call failed, or the response didn't match the contract (it may well
 * have been a success). A gateway 401 never reached the database.
 */
export function isUnknownOutcome(failure: ApiFailure | undefined): boolean {
	if (!failure) return true;
	switch (failure._tag) {
		case 'TransportError':
			return failure.status !== 401;
		case 'ContractViolation':
			return true;
		case 'BackendError':
			return failure.code === 'internal_error';
	}
}

/** Refusals that did nothing and leave the same attempt usable (PIN prompts). */
export function keepsAttempt(failure: ApiFailure | undefined): boolean {
	return (
		isUnknownOutcome(failure) ||
		(failure?._tag === 'BackendError' &&
			(failure.code === 'step_up_required' || failure.code === 'pin_incorrect'))
	);
}

/** A copy of the body without secrets (and without the key, which is stored on its own). */
export function storableBody(body: Readonly<Record<string, unknown>>): Record<string, unknown> {
	const copy: Record<string, unknown> = {};
	for (const [key, value] of Object.entries(body)) {
		if (!SECRET_FIELDS.has(key) && key !== 'idempotencyKey') copy[key] = value;
	}
	return copy;
}

export const PendingAttempt = Schema.Struct({
	key: Schema.String.check(Schema.isPattern(IDEMPOTENCY_KEY_PATTERN)),
	/** Backend command name (`record_income`, `set_allocation`...). */
	command: Schema.String.check(Schema.isPattern(/^[a-z][a-z_]{0,59}$/)),
	workspaceId: Schema.String,
	dispatchedAt: Schema.Number,
	/** Non-secret label for the "checking" screen ("₦120,000.00 income for Kemi"). */
	summary: Schema.NullOr(Schema.String),
	/** Replayable body without secrets; null when the form keeps none. */
	body: Schema.NullOr(Schema.Record(Schema.String, Schema.Unknown))
});
export type PendingAttempt = typeof PendingAttempt.Type;

export type Resolution =
	/** It went through. `reference` is the public one when the command has it. */
	| { readonly kind: 'committed'; readonly reference: string | null; readonly at: string }
	/** The attempt was cancelled through the trusted command (income, W-08). */
	| { readonly kind: 'cancelled'; readonly at: string }
	/** Nothing was committed; `canResend` when the same body can go again with the same key. */
	| { readonly kind: 'not_committed'; readonly canResend: boolean }
	/** Nothing yet, but too early to rule out the original request: ask again shortly. */
	| { readonly kind: 'pending' }
	/** The key belongs to another command (should not happen; never reuse the key). */
	| { readonly kind: 'conflict' };

/** What the backend's answer means for this attempt. */
export function resolveOutcome(
	outcome: CommandOutcome,
	attempt: PendingAttempt,
	now: number = Date.now()
): Resolution {
	switch (outcome.status) {
		case 'committed':
			return outcome.command === attempt.command
				? { kind: 'committed', reference: outcome.reference, at: outcome.committedAt }
				: { kind: 'conflict' };
		case 'cancelled':
			return { kind: 'cancelled', at: outcome.cancelledAt };
		case 'not_found':
			if (attempt.body) return { kind: 'not_committed', canResend: true };
			return now - attempt.dispatchedAt >= ATTEMPT_SETTLE_MS
				? { kind: 'not_committed', canResend: false }
				: { kind: 'pending' };
	}
}

/** "k3f92a1b…" → "K3F9-2A1B": a short, non-secret handle to read out to support. */
export function attemptLabel(key: string): string {
	const head = key
		.replace(/[^A-Za-z0-9]/g, '')
		.slice(0, 8)
		.toUpperCase();
	return head.length > 4 ? `${head.slice(0, 4)}-${head.slice(4)}` : head;
}

// ── Device storage (one pending attempt per person, workspace and command) ──

export interface AttemptStore {
	getItem(key: string): string | null;
	setItem(key: string, value: string): void;
	removeItem(key: string): void;
}

export interface AttemptScope {
	readonly uid: string;
	readonly workspaceId: string;
}

export const storageKey = (scope: AttemptScope, command: string) =>
	`${ATTEMPT_PREFIX}${command}:${encodeURIComponent(scope.uid)}:${encodeURIComponent(scope.workspaceId)}`;

const encode = Schema.encodeSync(PendingAttempt);
const decode = Schema.decodeUnknownSync(PendingAttempt);

export function saveAttempt(store: AttemptStore, scope: AttemptScope, attempt: PendingAttempt) {
	const safe: PendingAttempt = { ...attempt, body: attempt.body && storableBody(attempt.body) };
	try {
		store.setItem(storageKey(scope, attempt.command), JSON.stringify(encode(safe)));
	} catch {
		// Quota or privacy mode: the page still holds the attempt in memory.
	}
}

export function loadAttempt(
	store: AttemptStore,
	scope: AttemptScope,
	command: string,
	now: number = Date.now()
): PendingAttempt | null {
	const key = storageKey(scope, command);
	let raw: string | null;
	try {
		raw = store.getItem(key);
	} catch {
		return null;
	}
	if (!raw) return null;
	try {
		const attempt = decode(JSON.parse(raw));
		const fresh =
			attempt.command === command &&
			attempt.workspaceId === scope.workspaceId &&
			attempt.dispatchedAt <= now + 60_000 &&
			now - attempt.dispatchedAt <= ATTEMPT_MAX_AGE_MS;
		if (fresh) return attempt;
	} catch {
		// unreadable: dropped below
	}
	clearAttempt(store, scope, command);
	return null;
}

/**
 * Drops every kept attempt older than ATTEMPT_MAX_AGE_MS (or unreadable), for
 * any person, workspace or command, including the income page's own entries
 * (`savedAt`). Runs when the app shell starts, so attempts never outlive 24 h.
 */
export function sweepAttempts(
	store: AttemptStore & { keys(): string[] },
	now: number = Date.now()
): void {
	for (const key of store.keys()) {
		if (!key.startsWith(ATTEMPT_PREFIX)) continue;
		try {
			const entry = JSON.parse(store.getItem(key) ?? '') as {
				dispatchedAt?: unknown;
				savedAt?: unknown;
			};
			const at = typeof entry.dispatchedAt === 'number' ? entry.dispatchedAt : entry.savedAt;
			if (typeof at !== 'number' || now - at > ATTEMPT_MAX_AGE_MS) store.removeItem(key);
		} catch {
			store.removeItem(key);
		}
	}
}

export function clearAttempt(store: AttemptStore, scope: AttemptScope, command: string): void {
	try {
		store.removeItem(storageKey(scope, command));
	} catch {
		// nothing stored
	}
}
