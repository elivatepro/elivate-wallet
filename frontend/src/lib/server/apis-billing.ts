// BillingApi (Blueprint 16): the `billing` Edge Function. Reads retry; commands
// never do (the caller keeps its idempotency key). Payment truth comes from the
// function's server-side Paystack verification, never from a redirect.

import { Context, Effect, Layer, Schedule } from 'effect';
import { isRetryableRead } from '#lib/contract/errors.js';
import {
	BillingOverview,
	BillingRoutes,
	BillingSetup,
	CheckoutResult,
	CommandAck,
	OwnerCandidates,
	PaymentView,
	type AutoRenewCommand,
	type CheckoutCommand,
	StartNetworkRoute,
	StartedNetwork,
	type NextPlanCommand
} from '#lib/contract/billing.js';
import { EdgeTransport, type EdgeFailure } from './edge';

const readPolicy = {
	times: 2,
	while: isRetryableRead,
	schedule: Schedule.exponential('200 millis').pipe(Schedule.jittered)
};

export interface BillingApiShape {
	readonly setup: Effect.Effect<BillingSetup, EdgeFailure>;
	/** Founder setup (PL01/PL02): a new network with its plan and maybe the trial. */
	readonly startNetwork: (body: {
		readonly name: string;
		readonly shortName: string;
		readonly planKey: string;
		readonly trial: boolean;
		readonly idempotencyKey: string;
	}) => Effect.Effect<StartedNetwork, EdgeFailure>;
	readonly overview: (membershipId: string) => Effect.Effect<BillingOverview, EdgeFailure>;
	readonly checkout: (
		membershipId: string,
		body: CheckoutCommand
	) => Effect.Effect<CheckoutResult, EdgeFailure>;
	readonly payment: (
		membershipId: string,
		id: string,
		returned: boolean
	) => Effect.Effect<PaymentView, EdgeFailure>;
	readonly autoRenew: (
		membershipId: string,
		body: AutoRenewCommand
	) => Effect.Effect<CommandAck, EdgeFailure>;
	readonly nextPlan: (
		membershipId: string,
		body: NextPlanCommand
	) => Effect.Effect<CommandAck, EdgeFailure>;
	readonly ownerCandidates: (
		membershipId: string,
		q: string
	) => Effect.Effect<OwnerCandidates, EdgeFailure>;
	readonly changeOwner: (
		membershipId: string,
		body: { readonly membershipId: string; readonly idempotencyKey: string }
	) => Effect.Effect<CommandAck, EdgeFailure>;
}

export class BillingApi extends Context.Service<BillingApi, BillingApiShape>()('BillingApi') {}

export const BillingApiLive = Layer.effect(
	BillingApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		const fn = 'billing' as const;
		return {
			setup: edge
				.call({ fn, route: BillingRoutes.setup }, BillingSetup)
				.pipe(Effect.retry(readPolicy)),
			startNetwork: (body) =>
				edge.call({ fn: 'org', route: StartNetworkRoute, body }, StartedNetwork),
			overview: (membershipId) =>
				edge
					.call({ fn, route: BillingRoutes.overview, membershipId }, BillingOverview)
					.pipe(Effect.retry(readPolicy)),
			checkout: (membershipId, body) =>
				edge.call({ fn, route: BillingRoutes.checkout, membershipId, body }, CheckoutResult),
			payment: (membershipId, id, returned) =>
				edge
					.call(
						{
							fn,
							route: BillingRoutes.payment(id),
							membershipId,
							query: returned ? { returned: '1' } : {}
						},
						PaymentView
					)
					.pipe(Effect.retry(readPolicy)),
			autoRenew: (membershipId, body) =>
				edge.call({ fn, route: BillingRoutes.autoRenew, membershipId, body }, CommandAck),
			nextPlan: (membershipId, body) =>
				edge.call({ fn, route: BillingRoutes.nextPlan, membershipId, body }, CommandAck),
			ownerCandidates: (membershipId, q) =>
				edge
					.call(
						{ fn, route: BillingRoutes.ownerCandidates, membershipId, query: q ? { q } : {} },
						OwnerCandidates
					)
					.pipe(Effect.retry(readPolicy)),
			changeOwner: (membershipId, body) =>
				edge.call({ fn, route: BillingRoutes.owner, membershipId, body }, CommandAck)
		};
	})
);
