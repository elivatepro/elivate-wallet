// Statements and reports (Blueprint 15, W-18): the `ledger` routes the app
// uses, and the `exports-worker` steps the export runner drives. Money is an
// exact decimal string with its currency; it is never turned into a float.

import { Schema } from 'effect';
import { IsoDateTime, Person, Role, Uuid } from './common';
import { Currency, Money } from './ledger';

export const ExportKind = Schema.Literals([
	'statement_pdf',
	'statement_csv',
	'office_pdf',
	'transactions_csv',
	'member_balances_csv'
]);
export type ExportKind = typeof ExportKind.Type;

export const ReportKind = Schema.Literals([
	'office_pdf',
	'transactions_csv',
	'member_balances_csv'
]);
export type ReportKind = typeof ReportKind.Type;

/** `expired` is a ready file past its 7 days (derived by the backend). */
export const ExportStatus = Schema.Literals([
	'queued',
	'preparing',
	'rendering',
	'ready',
	'failed',
	'too_large',
	'expired'
]);
export type ExportStatus = typeof ExportStatus.Type;

export const PeriodKind = Schema.Literals(['month', 'quarter', 'year', 'year_to_date', 'custom']);
export type PeriodKind = typeof PeriodKind.Type;

const IsoDate = Schema.String.check(Schema.isPattern(/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/));

export const ExportPeriod = Schema.Struct({
	kind: PeriodKind,
	from: IsoDate,
	to: IsoDate,
	title: Schema.String,
	asOf: IsoDateTime,
	timeZone: Schema.String
});

export const ExportFile = Schema.Struct({
	exportId: Uuid,
	reference: Schema.String,
	kind: ExportKind,
	format: Schema.Literals(['pdf', 'csv']),
	tenantId: Uuid,
	currency: Currency,
	period: ExportPeriod,
	scope: Schema.NullOr(
		Schema.Struct({
			officeId: Schema.NullOr(Uuid),
			member: Schema.NullOr(Person),
			/** One-member reports: the member's wallet, for Recreate. */
			memberWalletId: Schema.optionalKey(Schema.NullOr(Uuid))
		})
	),
	status: ExportStatus,
	rowCount: Schema.NullOr(Schema.Int),
	pageCount: Schema.NullOr(Schema.Int),
	byteSize: Schema.NullOr(Schema.Number),
	hasPreview: Schema.Boolean,
	failReason: Schema.NullOr(Schema.String),
	background: Schema.Boolean,
	createdAt: IsoDateTime,
	readyAt: Schema.NullOr(IsoDateTime),
	expiresAt: Schema.NullOr(IsoDateTime)
});
export type ExportFile = typeof ExportFile.Type;

export const ExportPage = Schema.Struct({
	items: Schema.Array(ExportFile),
	nextCursor: Schema.NullOr(Schema.String)
});
export type ExportPage = typeof ExportPage.Type;

export const StatementNetwork = Schema.Struct({
	tenantId: Uuid,
	name: Schema.String,
	initial: Schema.String,
	currencies: Schema.Array(Currency)
});
export type StatementNetwork = typeof StatementNetwork.Type;

export const StatementOptions = Schema.Struct({
	networks: Schema.Array(StatementNetwork),
	today: IsoDate,
	timeZone: Schema.String,
	limits: Schema.Struct({ pdf: Schema.Int, csv: Schema.Int })
});
export type StatementOptions = typeof StatementOptions.Type;

// ── Report figures (Reports page and the office report) ──

export const HeldLine = Schema.Struct({
	kind: Schema.String,
	count: Schema.Int,
	amount: Money
});
export type HeldLine = typeof HeldLine.Type;

export const WithdrawalStage = Schema.Struct({
	stage: Schema.Literals(['requested', 'approved', 'completed', 'rejected', 'cancelled']),
	count: Schema.Int,
	amount: Money
});
export type WithdrawalStage = typeof WithdrawalStage.Type;

export const MemberFigure = Schema.Struct({
	member: Person,
	offices: Schema.Array(Schema.String),
	opening: Money,
	income: Money,
	paidOut: Money,
	in: Money,
	out: Money,
	closing: Money,
	reserved: Money,
	available: Money
});
export type MemberFigure = typeof MemberFigure.Type;

const ReportTotals = {
	opening: Money,
	closing: Money,
	held: Schema.Array(HeldLine),
	reserved: Money,
	reservedCount: Schema.Int,
	available: Money,
	netIncomeByPocket: Schema.Array(Schema.Struct({ pocket: Schema.String, amount: Money })),
	netIncome: Money,
	withdrawals: Schema.Array(WithdrawalStage),
	counts: Schema.Struct({
		activeMemberships: Schema.Int,
		people: Schema.Int,
		joined: Schema.Int
	}),
	excludedPeople: Schema.Int
};

export const ReportOverview = Schema.Struct({
	...ReportTotals,
	scope: Schema.Struct({ kind: Schema.Literals(['network', 'office']), name: Schema.String }),
	currency: Currency,
	period: Schema.Struct({
		kind: PeriodKind,
		from: IsoDate,
		to: IsoDate,
		title: Schema.String,
		asOf: IsoDateTime,
		current: Schema.Boolean,
		timeZone: Schema.String
	}),
	members: Schema.Struct({
		top: Schema.Array(MemberFigure),
		rest: Schema.Struct({ count: Schema.Int, income: Money, paidOut: Money, reserved: Money })
	}),
	canExport: Schema.Boolean,
	currencies: Schema.Array(Currency)
});
export type ReportOverview = typeof ReportOverview.Type;

// ── File contents (prepared by Postgres, rendered by the export runner) ──

const SummaryPeriod = Schema.Struct({
	kind: PeriodKind,
	from: IsoDate,
	to: IsoDate,
	title: Schema.String,
	asOf: IsoDateTime,
	cutShort: Schema.Boolean,
	timeZone: Schema.String
});

const SummaryNetwork = Schema.Struct({
	tenantId: Uuid,
	name: Schema.String,
	initial: Schema.String,
	// Blueprint 17: the team theme, whether a logo exists and the support contact.
	theme: Schema.optional(Schema.String),
	hasLogo: Schema.optional(Schema.Boolean),
	support: Schema.optional(
		Schema.NullOr(
			Schema.Struct({
				name: Schema.NullOr(Schema.String),
				email: Schema.NullOr(Schema.String),
				phone: Schema.NullOr(Schema.String),
				helpUrl: Schema.NullOr(Schema.String)
			})
		)
	)
});

export const PendingItem = Schema.Struct({
	kind: Schema.Literals(['withdrawal', 'pocket_transfer', 'conversion']),
	reference: Schema.NullOr(Schema.String),
	status: Schema.Literals(['requested', 'approved', 'needs_review']),
	pocket: Schema.String,
	date: IsoDate,
	amount: Money
});
export type PendingItem = typeof PendingItem.Type;

export const StatementSummary = Schema.Struct({
	type: Schema.Literal('statement'),
	network: SummaryNetwork,
	person: Person,
	memberships: Schema.Array(
		Schema.Struct({ office: Schema.String, role: Role, status: Schema.String })
	),
	currency: Currency,
	period: SummaryPeriod,
	opening: Money,
	moneyIn: Money,
	moneyOut: Money,
	closing: Money,
	inCount: Schema.Int,
	outTypes: Schema.Record(Schema.String, Schema.Int),
	pockets: Schema.Array(
		Schema.Struct({
			pocket: Schema.String,
			kind: Schema.String,
			opening: Money,
			in: Money,
			out: Money,
			closing: Money
		})
	),
	pending: Schema.Array(PendingItem),
	reserved: Money,
	available: Money,
	generatedAt: IsoDateTime,
	reference: Schema.String
});
export type StatementSummary = typeof StatementSummary.Type;

export const ReportSummary = Schema.Struct({
	...ReportTotals,
	type: Schema.Literal('report'),
	network: SummaryNetwork,
	scope: Schema.Struct({
		kind: Schema.Literals(['network', 'office']),
		name: Schema.String,
		member: Schema.optionalKey(Schema.NullOr(Person))
	}),
	preparedFor: Schema.Struct({
		uid: Schema.String,
		name: Schema.NullOr(Schema.String),
		role: Schema.NullOr(Role)
	}),
	currency: Currency,
	period: SummaryPeriod,
	members: Schema.Int,
	generatedAt: IsoDateTime,
	reference: Schema.String
});
export type ReportSummary = typeof ReportSummary.Type;

/** One posted movement (statement and transactions CSV rows). */
export const TxnRow = Schema.Struct({
	transactionId: Uuid,
	reference: Schema.String,
	type: Schema.String,
	postedAt: IsoDateTime,
	date: IsoDate,
	time: Schema.String,
	office: Schema.String,
	member: Schema.optionalKey(Person),
	amount: Money,
	balance: Schema.optionalKey(Money),
	status: Schema.Literals(['posted', 'reversed']),
	reversedBy: Schema.optionalKey(Schema.String),
	reverses: Schema.optionalKey(Schema.String),
	reversalCategory: Schema.optionalKey(Schema.String),
	pockets: Schema.Array(Schema.Struct({ pocket: Schema.String, amount: Money })),
	income: Schema.optionalKey(Schema.Struct({ source: Schema.String })),
	transfer: Schema.optionalKey(
		Schema.Struct({ from: Schema.String, to: Schema.String, amount: Money })
	),
	conversion: Schema.optionalKey(
		Schema.Struct({
			currency: Currency,
			amount: Money,
			destinationCurrency: Currency,
			destinationAmount: Money
		})
	),
	adjustment: Schema.optionalKey(
		Schema.Struct({ direction: Schema.Literals(['credit', 'debit']) })
	),
	returnedFor: Schema.optionalKey(Schema.String)
});
export type TxnRow = typeof TxnRow.Type;

export const ClaimedJob = Schema.Struct({
	exportId: Uuid,
	reference: Schema.String,
	kind: ExportKind,
	format: Schema.Literals(['pdf', 'csv']),
	objectKey: Schema.String.check(
		Schema.isPattern(/^exports\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9]{1,3}\.(pdf|csv)$/)
	),
	fileName: Schema.String,
	attempt: Schema.Int
});
export type ClaimedJob = typeof ClaimedJob.Type;

export const ClaimResult = Schema.Struct({ job: Schema.NullOr(ClaimedJob) });

export const PrepareResult = Schema.Struct({
	status: Schema.Literals(['rendering', 'too_large', 'failed']),
	rowCount: Schema.optionalKey(Schema.Int),
	summary: Schema.optionalKey(Schema.Unknown),
	background: Schema.optionalKey(Schema.Boolean),
	failReason: Schema.optionalKey(Schema.String),
	limit: Schema.optionalKey(Schema.Int)
});
export type PrepareResult = typeof PrepareResult.Type;

export const RowsPage = Schema.Struct({
	rows: Schema.Array(
		Schema.Struct({
			seq: Schema.Int,
			section: Schema.Literals(['txn', 'member']),
			data: Schema.Unknown
		})
	),
	rowCount: Schema.Int
});
export type RowsPage = typeof RowsPage.Type;

export const StepResult = Schema.Struct({
	status: Schema.String,
	failReason: Schema.optionalKey(Schema.String)
});

/** For the app server only: where the file is and how to send it. */
export const DownloadTarget = Schema.Struct({
	objectKey: Schema.String.check(
		Schema.isPattern(/^exports\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[0-9]{1,3}\.(pdf|csv)(\.png)?$/)
	),
	fileName: Schema.String.check(Schema.isPattern(/^[A-Za-z0-9._-]{1,200}$/)),
	contentType: Schema.Literals(['application/pdf', 'text/csv; charset=utf-8', 'image/png']),
	byteSize: Schema.NullOr(Schema.Number),
	sha256: Schema.NullOr(Schema.String)
});
export type DownloadTarget = typeof DownloadTarget.Type;

// ── Same-origin request bodies ──

const Key = Schema.String.check(Schema.isPattern(/^[A-Za-z0-9_-]{16,100}$/));

export const StatementCommand = Schema.Struct({
	tenantId: Schema.optionalKey(Schema.NullOr(Uuid)),
	currency: Currency,
	periodKind: PeriodKind,
	from: IsoDate,
	to: IsoDate,
	format: Schema.Literals(['pdf', 'csv']),
	idempotencyKey: Key
});
export type StatementCommand = typeof StatementCommand.Type;

export const ReportCommand = Schema.Struct({
	kind: ReportKind,
	/** One member, picked from Member wallets. */
	memberWalletId: Schema.optionalKey(Schema.NullOr(Uuid)),
	currency: Currency,
	periodKind: PeriodKind,
	from: IsoDate,
	to: IsoDate,
	idempotencyKey: Key
});
export type ReportCommand = typeof ReportCommand.Type;

export const UnlockCommand = Schema.Struct({
	pin: Schema.String.check(Schema.isPattern(/^[0-9]{4}$/))
});

export const ExportRoutes = {
	options: { method: 'GET', path: '/statements/options' },
	statements: { method: 'GET', path: '/statements' },
	createStatement: { method: 'POST', path: '/statements' },
	overview: { method: 'GET', path: '/reports/overview' },
	reports: { method: 'GET', path: '/reports' },
	members: { method: 'GET', path: '/reports/members' },
	createReport: { method: 'POST', path: '/reports' },
	file: (id: string) => ({ method: 'GET', path: `/exports/${id}` }) as const,
	retry: (id: string) => ({ method: 'POST', path: `/exports/${id}/retry` }) as const,
	download: (id: string) => ({ method: 'POST', path: `/exports/${id}/download` }) as const
} as const;

/** GET /api/statements: the builder's choices and the person's files. */
export const StatementsView = Schema.Struct({ options: StatementOptions, files: ExportPage });
export type StatementsView = typeof StatementsView.Type;

/** "One member" picker: people the actor may export (export_scoped_reports). */
export const ReportMembers = Schema.Struct({
	items: Schema.Array(Schema.Struct({ walletId: Uuid, person: Person }))
});
export type ReportMembers = typeof ReportMembers.Type;
