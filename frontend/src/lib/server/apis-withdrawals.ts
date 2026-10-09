// MoneyMovesApi (Blueprint 11): withdrawals, payouts, evidence review and
// pocket moves on the `ledger` Edge Function. Reads retry; commands never do
// (the browser keeps the idempotency key). Payout receipts upload through
// the signed-upload flow shared with income, and are read back through this
// server so the browser never sees a storage URL.

import { Context, Effect, Layer, Schedule, type Schema } from 'effect';
import { isRetryableRead, TransportError } from '#lib/contract/errors.js';
import { EvidenceFinalized } from '#lib/contract/income.js';
import { EvidenceUploadIntent, WithdrawalRoutes } from '#lib/contract/withdrawals.js';
import { EdgeTransport, type EdgeFailure, type EdgeRoute } from './edge';
import { putEvidence, type IncomeStorageOptions } from './apis-income';

const readPolicy = {
	times: 2,
	while: isRetryableRead,
	schedule: Schedule.exponential('200 millis').pipe(Schedule.jittered)
};

/** Only the private evidence bucket's signed read path is ever followed. */
const SIGNED_READ_PATH =
	/^\/storage\/v1\/object\/sign\/financial-evidence\/[0-9a-f-]+\/payout\/[0-9a-f-]+$/;
const RECEIPT_MAX_BYTES = 10 * 1024 * 1024;

export interface PayoutReceiptUpload {
	readonly withdrawalId: string;
	readonly idempotencyKey: string;
	readonly fileName: string;
	readonly mimeType: string;
	readonly bytes: Uint8Array<ArrayBuffer>;
	readonly sha256: string;
}

export interface ReceiptBytes {
	readonly bytes: Uint8Array<ArrayBuffer>;
	readonly mimeType: string;
}

export interface MoneyMovesApiShape {
	readonly read: <S extends Schema.ConstraintDecoder<unknown>>(
		membershipId: string,
		route: EdgeRoute,
		query: Readonly<Record<string, string>>,
		schema: S
	) => Effect.Effect<S['Type'], EdgeFailure>;
	readonly command: <S extends Schema.ConstraintDecoder<unknown>>(
		membershipId: string,
		route: EdgeRoute,
		body: unknown,
		schema: S
	) => Effect.Effect<S['Type'], EdgeFailure>;
	readonly uploadPayoutReceipt: (
		membershipId: string,
		upload: PayoutReceiptUpload
	) => Effect.Effect<typeof EvidenceFinalized.Type, EdgeFailure>;
	/** Follows a signed receipt link from the Edge Function; bytes stay server-side. */
	readonly fetchReceipt: (signedUrl: string) => Effect.Effect<ReceiptBytes, TransportError>;
}

export class MoneyMovesApi extends Context.Service<MoneyMovesApi, MoneyMovesApiShape>()(
	'MoneyMovesApi'
) {}

/** The signed read URL re-based onto the app's Supabase origin; null for anything else. */
export function rebaseReadUrl(signedUrl: string, supabaseUrl: string): string | null {
	let parsed: URL;
	try {
		parsed = new URL(signedUrl);
	} catch {
		return null;
	}
	const pathname = parsed.pathname;
	if (!SIGNED_READ_PATH.test(pathname) || !parsed.searchParams.get('token')) return null;
	const target = new URL(supabaseUrl);
	target.pathname = pathname;
	target.search = `?token=${encodeURIComponent(parsed.searchParams.get('token') ?? '')}`;
	return target.toString();
}

export const MoneyMovesApiLive = (storage: IncomeStorageOptions) =>
	Layer.effect(
		MoneyMovesApi,
		Effect.gen(function* () {
			const edge = yield* EdgeTransport;
			const fn = 'ledger' as const;
			return {
				read: (membershipId, route, query, schema) =>
					edge.call({ fn, route, membershipId, query }, schema).pipe(Effect.retry(readPolicy)),
				command: (membershipId, route, body, schema) =>
					edge.call({ fn, route, membershipId, body }, schema),
				uploadPayoutReceipt: (membershipId, upload) =>
					Effect.gen(function* () {
						const intent = yield* edge.call(
							{
								fn,
								route: WithdrawalRoutes.createUpload,
								membershipId,
								body: {
									withdrawalId: upload.withdrawalId,
									idempotencyKey: upload.idempotencyKey,
									fileName: upload.fileName,
									mimeType: upload.mimeType,
									size: upload.bytes.length,
									sha256: upload.sha256
								}
							},
							EvidenceUploadIntent
						);
						yield* putEvidence(storage, intent.uploadUrl, upload.mimeType, upload.bytes);
						return yield* edge.call(
							{
								fn,
								route: WithdrawalRoutes.finalizeUpload(intent.evidenceId),
								membershipId,
								body: {}
							},
							EvidenceFinalized
						);
					}),
				fetchReceipt: (signedUrl) =>
					Effect.gen(function* () {
						const url = rebaseReadUrl(signedUrl, storage.supabaseUrl);
						if (!url) {
							return yield* Effect.fail(
								new TransportError({ reason: 'non_envelope', status: null })
							);
						}
						const response = yield* Effect.tryPromise({
							try: () =>
								storage.fetch(url, {
									headers: { apikey: storage.publishableKey },
									redirect: 'error',
									cache: 'no-store',
									signal: AbortSignal.timeout(30_000)
								}),
							catch: () => new TransportError({ reason: 'network', status: null })
						});
						const bytes = yield* Effect.tryPromise({
							try: () => response.arrayBuffer(),
							catch: () => new TransportError({ reason: 'network', status: null })
						});
						if (!response.ok || bytes.byteLength > RECEIPT_MAX_BYTES) {
							return yield* Effect.fail(
								new TransportError({ reason: 'non_envelope', status: response.status })
							);
						}
						return {
							bytes: new Uint8Array(bytes),
							mimeType: response.headers.get('content-type') ?? 'application/octet-stream'
						};
					})
			};
		})
	);
