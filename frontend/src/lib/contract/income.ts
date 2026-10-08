// Income recording (Blueprint 04 B4 income routes; Blueprint 09). Wire
// schemas for the `ledger` Edge income routes and the app server's own
// /api/income endpoints. Money is a decimal string, never a float.

import { Schema } from 'effect';
import { IdempotencyKey } from './invitations';
import { IsoDateTime, Person, Role, Uuid } from './common';
import { Allocation, Currency, Money } from './ledger';
import { OptionalPin } from './app';

/** One member the actor may record income for (W-08 step 1). */
export const IncomeTarget = Schema.Struct({
	membershipId: Uuid,
	person: Person,
	role: Role,
	officeId: Uuid,
	officeName: Schema.String,
	startedAt: IsoDateTime
});
export type IncomeTarget = typeof IncomeTarget.Type;

export const LedgerCurrency = Schema.Struct({
	code: Schema.String.check(Schema.isPattern(/^[A-Z]{3}$/)),
	scale: Schema.Int
});
export type LedgerCurrency = typeof LedgerCurrency.Type;

/** GET /ledger/income/targets, relayed as-is by GET /api/income/targets. */
export const IncomeTargets = Schema.Struct({
	items: Schema.Array(IncomeTarget),
	nextCursor: Schema.NullOr(Schema.String),
	/** Null when the network has no active split (real missing setup). */
	allocation: Schema.NullOr(Allocation),
	currencies: Schema.NullOr(Schema.Array(LedgerCurrency))
});
export type IncomeTargets = typeof IncomeTargets.Type;

/** POST /ledger/evidence/uploads (Edge adds the signed upload URL + token). */
export const EvidenceUploadIntent = Schema.Struct({
	evidenceId: Uuid,
	uploadUrl: Schema.String,
	token: Schema.String,
	expiresAt: IsoDateTime
});

/** POST /ledger/evidence/uploads/:id/finalize, and POST /api/income/receipts. */
export const EvidenceFinalized = Schema.Struct({
	evidenceId: Uuid,
	status: Schema.Literal('finalized'),
	expiresAt: IsoDateTime
});
export type EvidenceFinalized = typeof EvidenceFinalized.Type;

export const INCOME_REFERENCE_PATTERN = /^INC-[A-Z0-9]{4}-[A-Z0-9]{4}$/;

export const IncomeAllocation = Schema.Struct({
	pocketId: Uuid,
	pocket: Schema.String,
	basisPoints: Schema.Int,
	amount: Money
});
export type IncomeAllocation = typeof IncomeAllocation.Type;

/** finance.income_result: the posted income (also a replay or a cancel-after-post). */
export const IncomePosted = Schema.Struct({
	incomeId: Uuid,
	reference: Schema.String.check(Schema.isPattern(INCOME_REFERENCE_PATTERN)),
	status: Schema.Literal('posted'),
	transactionId: Uuid,
	membershipId: Uuid,
	/** Blueprint 08: the member's wallet (absent on results stored before it). */
	walletId: Schema.optionalKey(Uuid),
	currency: Currency,
	amount: Money,
	allocations: Schema.Array(IncomeAllocation),
	replayed: Schema.optionalKey(Schema.Boolean)
});
export type IncomePosted = typeof IncomePosted.Type;

export const IncomeAttemptCancelled = Schema.Struct({
	status: Schema.Literal('cancelled'),
	cancelledAt: IsoDateTime,
	replayed: Schema.Boolean
});

/** POST /ledger/income/cancel: the posted income if it went through, else cancelled. */
export const CancelIncomeResult = Schema.Union([IncomePosted, IncomeAttemptCancelled]);
export type CancelIncomeResult = typeof CancelIncomeResult.Type;

const Text = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max));
const DATE_PATTERN = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;

/** Body of POST /ledger/income (the PIN is never forwarded to it). */
export const RecordIncomeInput = Schema.Struct({
	targetMembershipId: Uuid,
	currency: Currency,
	amount: Money,
	source: Text(100),
	receivedOn: Schema.String.check(Schema.isPattern(DATE_PATTERN)),
	providerReference: Schema.optionalKey(Text(100)),
	notes: Schema.optionalKey(Text(1000)),
	fee: Schema.optionalKey(Schema.Struct({ amount: Money, currency: Currency })),
	evidenceIds: Schema.Array(Uuid).check(Schema.isMinLength(1), Schema.isMaxLength(5)),
	idempotencyKey: IdempotencyKey
});
export type RecordIncomeInput = typeof RecordIncomeInput.Type;

/** POST /api/income: the record command plus the optional confirm-sheet PIN. */
export const RecordIncomeCommand = Schema.Struct({
	...RecordIncomeInput.fields,
	pin: OptionalPin
});
export type RecordIncomeCommand = typeof RecordIncomeCommand.Type;

/** POST /api/income/cancel and POST /ledger/income/cancel (no step-up). */
export const CancelIncomeCommand = Schema.Struct({
	targetMembershipId: Uuid,
	reason: Schema.String.check(Schema.isMinLength(3), Schema.isMaxLength(500)),
	idempotencyKey: IdempotencyKey
});
export type CancelIncomeCommand = typeof CancelIncomeCommand.Type;

export const IncomeRoutes = {
	targets: { method: 'GET', path: '/income/targets' },
	createUpload: { method: 'POST', path: '/evidence/uploads' },
	finalizeUpload: (evidenceId: string) =>
		({ method: 'POST', path: `/evidence/uploads/${evidenceId}/finalize` }) as const,
	record: { method: 'POST', path: '/income' },
	cancel: { method: 'POST', path: '/income/cancel' }
} as const;

/** Same-origin endpoints of the app server. */
export const IncomeAppRoutes = {
	targets: '/api/income/targets',
	receipts: '/api/income/receipts',
	record: '/api/income',
	cancel: '/api/income/cancel'
} as const;

/** Receipt limits (Blueprint 04 Q10). */
export const RECEIPT_MAX_BYTES = 10 * 1024 * 1024;
export const RECEIPT_MAX_FILES = 5;
export const RECEIPT_MIME_TYPES = ['application/pdf', 'image/jpeg', 'image/png'] as const;
export type ReceiptMime = (typeof RECEIPT_MIME_TYPES)[number];
