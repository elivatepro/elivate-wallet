// Shared command runner with unknown-outcome recovery (F-03, W-00,
// Blueprint 08 B5). Every money/protected command form uses one instance per
// command:
//
//   const attempt = new CommandAttempt({
//     command: 'record_income',            // backend command name
//     path: '/api/income', method: 'POST',
//     schema: IncomeResult,                // response schema
//     scope: () => ({ uid, workspaceId })  // storage scope, null = memory only
//   });
//   onMount(() => void attempt.restore()); // picks up an attempt left by a reload
//   await attempt.send(workspaceId, body, { pin, summary: '₦120,000.00 income for Kemi' });
//   attempt.state.kind: idle | sending | done | failed | unknown | checking | resolved
//
// While the outcome is unknown, `send` refuses a new submission (W-00:
// conflicting submissions are disabled) and the page shows
// #lib/ui/app/OutcomeUnknown.svelte bound to this instance (check / resend /
// dismiss). The key is rotated only after a definitive answer.

import { Cause, Effect, Exit, Option, type Schema } from 'effect';
import type { ApiFailure } from '#lib/contract/errors.js';
import { CommandOutcome } from '#lib/contract/ledger.js';
import {
	clearAttempt,
	isUnknownOutcome,
	keepsAttempt,
	loadAttempt,
	resolveOutcome,
	saveAttempt,
	type AttemptScope,
	type AttemptStore,
	type PendingAttempt,
	type Resolution
} from '#lib/recovery.js';
import { getJson, newKey, sendCommand } from './api';

export type AttemptState<A> =
	| { readonly kind: 'idle' }
	| { readonly kind: 'sending' }
	| { readonly kind: 'done'; readonly result: A }
	| { readonly kind: 'failed'; readonly failure: ApiFailure }
	| { readonly kind: 'unknown'; readonly attempt: PendingAttempt }
	| { readonly kind: 'checking'; readonly attempt: PendingAttempt }
	| {
			readonly kind: 'resolved';
			readonly attempt: PendingAttempt;
			readonly resolution: Resolution;
	  };

/** What the recovery screen needs from any CommandAttempt (OutcomeUnknown.svelte). */
export interface AttemptControls {
	readonly state: AttemptState<unknown>;
	check(): Promise<unknown>;
	resend(options?: { pin?: string }): Promise<unknown>;
	reset(): void;
}

export interface CommandAttemptOptions<S extends Schema.ConstraintDecoder<unknown>> {
	readonly command: string;
	readonly path: string;
	readonly method: 'POST' | 'PUT' | 'PATCH';
	readonly schema: S;
	/** Where the attempt is kept across reloads; null keeps it in memory only. */
	readonly scope: () => AttemptScope | null;
	/** False for forms whose body must not be stored (e.g. a full account number). */
	readonly persistBody?: boolean;
	readonly store?: AttemptStore | null;
	readonly now?: () => number;
	/** Test seams; default to the same-origin helpers. */
	readonly send?: (
		path: string,
		method: 'POST' | 'PUT' | 'PATCH',
		body: unknown,
		workspaceId: string,
		schema: S
	) => Effect.Effect<S['Type'], ApiFailure>;
	readonly lookup?: (key: string, command: string) => Effect.Effect<CommandOutcome, ApiFailure>;
}

const browserStore = (): AttemptStore | null => {
	try {
		return typeof localStorage === 'undefined' ? null : localStorage;
	} catch {
		return null;
	}
};

const outcomePath = (key: string, command: string) =>
	`/api/commands/outcome?${new URLSearchParams({ key, command })}`;

const failureOf = <A>(exit: Exit.Exit<A, ApiFailure>): ApiFailure | undefined =>
	Exit.isFailure(exit) ? Option.getOrUndefined(Cause.findErrorOption(exit.cause)) : undefined;

export class CommandAttempt<
	S extends Schema.ConstraintDecoder<unknown>
> implements AttemptControls {
	state: AttemptState<S['Type']> = $state({ kind: 'idle' });
	#key = newKey();
	/** The exact body sent with the current key (memory only; includes no PIN). */
	#body: Record<string, unknown> | null = null;
	#replaying = false;
	readonly #o: CommandAttemptOptions<S>;
	readonly #store: AttemptStore | null;
	readonly #now: () => number;

	constructor(options: CommandAttemptOptions<S>) {
		this.#o = options;
		this.#store = options.store === undefined ? browserStore() : options.store;
		this.#now = options.now ?? Date.now;
	}

	/** The idempotency key of the current attempt. */
	get key(): string {
		return this.#key;
	}

	/** True while a submission must not start (sending, or an outcome is not settled). */
	get blocked(): boolean {
		const s = this.state;
		if (s.kind === 'sending' || s.kind === 'unknown' || s.kind === 'checking') return true;
		if (s.kind !== 'resolved') return false;
		const r = s.resolution;
		return r.kind === 'pending' || (r.kind === 'not_committed' && r.canResend);
	}

	/**
	 * Sends the command. `body` is everything except `idempotencyKey` and `pin`.
	 * Refused (returns the current state) while an earlier outcome is unsettled.
	 */
	async send(
		workspaceId: string,
		body: Readonly<Record<string, unknown>>,
		options: { pin?: string; summary?: string | null } = {}
	): Promise<AttemptState<S['Type']>> {
		if (this.blocked) return this.state;
		return this.#dispatch(workspaceId, { ...body }, options);
	}

	/** Re-sends the SAME key and body (after "not committed", or a PIN prompt). */
	async resend(options: { pin?: string } = {}): Promise<AttemptState<S['Type']>> {
		const attempt = this.#pending();
		if (!attempt || !this.#body) return this.state;
		return this.#dispatch(attempt.workspaceId, this.#body, {
			pin: options.pin,
			summary: attempt.summary
		});
	}

	/** Asks the backend what happened to the pending attempt. */
	async check(): Promise<AttemptState<S['Type']>> {
		const attempt = this.#pending();
		if (!attempt) return this.state;
		this.state = { kind: 'checking', attempt };
		const lookup =
			this.#o.lookup ?? ((key, command) => getJson(outcomePath(key, command), CommandOutcome));
		const exit = await Effect.runPromiseExit(lookup(attempt.key, attempt.command));
		if (Exit.isFailure(exit)) {
			// Still unknown: keep everything and let the person ask again.
			this.state = { kind: 'unknown', attempt };
			return this.state;
		}
		const resolution = resolveOutcome(exit.value, attempt, this.#now());
		if (resolution.kind === 'committed' && this.#body) {
			// Same-key replay returns the stored result under current authority.
			this.#replaying = true;
			const replay = await this.#dispatch(attempt.workspaceId, this.#body, {
				summary: attempt.summary
			}).finally(() => (this.#replaying = false));
			if (replay.kind === 'done') return replay;
			// e.g. the PIN window closed: it still went through.
			this.#settle();
		} else if (resolution.kind === 'committed' || resolution.kind === 'cancelled') {
			this.#settle();
		}
		this.state = { kind: 'resolved', attempt, resolution };
		return this.state;
	}

	/** Picks up an attempt left on this device (reload, app update) and checks it. */
	async restore(): Promise<AttemptState<S['Type']>> {
		const scope = this.#o.scope();
		if (!scope || !this.#store || this.state.kind !== 'idle') return this.state;
		const attempt = loadAttempt(this.#store, scope, this.#o.command, this.#now());
		if (!attempt) return this.state;
		this.#key = attempt.key;
		this.#body = attempt.body;
		this.state = { kind: 'unknown', attempt };
		return this.check();
	}

	/** Back to a fresh form. Only once the outcome is settled. */
	reset(): void {
		if (this.blocked) return;
		this.#settle();
		this.state = { kind: 'idle' };
	}

	#pending(): PendingAttempt | null {
		const s = this.state;
		return s.kind === 'unknown' || s.kind === 'checking' || s.kind === 'resolved'
			? s.attempt
			: null;
	}

	/** Forgets the stored attempt and starts a new key. */
	#settle(): void {
		const scope = this.#o.scope();
		if (scope && this.#store) clearAttempt(this.#store, scope, this.#o.command);
		this.#key = newKey();
		this.#body = null;
	}

	async #dispatch(
		workspaceId: string,
		body: Record<string, unknown>,
		options: { pin?: string | undefined; summary?: string | null | undefined }
	): Promise<AttemptState<S['Type']>> {
		const attempt: PendingAttempt = {
			key: this.#key,
			command: this.#o.command,
			workspaceId,
			dispatchedAt: this.#now(),
			summary: options.summary ?? null,
			body: this.#o.persistBody === false ? null : body
		};
		this.#body = body;
		// Kept BEFORE dispatch (F-03), so a reload mid-flight can still recover.
		const scope = this.#o.scope();
		if (scope && this.#store) saveAttempt(this.#store, scope, attempt);
		this.state = { kind: 'sending' };

		const send = this.#o.send ?? sendCommand;
		const payload = {
			...body,
			...(options.pin ? { pin: options.pin } : {}),
			idempotencyKey: attempt.key
		};
		const exit = await Effect.runPromiseExit(
			send(this.#o.path, this.#o.method, payload, workspaceId, this.#o.schema)
		);
		if (Exit.isSuccess(exit)) {
			this.#settle();
			this.state = { kind: 'done', result: exit.value };
			return this.state;
		}
		const failure = failureOf(exit);
		if (isUnknownOutcome(failure)) {
			this.state = { kind: 'unknown', attempt: { ...attempt, body } };
			return this.#replaying ? this.state : this.check();
		}
		if (keepsAttempt(failure)) {
			// A PIN prompt: nothing ran; the same key goes again with the PIN.
			const scopeNow = this.#o.scope();
			if (scopeNow && this.#store) clearAttempt(this.#store, scopeNow, this.#o.command);
		} else {
			this.#settle();
		}
		if (failure) this.state = { kind: 'failed', failure };
		return this.state;
	}
}
