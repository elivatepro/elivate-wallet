// `payout` Edge Function contract (Blueprint 05), the routes the onboarding
// bank step and payout settings use. Derived from
// backend/supabase/functions/payout/handler.ts and payout.account_json /
// lookup views. Full account numbers never appear here except the owner reveal.

import { Schema } from 'effect';
import { IsoDateTime, Uuid } from './common';

export const ACCOUNT_NUMBER_PATTERN = /^[0-9]{10}$/;

export const Bank = Schema.Struct({ code: Schema.String, name: Schema.String });
export type Bank = typeof Bank.Type;
export const Banks = Schema.Struct({
	banks: Schema.Array(Bank),
	refreshedAt: Schema.NullOr(IsoDateTime),
	stale: Schema.Boolean
});

export const NameMatch = Schema.Literals(['matched', 'mismatched', 'identity_pending']);
export type NameMatch = typeof NameMatch.Type;

export const Lookup = Schema.Struct({
	lookupId: Uuid,
	status: Schema.Literal('resolved'),
	bankCode: Schema.String,
	bankName: Schema.NullOr(Schema.String),
	accountLast4: Schema.String,
	accountName: Schema.String,
	nameMatch: NameMatch,
	expiresAt: IsoDateTime
});
export type Lookup = typeof Lookup.Type;

export const PayoutAccount = Schema.Struct({
	payoutAccountId: Uuid,
	bankCode: Schema.String,
	bankName: Schema.NullOr(Schema.String),
	accountLast4: Schema.String,
	accountNumberMasked: Schema.String,
	accountName: Schema.String,
	currency: Schema.String,
	status: Schema.Literals(['active', 'replaced', 'deactivated']),
	nameMatch: NameMatch,
	isPrimary: Schema.Boolean,
	usableFrom: Schema.NullOr(IsoDateTime),
	createdAt: IsoDateTime
});
export type PayoutAccount = typeof PayoutAccount.Type;

export const PayoutAccounts = Schema.Struct({ items: Schema.Array(PayoutAccount) });
export const Confirmed = Schema.Struct({ payoutAccount: PayoutAccount });

export const PayoutRoutes = {
	banks: { method: 'GET', path: '/banks' },
	lookup: { method: 'POST', path: '/lookups' },
	confirm: { method: 'POST', path: '/accounts' },
	accounts: { method: 'GET', path: '/accounts' }
} as const;
