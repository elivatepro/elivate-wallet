// One submission of a conversion, adjustment or returned funds (Blueprint 12):
// the evidence uploads with the attempt's key, then the command goes through
// the shared CommandAttempt (F-03). Tried without a PIN first; a PIN prompt
// comes back as `pin` and the caller asks for it and calls again with it.

import type { Schema } from 'effect';
import type { ApiFailure } from '#lib/contract/errors.js';
import type { EntryKind } from '#lib/contract/entries.js';
import { pinProblem } from '#lib/payout.js';
import { isUnknownOutcome } from '#lib/recovery.js';
import type { CommandAttempt } from './command-attempt.svelte';
import type { EntryEvidence } from './entry-evidence.svelte';

export type EntrySubmitResult =
	| { readonly kind: 'done' }
	| { readonly kind: 'unknown' }
	| { readonly kind: 'pin'; readonly message: string }
	| { readonly kind: 'locked' }
	| { readonly kind: 'refused'; readonly failure: ApiFailure | undefined };

export async function submitEntry<S extends Schema.ConstraintDecoder<unknown>>(input: {
	attempt: CommandAttempt<S>;
	evidence: EntryEvidence;
	kind: EntryKind;
	targetMembershipId: string;
	workspaceId: string;
	body: Readonly<Record<string, unknown>>;
	summary: string;
	pin?: string;
}): Promise<EntrySubmitResult> {
	const { attempt, evidence } = input;
	const pin = input.pin ? { pin: input.pin } : {};
	const up = await evidence.upload(
		{ kind: input.kind, targetMembershipId: input.targetMembershipId, key: attempt.key, ...pin },
		input.workspaceId
	);
	if ('failure' in up) {
		// Nothing was sent yet: an upload that didn't answer is retried as is.
		const result = classify(up.failure ?? undefined);
		return result.kind === 'unknown'
			? { kind: 'refused', failure: up.failure ?? undefined }
			: result;
	}
	const state = attempt.awaitingPin
		? await attempt.resend(pin)
		: await attempt.send(
				input.workspaceId,
				{ ...input.body, evidenceIds: up.ids },
				{ ...pin, summary: input.summary }
			);
	if (state.kind === 'done') return { kind: 'done' };
	if (state.kind === 'failed') {
		const result = classify(state.failure);
		if (result.kind === 'refused') attempt.reset();
		return result;
	}
	return { kind: 'unknown' };
}

function classify(failure: ApiFailure | undefined): EntrySubmitResult {
	const problem = pinProblem(failure);
	if (problem?.kind === 'locked') return { kind: 'locked' };
	if (problem) return { kind: 'pin', message: problem.message };
	if (failure && isUnknownOutcome(failure)) return { kind: 'unknown' };
	return { kind: 'refused', failure };
}
