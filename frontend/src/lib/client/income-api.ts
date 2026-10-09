// Browser side of Record income's receipt upload: one multipart request to
// the app server (never to Storage directly), decoded with the same envelope
// pipeline as every other same-origin call. XMLHttpRequest rather than fetch
// so the receipt row can show "Uploading · 64%" (Paper v4 J01). Never retried
// automatically.

import { Effect } from 'effect';
import { decodeResponse } from '#lib/contract/envelope.js';
import { TransportError, type ApiFailure } from '#lib/contract/errors.js';
import { EvidenceFinalized, IncomeAppRoutes } from '#lib/contract/income.js';

const UPLOAD_TIMEOUT_MS = 90_000;

interface Reply {
	readonly status: number;
	readonly text: string;
}

export function sendForm(
	path: string,
	body: FormData,
	workspaceId: string,
	onProgress?: (fraction: number) => void
): Promise<Reply> {
	return new Promise((resolve, reject) => {
		const xhr = new XMLHttpRequest();
		xhr.open('POST', path);
		xhr.timeout = UPLOAD_TIMEOUT_MS;
		xhr.setRequestHeader('accept', 'application/json');
		xhr.setRequestHeader('x-ew-workspace', workspaceId);
		xhr.upload.onprogress = (event) => {
			if (event.lengthComputable && event.total > 0) onProgress?.(event.loaded / event.total);
		};
		xhr.onload = () => resolve({ status: xhr.status, text: xhr.responseText });
		xhr.onerror = () => reject(new TransportError({ reason: 'network', status: null }));
		xhr.ontimeout = () => reject(new TransportError({ reason: 'timeout', status: null }));
		xhr.onabort = () => reject(new TransportError({ reason: 'aborted', status: null }));
		xhr.send(body);
	});
}

export function uploadReceipt(
	input: { file: File; targetMembershipId: string; idempotencyKey: string; pin?: string },
	workspaceId: string,
	onProgress?: (fraction: number) => void
): Effect.Effect<typeof EvidenceFinalized.Type, ApiFailure> {
	const route = `POST ${IncomeAppRoutes.receipts}`;
	return Effect.gen(function* () {
		const body = new FormData();
		body.set('targetMembershipId', input.targetMembershipId);
		body.set('idempotencyKey', input.idempotencyKey);
		if (input.pin) body.set('pin', input.pin);
		body.set('file', input.file, input.file.name);
		const reply = yield* Effect.tryPromise({
			try: () => sendForm(IncomeAppRoutes.receipts, body, workspaceId, onProgress),
			catch: (error) =>
				error instanceof TransportError
					? error
					: new TransportError({ reason: 'network', status: null })
		});
		let json: unknown;
		try {
			json = reply.text ? JSON.parse(reply.text) : undefined;
		} catch {
			json = undefined;
		}
		return yield* decodeResponse(route, reply.status, json, EvidenceFinalized);
	});
}

/** Payout transfer receipt (Blueprint 11): same pipeline, bound to the payout command key. */
export function uploadPayoutReceipt(
	input: { file: File; withdrawalId: string; idempotencyKey: string; pin?: string },
	workspaceId: string,
	path: string,
	onProgress?: (fraction: number) => void
): Effect.Effect<typeof EvidenceFinalized.Type, ApiFailure> {
	const route = `POST ${path}`;
	return Effect.gen(function* () {
		const body = new FormData();
		body.set('idempotencyKey', input.idempotencyKey);
		if (input.pin) body.set('pin', input.pin);
		body.set('file', input.file, input.file.name);
		const reply = yield* Effect.tryPromise({
			try: () => sendForm(path, body, workspaceId, onProgress),
			catch: (error) =>
				error instanceof TransportError
					? error
					: new TransportError({ reason: 'network', status: null })
		});
		let json: unknown;
		try {
			json = reply.text ? JSON.parse(reply.text) : undefined;
		} catch {
			json = undefined;
		}
		return yield* decodeResponse(route, reply.status, json, EvidenceFinalized);
	});
}
