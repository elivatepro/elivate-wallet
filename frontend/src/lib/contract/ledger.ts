// `ledger` Edge Function contract (Blueprint 04), the reads Home and the
// split editor use. Money is a decimal string with the currency's exact scale
// (ledger.money); it is never turned into a float.

import { Schema } from 'effect';
import { IsoDateTime, TenantStatus, Uuid } from './common';

export const MONEY_PATTERN = /^-?[0-9]+(\.[0-9]+)?$/;
export const Money = Schema.String.check(Schema.isPattern(MONEY_PATTERN));
export const Currency = Schema.Literals(['NGN', 'USD']);
export type Currency = typeof Currency.Type;

export const Pocket = Schema.Struct({
	pocketId: Uuid,
	name: Schema.String,
	kind: Schema.Literals(['ordinary', 'debt']),
	status: Schema.String
});
export type Pocket = typeof Pocket.Type;

export const PocketBalance = Schema.Struct({
	pocketId: Uuid,
	posted: Money,
	reserved: Money,
	available: Money
});

export const CurrencyBalance = Schema.Struct({
	currency: Currency,
	posted: Money,
	reserved: Money,
	available: Money,
	pockets: Schema.NullOr(Schema.Array(PocketBalance))
});
export type CurrencyBalance = typeof CurrencyBalance.Type;

export const WalletNetwork = Schema.Struct({
	tenantId: Uuid,
	name: Schema.String,
	status: TenantStatus,
	activeMember: Schema.Boolean,
	pockets: Schema.Array(Pocket),
	currencies: Schema.Array(CurrencyBalance)
});
export type WalletNetwork = typeof WalletNetwork.Type;

export const Wallet = Schema.Struct({ walletId: Uuid, networks: Schema.Array(WalletNetwork) });

export const ActivityItem = Schema.Struct({
	transactionId: Uuid,
	reference: Schema.String,
	type: Schema.String,
	postedAt: IsoDateTime,
	tenantId: Uuid,
	currency: Currency,
	amount: Money
});
export type ActivityItem = typeof ActivityItem.Type;
export const Activity = Schema.Struct({
	items: Schema.Array(ActivityItem),
	nextCursor: Schema.NullOr(Schema.String)
});

export const SplitLine = Schema.Struct({
	pocketId: Uuid,
	name: Schema.String,
	basisPoints: Schema.Int,
	percent: Schema.String
});
export type SplitLine = typeof SplitLine.Type;

export const Allocation = Schema.Struct({
	policyId: Uuid,
	version: Schema.Int,
	createdAt: IsoDateTime,
	pockets: Schema.Array(SplitLine),
	debt: Schema.NullOr(Schema.Struct({ pocketId: Uuid, name: Schema.String }))
});
export type Allocation = typeof Allocation.Type;

export const AllocationVersion = Schema.Struct({
	policyId: Uuid,
	version: Schema.Int,
	source: Schema.String,
	createdAt: IsoDateTime,
	pockets: Schema.Array(SplitLine),
	reason: Schema.NullOr(Schema.String)
});
export type AllocationVersion = typeof AllocationVersion.Type;
export const AllocationVersions = Schema.Struct({ items: Schema.Array(AllocationVersion) });

export const LedgerRoutes = {
	versions: { method: 'GET', path: '/allocation/versions' },
	wallet: { method: 'GET', path: '/me/wallet' },
	activity: { method: 'GET', path: '/me/activity' },
	allocation: { method: 'GET', path: '/allocation' },
	setAllocation: { method: 'PUT', path: '/allocation' }
} as const;
