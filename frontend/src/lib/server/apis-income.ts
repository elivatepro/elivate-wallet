// IncomeApi (Blueprint 04 income routes; Blueprint 09): eligible targets,
// receipt upload (intent → signed upload → finalize) and the record/cancel
// commands. Reads retry; commands never do (the browser keeps the key).

import { Context, Effect, Layer, Schedule } from 'effect';
import { isRetryableRead, TransportError } from '#lib/contract/errors.js';
import {
	CancelIncomeResult,
	EvidenceFinalized,
	EvidenceUploadIntent,
	IncomePosted,
	IncomeRoutes,
	IncomeTargets,
	type RecordIncomeInput
} from '#lib/contract/income.js';
import { EdgeTransport, type EdgeFailure } from './edge';

const readPolicy = {
	times: 2,
	while: isRetryableRead,
	schedule: Schedule.exponential('200 millis').pipe(Schedule.jittered)
};

/** Only the private evidence bucket's signed-upload path is ever accepted. */
const SIGNED_UPLOAD_PATH =
	/^\/storage\/v1\/object\/upload\/sign\/financial-evidence\/[0-9a-f-]+\/income\/[0-9a-f-]+$/;
const UPLOAD_TIMEOUT_MS = 60_000;

/**
 * The signed upload URL the Edge Function built, re-based onto the app's own
 * Supabase origin (inside the local stack the function sees an internal host).
 * Null for anything that is not the evidence bucket's signed-upload path.
 */
export function rebaseUploadUrl(uploadUrl: string, supabaseUrl: string): string | null {
	let parsed: URL;
	try {
		parsed = new URL(uploadUrl);
	} catch {
		return null;
	}
	if (!SIGNED_UPLOAD_PATH.test(parsed.pathname) || !parsed.searchParams.get('token')) return null;
	const target = new URL(supabaseUrl);
	target.pathname = parsed.pathname;
	target.search = `?token=${encodeURIComponent(parsed.searchParams.get('token') ?? '')}`;
	return target.toString();
}

export interface ReceiptUpload {
	readonly targetMembershipId: string;
	readonly idempotencyKey: string;
	readonly fileName: string;
	readonly mimeType: string;
	readonly bytes: Uint8Array<ArrayBuffer>;
	readonly sha256: string;
}

export interface IncomeApiShape {
	readonly targets: (
		membershipId: string,
		cursor: string | null
	) => Effect.Effect<typeof IncomeTargets.Type, EdgeFailure>;
	readonly uploadReceipt: (
		membershipId: string,
		upload: ReceiptUpload
	) => Effect.Effect<typeof EvidenceFinalized.Type, EdgeFailure>;
	readonly record: (
		membershipId: string,
		input: RecordIncomeInput
	) => Effect.Effect<typeof IncomePosted.Type, EdgeFailure>;
	readonly cancel: (
		membershipId: string,
		input: { targetMembershipId: string; reason: string; idempotencyKey: string }
	) => Effect.Effect<typeof CancelIncomeResult.Type, EdgeFailure>;
}

export class IncomeApi extends Context.Service<IncomeApi, IncomeApiShape>()('IncomeApi') {}

export interface IncomeStorageOptions {
	readonly supabaseUrl: string;
	readonly publishableKey: string;
	readonly fetch: typeof globalThis.fetch;
}

export const IncomeApiLive = (storage: IncomeStorageOptions) =>
	Layer.effect(
		IncomeApi,
		Effect.gen(function* () {
			const edge = yield* EdgeTransport;
			const fn = 'ledger' as const;

			const putObject = (uploadUrl: string, upload: ReceiptUpload) =>
				Effect.gen(function* () {
					const url = rebaseUploadUrl(uploadUrl, storage.supabaseUrl);
					if (!url)
						return yield* Effect.fail(new TransportError({ reason: 'non_envelope', status: null }));
					const response = yield* Effect.tryPromise({
						try: () =>
							storage.fetch(url, {
								method: 'PUT',
								headers: {
									apikey: storage.publishableKey,
									'content-type': upload.mimeType,
									'x-upsert': 'false'
								},
								body: upload.bytes,
								redirect: 'error',
								cache: 'no-store',
								signal: AbortSignal.timeout(UPLOAD_TIMEOUT_MS)
							}),
						catch: () => new TransportError({ reason: 'network', status: null })
					});
					// Drain the body; its content is not needed.
					yield* Effect.promise(() => response.arrayBuffer().catch(() => null));
					if (!response.ok) {
						return yield* Effect.fail(
							new TransportError({ reason: 'non_envelope', status: response.status })
						);
					}
				});

			return {
				targets: (membershipId, cursor) =>
					edge
						.call(
							{
								fn,
								route: IncomeRoutes.targets,
								membershipId,
								query: { limit: '100', ...(cursor ? { cursor } : {}) }
							},
							IncomeTargets
						)
						.pipe(Effect.retry(readPolicy)),
				uploadReceipt: (membershipId, upload) =>
					Effect.gen(function* () {
						const intent = yield* edge.call(
							{
								fn,
								route: IncomeRoutes.createUpload,
								membershipId,
								body: {
									targetMembershipId: upload.targetMembershipId,
									idempotencyKey: upload.idempotencyKey,
									fileName: upload.fileName,
									mimeType: upload.mimeType,
									size: upload.bytes.length,
									sha256: upload.sha256
								}
							},
							EvidenceUploadIntent
						);
						yield* putObject(intent.uploadUrl, upload);
						return yield* edge.call(
							{
								fn,
								route: IncomeRoutes.finalizeUpload(intent.evidenceId),
								membershipId,
								body: {}
							},
							EvidenceFinalized
						);
					}),
				record: (membershipId, input) =>
					edge.call({ fn, route: IncomeRoutes.record, membershipId, body: input }, IncomePosted),
				cancel: (membershipId, input) =>
					edge.call(
						{ fn, route: IncomeRoutes.cancel, membershipId, body: input },
						CancelIncomeResult
					)
			};
		})
	);
