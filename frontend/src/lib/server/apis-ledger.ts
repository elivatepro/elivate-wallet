// LedgerApi (Blueprint 04): own wallet, own activity, the network's split and
// the President's split change (reason + step-up). Reads retry; the command
// never does (the caller keeps its idempotency key).

import { Context, Effect, Layer, Schedule } from 'effect';
import { isRetryableRead } from '#lib/contract/errors.js';
import {
	Activity,
	Allocation,
	LedgerRoutes,
	Wallet,
	type Allocation as AllocationType
} from '#lib/contract/ledger.js';
import { EdgeTransport, type EdgeFailure } from './edge';

const readPolicy = {
	times: 2,
	while: isRetryableRead,
	schedule: Schedule.exponential('200 millis').pipe(Schedule.jittered)
};

export interface SplitInput {
	readonly expectedVersion: number;
	readonly pockets: ReadonlyArray<{ pocketId: string | null; name: string; basisPoints: number }>;
	readonly reason: string;
	readonly idempotencyKey: string;
}

export interface LedgerApiShape {
	readonly wallet: Effect.Effect<typeof Wallet.Type, EdgeFailure>;
	readonly activity: (query: {
		tenantId?: string;
		limit?: number;
	}) => Effect.Effect<typeof Activity.Type, EdgeFailure>;
	readonly allocation: (membershipId: string) => Effect.Effect<AllocationType, EdgeFailure>;
	readonly setAllocation: (
		membershipId: string,
		input: SplitInput
	) => Effect.Effect<AllocationType, EdgeFailure>;
}

export class LedgerApi extends Context.Service<LedgerApi, LedgerApiShape>()('LedgerApi') {}

export const LedgerApiLive = Layer.effect(
	LedgerApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		const fn = 'ledger' as const;
		return {
			wallet: edge.call({ fn, route: LedgerRoutes.wallet }, Wallet).pipe(Effect.retry(readPolicy)),
			activity: (query) => {
				const params: Record<string, string> = {};
				if (query.tenantId) params.tenantId = query.tenantId;
				if (query.limit) params.limit = String(query.limit);
				return edge
					.call({ fn, route: LedgerRoutes.activity, query: params }, Activity)
					.pipe(Effect.retry(readPolicy));
			},
			allocation: (membershipId) =>
				edge
					.call({ fn, route: LedgerRoutes.allocation, membershipId }, Allocation)
					.pipe(Effect.retry(readPolicy)),
			setAllocation: (membershipId, input) =>
				edge.call({ fn, route: LedgerRoutes.setAllocation, body: input, membershipId }, Allocation)
		};
	})
);
