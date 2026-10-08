// IdentityApi and PayoutApi (Blueprints 05/06): one method per route. Reads
// retry like the other services; commands never retry (the caller keeps the
// idempotency key; NIN checks count against a limit).

import { Context, Effect, Layer, Schedule, Schema } from 'effect';
import { isRetryableRead } from '#lib/contract/errors.js';
import {
	decideRoute,
	IdentityRoutes,
	NinVerified,
	OnboardingWorkspace,
	PendingReviews,
	PhotoKey,
	PhotoSet,
	Profile,
	ReviewDecided,
	ReviewRequested,
	type PendingReview
} from '#lib/contract/identity.js';
import {
	Banks,
	Confirmed,
	Deactivated,
	deactivateRoute,
	Lookup,
	PayoutAccounts,
	PayoutRoutes,
	PrimarySet,
	primaryRoute,
	type Bank,
	type PayoutAccount
} from '#lib/contract/payout.js';
import { EdgeTransport, type EdgeFailure } from './edge';

const readPolicy = {
	times: 2,
	while: isRetryableRead,
	schedule: Schedule.exponential('200 millis').pipe(Schedule.jittered)
};

export interface ProfileChanges {
	readonly displayName?: string | null;
	readonly phone?: string;
	readonly rank?: string;
}

export interface IdentityApiShape {
	readonly profile: Effect.Effect<Profile, EdgeFailure>;
	readonly photoKey: Effect.Effect<string | null, EdgeFailure>;
	readonly updateProfile: (
		changes: ProfileChanges,
		idempotencyKey: string
	) => Effect.Effect<Profile, EdgeFailure>;
	readonly setPhoto: (photoKey: string) => Effect.Effect<typeof PhotoSet.Type, EdgeFailure>;
	readonly welcome: (membershipId: string) => Effect.Effect<OnboardingWorkspace, EdgeFailure>;
	readonly verifyNin: (nin: string) => Effect.Effect<typeof NinVerified.Type, EdgeFailure>;
	readonly requestReview: (
		membershipId: string,
		input: {
			nin: string;
			givenName: string;
			middleNames: string[];
			surname: string;
			idempotencyKey: string;
		}
	) => Effect.Effect<typeof ReviewRequested.Type, EdgeFailure>;
	readonly reviews: (
		membershipId: string
	) => Effect.Effect<ReadonlyArray<PendingReview>, EdgeFailure>;
	readonly decide: (
		membershipId: string,
		reviewId: string,
		input: { decision: 'approve' | 'reject'; reason: string; idempotencyKey: string }
	) => Effect.Effect<typeof ReviewDecided.Type, EdgeFailure>;
}

export class IdentityApi extends Context.Service<IdentityApi, IdentityApiShape>()('IdentityApi') {}

export const IdentityApiLive = Layer.effect(
	IdentityApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		const fn = 'identity' as const;
		return {
			profile: edge
				.call({ fn, route: IdentityRoutes.profile }, Profile)
				.pipe(Effect.retry(readPolicy)),
			photoKey: edge.call({ fn, route: IdentityRoutes.photoKey }, PhotoKey).pipe(
				Effect.retry(readPolicy),
				Effect.map((r) => r.photoKey)
			),
			updateProfile: (changes, idempotencyKey) =>
				edge.call(
					{ fn, route: IdentityRoutes.updateProfile, body: { ...changes, idempotencyKey } },
					Profile
				),
			setPhoto: (photoKey) =>
				edge.call({ fn, route: IdentityRoutes.setPhoto, body: { photoKey } }, PhotoSet),
			welcome: (membershipId) =>
				edge
					.call({ fn, route: IdentityRoutes.welcome, membershipId }, OnboardingWorkspace)
					.pipe(Effect.retry(readPolicy)),
			verifyNin: (nin) =>
				edge.call({ fn, route: IdentityRoutes.verifyNin, body: { nin } }, NinVerified),
			requestReview: (membershipId, input) =>
				edge.call(
					{ fn, route: IdentityRoutes.requestReview, body: input, membershipId },
					ReviewRequested
				),
			reviews: (membershipId) =>
				edge
					.call({ fn, route: IdentityRoutes.reviews, membershipId }, PendingReviews)
					.pipe(Effect.retry(readPolicy)),
			decide: (membershipId, reviewId, input) =>
				edge.call({ fn, route: decideRoute(reviewId), body: input, membershipId }, ReviewDecided)
		};
	})
);

export interface PayoutApiShape {
	/** Whether the person has a wallet (members do; President Team alone does not). */
	readonly walletExists: Effect.Effect<boolean, EdgeFailure>;
	readonly banks: Effect.Effect<ReadonlyArray<Bank>, EdgeFailure>;
	readonly accounts: (
		membershipId: string
	) => Effect.Effect<ReadonlyArray<PayoutAccount>, EdgeFailure>;
	readonly lookup: (
		membershipId: string,
		input: { bankCode: string; accountNumber: string; idempotencyKey: string }
	) => Effect.Effect<typeof Lookup.Type, EdgeFailure>;
	readonly confirm: (
		membershipId: string,
		input: { lookupId: string; idempotencyKey: string }
	) => Effect.Effect<PayoutAccount, EdgeFailure>;
	readonly setPrimary: (
		membershipId: string,
		payoutAccountId: string,
		input: { idempotencyKey: string }
	) => Effect.Effect<typeof PrimarySet.Type, EdgeFailure>;
	readonly deactivate: (
		membershipId: string,
		payoutAccountId: string,
		input: { reason: string; idempotencyKey: string }
	) => Effect.Effect<typeof Deactivated.Type, EdgeFailure>;
}

export class PayoutApi extends Context.Service<PayoutApi, PayoutApiShape>()('PayoutApi') {}

export const PayoutApiLive = Layer.effect(
	PayoutApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		const fn = 'payout' as const;
		return {
			walletExists: edge
				.call({ fn: 'ledger', route: { method: 'GET', path: '/me/wallet' } }, Schema.Unknown)
				.pipe(
					Effect.retry(readPolicy),
					Effect.as(true),
					Effect.catchIf(
						(e) => e._tag === 'BackendError' && e.code === 'no_wallet',
						() => Effect.succeed(false)
					)
				),
			banks: edge.call({ fn, route: PayoutRoutes.banks }, Banks).pipe(
				Effect.retry(readPolicy),
				Effect.map((r) => r.banks)
			),
			accounts: (membershipId) =>
				edge.call({ fn, route: PayoutRoutes.accounts, membershipId }, PayoutAccounts).pipe(
					Effect.retry(readPolicy),
					Effect.map((r) => r.items)
				),
			lookup: (membershipId, input) =>
				edge.call({ fn, route: PayoutRoutes.lookup, body: input, membershipId }, Lookup),
			confirm: (membershipId, input) =>
				edge
					.call(
						{ fn, route: PayoutRoutes.confirm, body: { ...input, confirmed: true }, membershipId },
						Confirmed
					)
					.pipe(Effect.map((r) => r.payoutAccount)),
			setPrimary: (membershipId, payoutAccountId, input) =>
				edge.call(
					{ fn, route: primaryRoute(payoutAccountId), body: input, membershipId },
					PrimarySet
				),
			// Relayed as the backend shapes it ({ payoutAccount }), like setPrimary.
			deactivate: (membershipId, payoutAccountId, input) =>
				edge.call(
					{ fn, route: deactivateRoute(payoutAccountId), body: input, membershipId },
					Deactivated
				)
		};
	})
);
