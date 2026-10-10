// LedgerApi (Blueprints 04 and 08): own wallet, own activity and transaction
// detail, the network's split and the President's split change (reason +
// step-up), managed wallets, the leadership overview and the unknown-outcome
// lookup. Reads retry; the command never does (the caller keeps its key).

import { Context, Effect, Layer, Schedule } from 'effect';
import { HomeView } from '#lib/contract/app.js';
import { isRetryableRead } from '#lib/contract/errors.js';
import {
	Activity,
	Allocation,
	AllocationVersions,
	CommandOutcome,
	LeadershipOverview,
	LedgerRoutes,
	ManagedWallet,
	ManagedWalletPage,
	TransactionDetail,
	Wallet,
	type ActivityQuery,
	type Allocation as AllocationType
} from '#lib/contract/ledger.js';
import { EdgeTransport, type EdgeFailure } from './edge';

/** Only the keys that were set, as strings (the Edge rejects unknown or empty ones). */
export function activityParams(
	query: Readonly<Record<string, string | number | undefined>>
): Record<string, string> {
	const params: Record<string, string> = {};
	for (const [key, value] of Object.entries(query)) {
		if (value !== undefined && value !== null && value !== '') params[key] = String(value);
	}
	return params;
}

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
	/** Blueprint 20: the own wallet limited to the workspace's network (resolved by the backend). */
	readonly walletIn: (membershipId: string) => Effect.Effect<typeof Wallet.Type, EdgeFailure>;
	/**
	 * Own activity. With a membership id (Blueprint 20) the backend resolves the
	 * network from the caller's own membership; `query.tenantId` must then be unset.
	 */
	readonly activity: (
		query: ActivityQuery,
		membershipId?: string
	) => Effect.Effect<typeof Activity.Type, EdgeFailure>;
	/** Blueprint 20: Home (W-07) in one read for the workspace. */
	readonly home: (membershipId: string) => Effect.Effect<HomeView, EdgeFailure>;
	readonly transaction: (id: string) => Effect.Effect<TransactionDetail, EdgeFailure>;
	readonly commandOutcome: (
		idempotencyKey: string,
		command: string | null
	) => Effect.Effect<CommandOutcome, EdgeFailure>;
	readonly overview: (
		membershipId: string,
		tz: string | null
	) => Effect.Effect<LeadershipOverview, EdgeFailure>;
	readonly managedWallets: (
		membershipId: string,
		query: { q?: string; cursor?: string; officeId?: string }
	) => Effect.Effect<ManagedWalletPage, EdgeFailure>;
	readonly managedWallet: (
		membershipId: string,
		walletId: string
	) => Effect.Effect<ManagedWallet, EdgeFailure>;
	readonly managedActivity: (
		membershipId: string,
		walletId: string,
		query: ActivityQuery
	) => Effect.Effect<typeof Activity.Type, EdgeFailure>;
	readonly managedTransaction: (
		membershipId: string,
		walletId: string,
		id: string
	) => Effect.Effect<TransactionDetail, EdgeFailure>;
	readonly allocation: (membershipId: string) => Effect.Effect<AllocationType, EdgeFailure>;
	readonly versions: (
		membershipId: string
	) => Effect.Effect<typeof AllocationVersions.Type, EdgeFailure>;
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
			walletIn: (membershipId) =>
				edge
					.call({ fn, route: LedgerRoutes.wallet, membershipId }, Wallet)
					.pipe(Effect.retry(readPolicy)),
			activity: (query, membershipId) =>
				edge
					.call(
						{
							fn,
							route: LedgerRoutes.activity,
							query: activityParams(query),
							...(membershipId ? { membershipId } : {})
						},
						Activity
					)
					.pipe(Effect.retry(readPolicy)),
			home: (membershipId) =>
				edge
					.call({ fn, route: LedgerRoutes.home, membershipId }, HomeView)
					.pipe(Effect.retry(readPolicy)),
			transaction: (id) =>
				edge
					.call({ fn, route: LedgerRoutes.transaction(id) }, TransactionDetail)
					.pipe(Effect.retry(readPolicy)),
			// A read, but never retried on its own: the caller decides when to ask again.
			commandOutcome: (idempotencyKey, command) =>
				edge.call(
					{
						fn,
						route: LedgerRoutes.commandOutcome,
						query: command ? { idempotencyKey, command } : { idempotencyKey }
					},
					CommandOutcome
				),
			overview: (membershipId, tz) =>
				edge
					.call(
						{ fn, route: LedgerRoutes.overview, membershipId, query: tz ? { tz } : {} },
						LeadershipOverview
					)
					.pipe(Effect.retry(readPolicy)),
			managedWallets: (membershipId, query) =>
				edge
					.call(
						{
							fn,
							route: LedgerRoutes.managedWallets,
							membershipId,
							query: activityParams(query)
						},
						ManagedWalletPage
					)
					.pipe(Effect.retry(readPolicy)),
			managedWallet: (membershipId, walletId) =>
				edge
					.call({ fn, route: LedgerRoutes.managedWallet(walletId), membershipId }, ManagedWallet)
					.pipe(Effect.retry(readPolicy)),
			managedActivity: (membershipId, walletId, query) =>
				edge
					.call(
						{
							fn,
							route: LedgerRoutes.managedActivity(walletId),
							membershipId,
							query: activityParams(query)
						},
						Activity
					)
					.pipe(Effect.retry(readPolicy)),
			managedTransaction: (membershipId, walletId, id) =>
				edge
					.call(
						{ fn, route: LedgerRoutes.managedTransaction(walletId, id), membershipId },
						TransactionDetail
					)
					.pipe(Effect.retry(readPolicy)),
			allocation: (membershipId) =>
				edge
					.call({ fn, route: LedgerRoutes.allocation, membershipId }, Allocation)
					.pipe(Effect.retry(readPolicy)),
			versions: (membershipId) =>
				edge
					.call({ fn, route: LedgerRoutes.versions, membershipId }, AllocationVersions)
					.pipe(Effect.retry(readPolicy)),
			setAllocation: (membershipId, input) =>
				edge.call({ fn, route: LedgerRoutes.setAllocation, body: input, membershipId }, Allocation)
		};
	})
);
