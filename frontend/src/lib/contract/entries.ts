// Conversions, adjustments, returned funds and reversals (Blueprint 12).
// Wire schemas for the `ledger` Edge routes (finance.entry_json,
// entry_case_json, returnable_json, reversal_json) and the app server's own
// endpoints. Money and rates are decimal strings, never floats. Responses may
// carry extra fields; request bodies must not.

import { Schema } from 'effect';
import { IsoDateTime, Person, Role, Uuid } from './common';
import { IdempotencyKey } from './invitations';
import { Allocation, Currency, Money, TransactionDetail } from './ledger';
import { OptionalPin } from './app';

const Named = Schema.Struct({ id: Uuid, name: Schema.String });
const Reason = Schema.String.check(Schema.isMinLength(3), Schema.isMaxLength(500));
const Text = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max));
/** An exact rate: up to 12 digits and 8 decimals. */
export const RATE_PATTERN = /^[0-9]{1,12}(\.[0-9]{1,8})?$/;
const Rate = Schema.String.check(Schema.isPattern(RATE_PATTERN));
/** An observed moment, ISO 8601 with an offset. */
const Moment = Schema.String.check(
	Schema.isPattern(
		/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?(Z|[+-][0-9]{2}:[0-9]{2})$/
	)
);
const Evidence = Schema.Struct({
	evidenceId: Uuid,
	name: Schema.String,
	mimeType: Schema.NullOr(Schema.String),
	size: Schema.NullOr(Schema.Number)
});

export const EntryKind = Schema.Literals(['conversion', 'adjustment', 'returned_funds']);
export type EntryKind = typeof EntryKind.Type;
export const EntryStatus = Schema.Literals(['needs_review', 'posted', 'rejected']);

export const Entry = Schema.Struct({
	entryId: Uuid,
	reference: Schema.String,
	kind: EntryKind,
	status: EntryStatus,
	direction: Schema.Literals(['credit', 'debit']),
	currency: Currency,
	amount: Money,
	pocket: Schema.NullOr(Schema.Struct({ pocketId: Uuid, name: Schema.String })),
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
	observedAt: Schema.NullOr(IsoDateTime),
	externalReference: Schema.NullOr(Schema.String),
	reason: Schema.NullOr(Schema.String),
	notes: Schema.NullOr(Schema.String),
	withdrawal: Schema.NullOr(
		Schema.Struct({
			withdrawalId: Uuid,
			reference: Schema.String,
			destination: Schema.Struct({
				bankName: Schema.NullOr(Schema.String),
				accountLast4: Schema.String
			})
		})
	),
	lines: Schema.NullOr(
		Schema.Array(
			Schema.Struct({
				pocketId: Uuid,
				pocket: Schema.String,
				basisPoints: Schema.Int,
				amount: Money
			})
		)
	),
	member: Person,
	membershipId: Uuid,
	walletId: Uuid,
	office: Named,
	submittedBy: Person,
	createdAt: IsoDateTime,
	evidence: Schema.Array(Evidence),
	review: Schema.NullOr(
		Schema.Struct({
			decision: Schema.Literals(['clear', 'reject']),
			reason: Schema.String,
			decidedAt: IsoDateTime,
			reviewer: Person
		})
	),
	transactionId: Schema.NullOr(Uuid),
	replayed: Schema.optionalKey(Schema.Boolean)
});
export type Entry = typeof Entry.Type;

/** What can still come back from a completed withdrawal (W-16). */
export const Returnable = Schema.Struct({
	withdrawalId: Uuid,
	reference: Schema.String,
	status: Schema.String,
	currency: Currency,
	member: Person,
	membershipId: Uuid,
	walletId: Uuid,
	pocket: Schema.Struct({ pocketId: Uuid, name: Schema.String }),
	destination: Schema.Struct({
		bankName: Schema.NullOr(Schema.String),
		accountLast4: Schema.String,
		accountNumberMasked: Schema.String,
		accountName: Schema.String
	}),
	completedAt: Schema.NullOr(IsoDateTime),
	paidOn: Schema.NullOr(Schema.String),
	paidOut: Money,
	returned: Money,
	pending: Money,
	remaining: Money,
	returns: Schema.Array(
		Schema.Struct({
			entryId: Uuid,
			reference: Schema.String,
			status: EntryStatus,
			amount: Money,
			createdAt: IsoDateTime,
			inEffect: Schema.Boolean
		})
	)
});
export type Returnable = typeof Returnable.Type;

export const ReturnedEntry = Schema.Struct({ ...Entry.fields, returnable: Returnable });
export type ReturnedEntry = typeof ReturnedEntry.Type;

/** A conversion / adjustment / returned-funds case in the evidence review queue. */
export const EntryCase = Schema.Struct({
	kind: EntryKind,
	caseId: Uuid,
	status: EntryStatus,
	entry: Entry,
	returnable: Schema.NullOr(Returnable),
	canDecide: Schema.Boolean,
	replayed: Schema.optionalKey(Schema.Boolean)
});
export type EntryCase = typeof EntryCase.Type;

export const EntryTarget = Schema.Struct({
	membershipId: Uuid,
	person: Person,
	role: Role,
	officeId: Uuid,
	officeName: Schema.String
});
export type EntryTarget = typeof EntryTarget.Type;

export const EntryTargetPage = Schema.Struct({
	items: Schema.Array(EntryTarget),
	nextCursor: Schema.NullOr(Schema.String)
});
export type EntryTargetPage = typeof EntryTargetPage.Type;

export const EntrySegment = Schema.Struct({
	accountId: Uuid,
	currency: Currency,
	pocketId: Uuid,
	pocket: Schema.String,
	kind: Schema.Literals(['ordinary', 'debt']),
	posted: Money,
	reserved: Money,
	available: Money
});
export type EntrySegment = typeof EntrySegment.Type;

export const EntrySegments = Schema.Struct({
	membershipId: Uuid,
	person: Person,
	role: Role,
	office: Schema.NullOr(Named),
	eligible: Schema.Boolean,
	currencies: Schema.Array(Schema.Struct({ code: Currency, scale: Schema.Int })),
	allocation: Schema.NullOr(Allocation),
	segments: Schema.Array(EntrySegment)
});
export type EntrySegments = typeof EntrySegments.Type;

export const REVERSAL_CATEGORIES = [
	'recorded_twice',
	'wrong_member',
	'wrong_amount',
	'wrong_pocket',
	'other'
] as const;
export type ReversalCategory = (typeof REVERSAL_CATEGORIES)[number];

export const ReversalPreview = Schema.Struct({
	transaction: TransactionDetail,
	title: Schema.NullOr(Schema.String),
	member: Person,
	walletId: Uuid,
	blocker: Schema.NullOr(Schema.Literals(['not_reversible', 'already_reversed'])),
	lines: Schema.Array(
		Schema.Struct({
			pocketId: Uuid,
			pocket: Schema.String,
			currency: Currency,
			amount: Money,
			available: Money,
			enough: Schema.Boolean
		})
	)
});
export type ReversalPreview = typeof ReversalPreview.Type;

export const Reversal = Schema.Struct({
	reversalId: Uuid,
	reference: Schema.String,
	transactionId: Uuid,
	category: Schema.Literals(REVERSAL_CATEGORIES),
	note: Schema.NullOr(Schema.String),
	createdAt: IsoDateTime,
	reverses: Schema.Struct({ transactionId: Uuid, reference: Schema.String, type: Schema.String }),
	member: Person,
	walletId: Uuid,
	amounts: Schema.Array(Schema.Struct({ currency: Currency, amount: Money })),
	replayed: Schema.optionalKey(Schema.Boolean)
});
export type Reversal = typeof Reversal.Type;

// ── Request bodies (Edge) and app commands (with the optional dialog PIN) ──

const EvidenceIds = Schema.Array(Uuid).check(Schema.isMinLength(1), Schema.isMaxLength(5));

export const ConversionInput = Schema.Struct({
	sourceAccountId: Uuid,
	amount: Money,
	destinationCurrency: Currency,
	destinationAmount: Money,
	quotedRate: Schema.optionalKey(Rate),
	provider: Text(100),
	convertedAt: Moment,
	externalReference: Schema.optionalKey(Text(100)),
	notes: Schema.optionalKey(Text(1000)),
	evidenceIds: EvidenceIds,
	idempotencyKey: IdempotencyKey
});
export type ConversionInput = typeof ConversionInput.Type;
export const ConversionCommand = Schema.Struct({ ...ConversionInput.fields, pin: OptionalPin });

export const AdjustmentInput = Schema.Struct({
	targetMembershipId: Uuid,
	direction: Schema.Literals(['credit', 'debit']),
	currency: Currency,
	amount: Money,
	reason: Reason,
	notes: Schema.optionalKey(Text(1000)),
	evidenceIds: EvidenceIds,
	idempotencyKey: IdempotencyKey
});
export type AdjustmentInput = typeof AdjustmentInput.Type;
export const AdjustmentCommand = Schema.Struct({ ...AdjustmentInput.fields, pin: OptionalPin });

export const ReturnInput = Schema.Struct({
	amount: Money,
	seenAt: Moment,
	returnedBy: Text(100),
	bankReference: Schema.optionalKey(Text(100)),
	notes: Schema.optionalKey(Text(1000)),
	evidenceIds: EvidenceIds,
	idempotencyKey: IdempotencyKey
});
export type ReturnInput = typeof ReturnInput.Type;
export const ReturnCommand = Schema.Struct({ ...ReturnInput.fields, pin: OptionalPin });

export const ReversalInput = Schema.Struct({
	transactionId: Uuid,
	category: Schema.Literals(REVERSAL_CATEGORIES),
	note: Schema.optionalKey(Reason),
	confirmReference: Text(20),
	idempotencyKey: IdempotencyKey
});
export type ReversalInput = typeof ReversalInput.Type;
export const ReversalCommand = Schema.Struct({ ...ReversalInput.fields, pin: OptionalPin });

export const EntryRoutes = {
	targets: { method: 'GET', path: '/entries/targets' },
	segments: { method: 'GET', path: '/entries/segments' },
	createUpload: { method: 'POST', path: '/entry-evidence/uploads' },
	conversions: { method: 'POST', path: '/conversions' },
	adjustments: { method: 'POST', path: '/adjustments' },
	returnable: (id: string) => ({ method: 'GET', path: `/withdrawals/${id}/returnable` }) as const,
	returns: (id: string) => ({ method: 'POST', path: `/withdrawals/${id}/returns` }) as const,
	evidence: (caseId: string, evidenceId: string) =>
		({ method: 'GET', path: `/reviews/${caseId}/evidence/${evidenceId}` }) as const,
	reversalPreview: { method: 'GET', path: '/reversals/preview' },
	reversals: { method: 'POST', path: '/reversals' }
} as const;

/** Same-origin endpoints of the app server. */
export const EntryAppRoutes = {
	targets: '/api/entries/targets',
	segments: '/api/entries/segments',
	evidenceUpload: '/api/entries/evidence',
	conversions: '/api/conversions',
	adjustments: '/api/adjustments',
	returns: (withdrawalId: string) => `/api/returns/${withdrawalId}`,
	evidence: (caseId: string, evidenceId: string) =>
		`/api/evidence-reviews/${caseId}/evidence/${evidenceId}`,
	reversalPreview: '/api/reversals/preview',
	reversals: '/api/reversals'
} as const;
