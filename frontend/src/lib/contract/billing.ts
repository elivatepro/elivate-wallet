// Billing (Blueprint 16, W-19): the `billing` Edge Function routes. Prices and
// amounts are exact decimal strings in NGN; nothing here is turned into a
// float. Paystack's own reference never reaches the browser.

import { Schema } from 'effect';
import { IDEMPOTENCY_KEY_PATTERN, IsoDateTime, Role, TenantStatus, Uid, Uuid } from './common';
import { Money } from './ledger';

export const PlanKey = Schema.Literals(['band_400', 'band_1000', 'band_1001_plus']);
export type PlanKey = typeof PlanKey.Type;

export const Plan = Schema.Struct({
	key: PlanKey,
	name: Schema.String,
	seatCap: Schema.NullOr(Schema.Int),
	price: Money,
	currency: Schema.Literal('NGN')
});
export type Plan = typeof Plan.Type;

export const PlanOffer = Schema.Struct({
	...Plan.fields,
	action: Schema.NullOr(Schema.Literals(['current', 'upgrade', 'choose'])),
	amount: Schema.NullOr(Money),
	daysLeft: Schema.NullOr(Schema.Int),
	fits: Schema.Boolean
});
export type PlanOffer = typeof PlanOffer.Type;

export const PaymentStatus = Schema.Literals(['open', 'paid', 'failed', 'abandoned', 'superseded']);
export type PaymentStatus = typeof PaymentStatus.Type;

export const Payment = Schema.Struct({
	id: Uuid,
	reference: Schema.String,
	purpose: Schema.Literals(['start', 'renew', 'upgrade', 'reactivate', 'auto_renewal']),
	status: PaymentStatus,
	amount: Money,
	currency: Schema.Literal('NGN'),
	plan: Plan,
	fromPlan: Schema.NullOr(Plan),
	coversFrom: Schema.NullOr(IsoDateTime),
	coversTo: Schema.NullOr(IsoDateTime),
	paidAt: Schema.NullOr(IsoDateTime),
	createdAt: IsoDateTime,
	applied: Schema.Boolean,
	needsReview: Schema.Boolean,
	authorizationUrl: Schema.NullOr(Schema.String),
	network: Schema.optional(Schema.String)
});
export type Payment = typeof Payment.Type;

export const BillingOwner = Schema.NullOr(
	Schema.Struct({
		uid: Uid,
		name: Schema.NullOr(Schema.String),
		membershipId: Schema.NullOr(Uuid),
		since: IsoDateTime,
		role: Schema.NullOr(Role)
	})
);

export const SubscriptionStatus = Schema.Literals(['pending', 'trial', 'active', 'paused']);
export type SubscriptionStatus = typeof SubscriptionStatus.Type;

export const BillingOverview = Schema.Struct({
	network: Schema.String,
	status: SubscriptionStatus,
	kind: Schema.Literals(['trial', 'paid', 'complimentary', 'development']),
	plan: Plan,
	nextPlan: Schema.NullOr(Plan),
	planChangeAt: Schema.NullOr(IsoDateTime),
	periodStart: Schema.NullOr(IsoDateTime),
	periodEnd: Schema.NullOr(IsoDateTime),
	/** The last paid (or free) day, WAT. */
	lastDay: Schema.NullOr(Schema.String),
	daysLeft: Schema.NullOr(Schema.Int),
	pausedAt: Schema.NullOr(IsoDateTime),
	seats: Schema.Struct({ used: Schema.Int, cap: Schema.NullOr(Schema.Int) }),
	autoRenew: Schema.Boolean,
	renewsAutomatically: Schema.Boolean,
	cardOnFile: Schema.Boolean,
	owner: BillingOwner,
	canManage: Schema.Boolean,
	plans: Schema.Array(PlanOffer),
	payments: Schema.Array(Payment)
});
export type BillingOverview = typeof BillingOverview.Type;

export const BillingSetup = Schema.Struct({
	trialAvailable: Schema.Boolean,
	trialDays: Schema.Int,
	plans: Schema.Array(Plan),
	pending: Schema.Array(
		Schema.Struct({ tenantId: Uuid, name: Schema.String, membershipId: Uuid, plan: Plan })
	)
});
export type BillingSetup = typeof BillingSetup.Type;

export const PaymentView = Schema.Struct({
	payment: Payment,
	tenantStatus: Schema.optional(TenantStatus)
});
export type PaymentView = typeof PaymentView.Type;

export const CheckoutResult = Schema.Struct({
	paymentId: Schema.NullOr(Uuid),
	applied: Schema.Boolean,
	reference: Schema.NullOr(Schema.String),
	amount: Schema.NullOr(Money),
	currency: Schema.NullOr(Schema.String),
	status: Schema.NullOr(Schema.String),
	authorizationUrl: Schema.NullOr(Schema.String)
});
export type CheckoutResult = typeof CheckoutResult.Type;

export const OwnerCandidate = Schema.Struct({
	uid: Uid,
	name: Schema.NullOr(Schema.String),
	membershipId: Uuid,
	role: Role,
	office: Schema.NullOr(Schema.String),
	current: Schema.Boolean
});
export type OwnerCandidate = typeof OwnerCandidate.Type;
export const OwnerCandidates = Schema.Struct({ candidates: Schema.Array(OwnerCandidate) });
export type OwnerCandidates = typeof OwnerCandidates.Type;

const IdempotencyKey = Schema.String.check(Schema.isPattern(IDEMPOTENCY_KEY_PATTERN));
const PinField = Schema.String.check(Schema.isPattern(/^[0-9]{4}$/));

export const CheckoutCommand = Schema.Struct({
	planKey: PlanKey,
	kind: Schema.Literals(['year', 'upgrade']),
	idempotencyKey: IdempotencyKey
});
export type CheckoutCommand = typeof CheckoutCommand.Type;

export const AutoRenewCommand = Schema.Struct({
	enabled: Schema.Boolean,
	idempotencyKey: IdempotencyKey
});
export type AutoRenewCommand = typeof AutoRenewCommand.Type;

export const NextPlanCommand = Schema.Struct({
	planKey: Schema.NullOr(PlanKey),
	idempotencyKey: IdempotencyKey
});
export type NextPlanCommand = typeof NextPlanCommand.Type;

/** The PIN opens the step-up in the app server; only the rest reaches the Edge. */
export const OwnerCommand = Schema.Struct({
	membershipId: Uuid,
	pin: PinField,
	idempotencyKey: IdempotencyKey
});
export type OwnerCommand = typeof OwnerCommand.Type;

export const BillingRoutes = {
	setup: { method: 'GET', path: '/setup' },
	overview: { method: 'GET', path: '/overview' },
	checkout: { method: 'POST', path: '/checkout' },
	payment: (id: string) => ({ method: 'GET', path: `/payments/${id}` }) as const,
	autoRenew: { method: 'POST', path: '/auto-renew' },
	nextPlan: { method: 'POST', path: '/next-plan' },
	ownerCandidates: { method: 'GET', path: '/owner-candidates' },
	owner: { method: 'POST', path: '/owner' }
} as const;

export const StartedNetwork = Schema.Struct({
	tenantId: Uuid,
	status: TenantStatus,
	membershipId: Uuid,
	trial: Schema.optional(Schema.Boolean)
});
export type StartedNetwork = typeof StartedNetwork.Type;

/** POST /org/networks (Blueprint 16: with the plan and the founder's trial). */
export const StartNetworkRoute = { method: 'POST', path: '/networks' } as const;

export const CommandAck = Schema.Record(Schema.String, Schema.Unknown);
export type CommandAck = typeof CommandAck.Type;
