// `ledger` Edge Function contract (Blueprint 04), the reads Home and the
// split editor use. Money is a decimal string with the currency's exact scale
// (ledger.money); it is never turned into a float.

import { Schema } from 'effect';
import { IsoDateTime, Person, Role, TenantStatus, Uuid } from './common';

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
	/** Durable status of the movement (Blueprint 08); `posted` until reversals land. */
	status: Schema.String,
	/** Income source; null for other movements. */
	title: Schema.NullOr(Schema.String),
	postedAt: IsoDateTime,
	tenantId: Uuid,
	currency: Currency,
	amount: Money,
	pocketCount: Schema.Int,
	/** Pocket moves net to zero: the amount moved between pockets (Blueprint 11). */
	movedAmount: Schema.optionalKey(Schema.NullOr(Money)),
	/** When a reversal points at this movement (owner decision 2026-10-08, Q03). */
	reversedAt: Schema.optionalKey(Schema.NullOr(IsoDateTime))
});
export type ActivityItem = typeof ActivityItem.Type;

/**
 * Blueprint 44 (D1): one of the person's own open withdrawals (requested or
 * approved), shown above the posted rows. The amount is on hold, never
 * signed; it never counts in the month totals. Opens the withdrawal itself.
 */
export const PendingWithdrawal = Schema.Struct({
	withdrawalId: Uuid,
	reference: Schema.String,
	status: Schema.Literals(['requested', 'approved']),
	currency: Currency,
	amount: Money,
	/** "<Bank> •• last4" */
	title: Schema.String,
	pocket: Schema.Struct({ pocketId: Uuid, name: Schema.String }),
	tenantId: Uuid,
	createdAt: IsoDateTime,
	approvedAt: Schema.NullOr(IsoDateTime)
});
export type PendingWithdrawal = typeof PendingWithdrawal.Type;

/** Money in / out of one month and currency, from the whole filtered set (never one page). */
export const ActivityMonth = Schema.Struct({
	month: Schema.String.check(Schema.isPattern(/^[0-9]{4}-[0-9]{2}$/)),
	currencies: Schema.Array(Schema.Struct({ currency: Currency, in: Money, out: Money }))
});
export type ActivityMonth = typeof ActivityMonth.Type;

export const Activity = Schema.Struct({
	items: Schema.Array(ActivityItem),
	nextCursor: Schema.NullOr(Schema.String),
	months: Schema.Array(ActivityMonth),
	/** Size of the whole filtered set (mobile sheet "Show N results"). */
	total: Schema.optionalKey(Schema.Int),
	timeZone: Schema.String,
	/** Blueprint 44: own open withdrawals, first page of your own activity only. */
	pending: Schema.optionalKey(Schema.Array(PendingWithdrawal))
});
export type Activity = typeof Activity.Type;

/** Query of the activity reads (Blueprint 08 B4.2). Dates are YYYY-MM-DD in `tz`. */
export type ActivityQuery = {
	readonly tenantId?: string;
	readonly q?: string;
	readonly direction?: 'in' | 'out';
	readonly currency?: Currency;
	readonly status?: string;
	readonly type?: string;
	readonly pocketId?: string;
	readonly from?: string;
	readonly to?: string;
	readonly tz?: string;
	readonly cursor?: string;
	readonly limit?: number;
};

const TransactionLink = Schema.Struct({
	transactionId: Uuid,
	reference: Schema.String,
	postedAt: IsoDateTime
});

const PocketLine = Schema.Struct({ pocketId: Uuid, pocket: Schema.String, amount: Money });

/** One transaction as its owner (or a leader, visible segments only) sees it. */
export const TransactionDetail = Schema.Struct({
	transactionId: Uuid,
	reference: Schema.String,
	type: Schema.String,
	status: Schema.String,
	postedAt: IsoDateTime,
	recordedBy: Person,
	/** Q03: the reversal of this transaction, or what a reversal reverses. */
	reversedBy: Schema.optionalKey(Schema.NullOr(TransactionLink)),
	reverses: Schema.optionalKey(Schema.NullOr(TransactionLink)),
	tenant: Schema.Struct({ id: Uuid, name: Schema.String }),
	office: Schema.Struct({ id: Uuid, name: Schema.String }),
	journals: Schema.Array(
		Schema.Struct({ currency: Currency, lines: Schema.NullOr(Schema.Array(PocketLine)) })
	),
	income: Schema.NullOr(
		Schema.Struct({
			incomeId: Uuid,
			source: Schema.String,
			receivedOn: Schema.String,
			providerReference: Schema.NullOr(Schema.String),
			notes: Schema.NullOr(Schema.String),
			currency: Currency,
			amount: Money,
			fee: Schema.NullOr(Schema.Struct({ amount: Money, currency: Currency })),
			allocations: Schema.Array(
				Schema.Struct({
					pocketId: Uuid,
					pocket: Schema.String,
					basisPoints: Schema.Int,
					amount: Money
				})
			)
		})
	),
	/** Blueprint 40: what a withdrawal was for (null before it was asked). */
	withdrawal: Schema.optionalKey(
		Schema.NullOr(
			Schema.Struct({
				withdrawalId: Uuid,
				reason: Schema.optionalKey(Schema.NullOr(Schema.String))
			})
		)
	),
	/** Blueprint 12: the conversion / adjustment / returned-funds facts. */
	entry: Schema.optionalKey(
		Schema.NullOr(
			Schema.Struct({
				kind: Schema.Literals(['conversion', 'adjustment', 'returned_funds']),
				direction: Schema.Literals(['credit', 'debit']),
				currency: Currency,
				amount: Money,
				conversion: Schema.NullOr(
					Schema.Struct({
						destinationCurrency: Currency,
						destinationAmount: Money,
						rateBase: Currency,
						rateQuote: Currency,
						effectiveRate: Schema.String,
						quotedRate: Schema.NullOr(Schema.String)
					})
				),
				provider: Schema.NullOr(Schema.String),
				externalReference: Schema.NullOr(Schema.String),
				reason: Schema.NullOr(Schema.String),
				withdrawal: Schema.NullOr(Schema.Struct({ withdrawalId: Uuid, reference: Schema.String })),
				reviewedBy: Person
			})
		)
	),
	reversal: Schema.optionalKey(
		Schema.NullOr(
			Schema.Struct({
				category: Schema.String,
				reversedBy: Person
			})
		)
	)
});
export type TransactionDetail = typeof TransactionDetail.Type;

/**
 * Unknown-outcome lookup (F-03, Blueprint 08 B4.1): the fate of the person's
 * own attempt. Never the protected result itself; a same-key replay of the
 * command returns that under current authority.
 */
export const CommandOutcome = Schema.Union([
	Schema.Struct({
		status: Schema.Literal('committed'),
		command: Schema.String,
		committedAt: IsoDateTime,
		reference: Schema.NullOr(Schema.String)
	}),
	Schema.Struct({
		status: Schema.Literal('cancelled'),
		command: Schema.String,
		cancelledAt: IsoDateTime
	}),
	Schema.Struct({ status: Schema.Literal('not_found'), command: Schema.NullOr(Schema.String) })
]);
export type CommandOutcome = typeof CommandOutcome.Type;

const CurrencyTotals = Schema.Struct({
	currency: Currency,
	posted: Money,
	reserved: Money,
	available: Money
});

/** Leadership dashboard (Blueprint 08 B4.3, Paper T01/T04). */
export const LeadershipOverview = Schema.Struct({
	scope: Schema.Struct({
		kind: Schema.Literals(['office', 'network']),
		officeId: Schema.NullOr(Uuid),
		name: Schema.String
	}),
	period: Schema.Struct({
		month: Schema.String,
		previousMonth: Schema.String,
		timeZone: Schema.String
	}),
	currencies: Schema.Array(
		Schema.Struct({
			currency: Currency,
			incomeThisMonth: Money,
			incomePreviousMonth: Money,
			posted: Money,
			reserved: Money,
			available: Money,
			weeks: Schema.Array(Schema.Struct({ start: Schema.String, income: Money }))
		})
	),
	members: Schema.Struct({
		active: Schema.Int,
		activeMemberships: Schema.Int,
		pendingInvitations: Schema.NullOr(Schema.Int)
	}),
	excluded: Schema.Struct({ offices: Schema.Int, members: Schema.Int })
});
export type LeadershipOverview = typeof LeadershipOverview.Type;

/**
 * Blueprint 25: "Offices this month" on the network home (Paper NV01/NV03).
 * One row per office of the scope, counting its own members and the income
 * recorded on its own segments this month (the network's time zone), one
 * figure per currency and never a cross-currency total. Scope the viewer may
 * not see is left out and counted in `excludedMembers` / `excluded`.
 */
export const LeadershipOffices = Schema.Struct({
	scope: Schema.Struct({
		kind: Schema.Literals(['office', 'network']),
		officeId: Schema.NullOr(Uuid),
		name: Schema.String
	}),
	period: Schema.Struct({ month: Schema.String, timeZone: Schema.String }),
	currencies: Schema.Array(Currency),
	offices: Schema.Array(
		Schema.Struct({
			officeId: Uuid,
			name: Schema.String,
			kind: Schema.Literals(['world_team', 'director', 'team_leader']),
			parentOfficeId: Schema.NullOr(Uuid),
			status: Schema.String,
			members: Schema.Int,
			income: Schema.Array(Schema.Struct({ currency: Currency, amount: Money })),
			excludedMembers: Schema.Int
		})
	),
	excluded: Schema.Struct({ offices: Schema.Int, members: Schema.Int })
});
export type LeadershipOffices = typeof LeadershipOffices.Type;

/** GET /ledger/wallets (Blueprint 04): owners with at least one visible segment. */
export const ManagedWalletPage = Schema.Struct({
	items: Schema.Array(
		Schema.Struct({
			walletId: Uuid,
			person: Person,
			/** The person's membership state in this network (Q04). */
			status: Schema.optionalKey(Schema.NullOr(Schema.String)),
			currencies: Schema.Array(CurrencyTotals)
		})
	),
	nextCursor: Schema.NullOr(Schema.String),
	people: Schema.optionalKey(Schema.Int),
	scope: Schema.optionalKey(
		Schema.Struct({ kind: Schema.Literals(['office', 'network']), name: Schema.String })
	)
});
export type ManagedWalletPage = typeof ManagedWalletPage.Type;

export const ManagedWallet = Schema.Struct({
	walletId: Uuid,
	person: Person,
	memberships: Schema.optionalKey(
		Schema.Array(
			Schema.Struct({
				/** Blueprint 12: opens Convert / Adjust for this membership. */
				membershipId: Schema.optionalKey(Uuid),
				role: Role,
				officeName: Schema.String,
				status: Schema.String
			})
		)
	),
	networks: Schema.Array(WalletNetwork)
});
export type ManagedWallet = typeof ManagedWallet.Type;

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
	transaction: (id: string) => ({ method: 'GET', path: `/me/transactions/${id}` }) as const,
	commandOutcome: { method: 'GET', path: '/me/command-outcome' },
	overview: { method: 'GET', path: '/overview' },
	// Blueprint 25: per-office members and income this month (X-Membership).
	overviewOffices: { method: 'GET', path: '/overview/offices' },
	managedWallets: { method: 'GET', path: '/wallets' },
	managedWallet: (walletId: string) => ({ method: 'GET', path: `/wallets/${walletId}` }) as const,
	managedActivity: (walletId: string) =>
		({ method: 'GET', path: `/wallets/${walletId}/activity` }) as const,
	managedTransaction: (walletId: string, id: string) =>
		({ method: 'GET', path: `/wallets/${walletId}/transactions/${id}` }) as const,
	allocation: { method: 'GET', path: '/allocation' },
	setAllocation: { method: 'PUT', path: '/allocation' },
	// Blueprint 20: Home in one read (X-Membership), decoded as app HomeView.
	home: { method: 'GET', path: '/home' }
} as const;
