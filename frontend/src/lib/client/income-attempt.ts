// Unknown-outcome recovery for Record income (F-03, W-00, W-08 "Recovery").
//
// Before POST /api/income is dispatched, the exact attempt (its idempotency
// key and request body) is kept on this device so a timeout, dropped
// connection or reload can be resolved with the SAME key: re-send (the backend
// replays, never posts twice) or cancel through the trusted command. Never
// stored: PINs, tokens, file contents. Scoped to the person and workspace;
// dropped after 24 h and on any definitive answer.
//
// Isolated on purpose: when the shared F-03 utility (member build slice 2)
// lands in #lib, this module is the one call site to switch over.

import { Schema } from 'effect';
import { RecordIncomeInput } from '#lib/contract/income.js';

export const ATTEMPT_PREFIX = 'ew:attempt:v1:income:';
export const ATTEMPT_MAX_AGE_MS = 24 * 60 * 60 * 1000;

export const IncomeAttempt = Schema.Struct({
	savedAt: Schema.Number,
	/** What the screen shows while the outcome is unknown (no secrets). */
	target: Schema.Struct({
		name: Schema.NullOr(Schema.String),
		uid: Schema.String,
		officeName: Schema.String
	}),
	request: RecordIncomeInput
});
export type IncomeAttempt = typeof IncomeAttempt.Type;

/** Minimal synchronous store (localStorage in the browser). */
export interface AttemptStore {
	getItem(key: string): string | null;
	setItem(key: string, value: string): void;
	removeItem(key: string): void;
}

export interface AttemptScope {
	readonly uid: string;
	readonly workspaceId: string;
}

const keyFor = (scope: AttemptScope) =>
	`${ATTEMPT_PREFIX}${encodeURIComponent(scope.uid)}:${encodeURIComponent(scope.workspaceId)}`;

export function saveAttempt(
	store: AttemptStore,
	scope: AttemptScope,
	attempt: IncomeAttempt
): void {
	// Encoding through the schema drops anything it doesn't name (e.g. a PIN).
	const text = JSON.stringify(Schema.encodeSync(IncomeAttempt)(attempt));
	try {
		store.setItem(keyFor(scope), text);
	} catch {
		// Quota or privacy mode: the screen still holds the attempt in memory.
	}
}

export function loadAttempt(
	store: AttemptStore,
	scope: AttemptScope,
	now: number = Date.now()
): IncomeAttempt | null {
	const key = keyFor(scope);
	let raw: string | null;
	try {
		raw = store.getItem(key);
	} catch {
		return null;
	}
	if (!raw) return null;
	try {
		const attempt = Schema.decodeUnknownSync(IncomeAttempt)(JSON.parse(raw));
		if (now - attempt.savedAt > ATTEMPT_MAX_AGE_MS || attempt.savedAt > now + 60_000) {
			store.removeItem(key);
			return null;
		}
		return attempt;
	} catch {
		store.removeItem(key);
		return null;
	}
}

export function clearAttempt(store: AttemptStore, scope: AttemptScope): void {
	try {
		store.removeItem(keyFor(scope));
	} catch {
		// best-effort
	}
}

/** localStorage, or null when it is unavailable (SSR, privacy mode). */
export function browserAttemptStore(): AttemptStore | null {
	try {
		return typeof localStorage === 'undefined' ? null : localStorage;
	} catch {
		return null;
	}
}
