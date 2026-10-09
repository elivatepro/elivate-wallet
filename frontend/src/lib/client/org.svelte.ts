// Client side of the org-management pages (Blueprint 07): one validated read
// helper and a small command runner per dialog that owns its idempotency key
// (kept when the outcome is unknown, renewed after a definite answer, W-00),
// its busy flag and what the dialog should say.

import { Cause, Effect, Exit, Option, type Schema } from 'effect';
import type { ApiFailure } from '#lib/contract/errors.js';
import { CommandResult } from '#lib/contract/org-admin.js';
import { describeOrgFailure, keepsKey } from '#lib/org.js';
import { getJson, newKey, sendCommand } from './api';

export const failureOf = <A>(exit: Exit.Exit<A, ApiFailure>) =>
	Exit.isFailure(exit) ? Option.getOrUndefined(Cause.findErrorOption(exit.cause)) : undefined;

export type Loaded<A> = { ok: true; value: A } | { ok: false; text: string; status: number | null };

export async function loadView<S extends Schema.ConstraintDecoder<unknown>>(
	path: string,
	schema: S
): Promise<Loaded<S['Type']>> {
	const exit = await Effect.runPromiseExit(getJson(path, schema));
	if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
	const failure = failureOf(exit);
	if (failure?._tag === 'BackendError') {
		return { ok: false, text: failure.message, status: failure.status };
	}
	return { ok: false, text: 'We couldn’t load this. Try again.', status: null };
}

export class OrgCommand {
	busy = $state(false);
	error = $state<string | null>(null);
	pinError = $state<string | null>(null);
	#key = newKey();
	#target: string | null = null;

	/** A new target (another row) starts a new attempt. */
	reset(target: string | null = null): void {
		if (target !== this.#target) this.#key = newKey();
		this.#target = target;
		this.error = null;
		this.pinError = null;
	}

	async send(
		path: string,
		method: 'POST' | 'PUT' | 'PATCH',
		body: Record<string, unknown>,
		workspaceId: string,
		withKey = true
	): Promise<Readonly<Record<string, unknown>> | null> {
		this.busy = true;
		this.error = null;
		this.pinError = null;
		const exit = await Effect.runPromiseExit(
			sendCommand(
				path,
				method,
				withKey ? { ...body, idempotencyKey: this.#key } : body,
				workspaceId,
				CommandResult
			)
		);
		this.busy = false;
		if (Exit.isSuccess(exit)) {
			this.#key = newKey();
			return exit.value;
		}
		const failure = failureOf(exit);
		if (!keepsKey(failure)) this.#key = newKey();
		const said = describeOrgFailure(failure);
		if (said.kind === 'locked') window.location.assign('/pin/locked');
		else if (said.kind === 'pin') this.pinError = said.text;
		else this.error = said.text;
		return null;
	}
}
