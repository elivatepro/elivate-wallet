// Browser side of Record income's receipt upload: one multipart request to
// the app server (never to Storage directly), decoded with the same envelope
// pipeline as every other same-origin call. Never retried automatically.

import { Effect } from 'effect';
import { decodeResponse } from '#lib/contract/envelope.js';
import { TransportError, type ApiFailure } from '#lib/contract/errors.js';
import { EvidenceFinalized, IncomeAppRoutes } from '#lib/contract/income.js';

const UPLOAD_TIMEOUT_MS = 90_000;

export function uploadReceipt(
	input: { file: File; targetMembershipId: string; idempotencyKey: string; pin?: string },
	workspaceId: string
): Effect.Effect<typeof EvidenceFinalized.Type, ApiFailure> {
	const route = `POST ${IncomeAppRoutes.receipts}`;
	return Effect.gen(function* () {
		const body = new FormData();
		body.set('targetMembershipId', input.targetMembershipId);
		body.set('idempotencyKey', input.idempotencyKey);
		if (input.pin) body.set('pin', input.pin);
		body.set('file', input.file, input.file.name);
		const timeout = AbortSignal.timeout(UPLOAD_TIMEOUT_MS);
		const response = yield* Effect.tryPromise({
			try: () =>
				fetch(IncomeAppRoutes.receipts, {
					method: 'POST',
					headers: { accept: 'application/json', 'x-ew-workspace': workspaceId },
					body,
					signal: timeout,
					redirect: 'error',
					cache: 'no-store'
				}),
			catch: () =>
				new TransportError({ reason: timeout.aborted ? 'timeout' : 'network', status: null })
		});
		const text = yield* Effect.tryPromise({
			try: () => response.text(),
			catch: () => new TransportError({ reason: 'network', status: response.status })
		});
		let json: unknown;
		try {
			json = text ? JSON.parse(text) : undefined;
		} catch {
			json = undefined;
		}
		return yield* decodeResponse(route, response.status, json, EvidenceFinalized);
	});
}
