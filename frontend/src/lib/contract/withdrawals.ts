// Withdrawals, payouts, evidence review and pocket moves (Blueprint 11).
// Wire schemas for the `ledger` Edge routes (finance.withdrawal_json,
// payout_json, review_case_json, transfer_json) and the app server's own
// endpoints. Money is a decimal string, never a float. Responses may carry
// extra fields; request bodies must not.

import { Schema } from 'effect';
import { IsoDateTime, Person, Role, Uuid } from './common';
import { IdempotencyKey } from './invitations';
import { Money } from './ledger';
import { OptionalPin } from './app';
import { PayoutAccount } from './payout';
import { EntryCase, EntryKind } from './entries';

const Named = Schema.Struct({ id: Uuid, name: Schema.String });
const PocketRef = Schema.Struct({ pocketId: Uuid, name: Schema.String });
const DATE_PATTERN = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;
export const CalendarDate = Schema.String.check(Schema.isPattern(DATE_PATTERN));
const Reason = Schema.String.check(Schema.isMinLength(3), Schema.isMaxLength(500));
const Text = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max));

export const WithdrawalStatus = Schema.Literals([
	'requested',
	'approved',
	'completed',
	'rejected',
	'cancelled'
]);
export type WithdrawalStatus = typeof WithdrawalStatus.Type;

export const PayoutStatus = Schema.Literals([
	'verifying',
	'correction_required',
	'needs_review',
	'completed',
	'rejected'
]);
export type PayoutStatus = typeof PayoutStatus.Type;

export const CheckStatus = Schema.Literals(['queued', 'leased', 'done', 'dead', 'obsolete']);

/** Facts the model read from the receipt (shown to approvers and reviewers). */
export const ReceiptFacts = Schema.Struct({
	amount: Schema.NullOr(Schema.String),
	currency: Schema.NullOr(Schema.String),
	recipientAccount: Schema.NullOr(Schema.String),
	recipientName: Schema.NullOr(Schema.String),
	transactionDate: Schema.NullOr(Schema.String),
	paymentStatus: Schema.optionalKey(Schema.String),
	confidence: Schema.optionalKey(Schema.String)
});
export type ReceiptFacts = typeof ReceiptFacts.Type;

export const PayoutRevision = Schema.Struct({
	revision: Schema.Int,
	amount: Money,
	fee: Schema.NullOr(Money),
	paidOn: CalendarDate,
	bankReference: Schema.NullOr(Schema.String),
	notes: Schema.NullOr(Schema.String),
	receipt: Schema.Struct({
		evidenceId: Uuid,
		name: Schema.String,
		mimeType: Schema.NullOr(Schema.String),
		size: Schema.NullOr(Schema.Number)
	}),
	createdAt: IsoDateTime,
	check: Schema.NullOr(
		Schema.Struct({
			status: CheckStatus,
			outcome: Schema.NullOr(Schema.Literals(['match', 'mismatch'])),
			reasons: Schema.Array(Schema.String),
			attempts: Schema.Int,
			lastError: Schema.NullOr(Schema.String),
			finishedAt: Schema.NullOr(IsoDateTime),
			facts: Schema.optionalKey(Schema.NullOr(ReceiptFacts))
		})
	)
});
export type PayoutRevision = typeof PayoutRevision.Type;

export const Payout = Schema.Struct({
	payoutId: Uuid,
	attemptNo: Schema.Int,
	status: PayoutStatus,
	revision: Schema.Int,
	submittedBy: Person,
	createdAt: IsoDateTime,
	settledAt: Schema.NullOr(IsoDateTime),
	revisions: Schema.NullOr(Schema.Array(PayoutRevision)),
	review: Schema.NullOr(
		Schema.Struct({
			decision: Schema.Literals(['clear', 'reject']),
			reason: Schema.String,
			decidedAt: IsoDateTime,
			reviewer: Person
		})
	)
});
export type Payout = typeof Payout.Type;

export const WithdrawalCaps = Schema.Struct({
	approve: Schema.Boolean,
	reject: Schema.Boolean,
	cancel: Schema.Boolean,
	reveal: Schema.Boolean,
	record: Schema.Boolean,
	correct: Schema.Boolean,
	retryCheck: Schema.Boolean
});

const WithdrawalFields = {
	withdrawalId: Uuid,
	reference: Schema.String,
	status: WithdrawalStatus,
	currency: Schema.String,
	amount: Money,
	reserved: Money,
	pocket: PocketRef,
	tenant: Named,
	office: Named,
	membershipId: Uuid,
	role: Role,
	walletId: Uuid,
	member: Person,
	requestedBy: Person,
	onBehalf: Schema.Boolean,
	/** Blueprint 40: what it is for; null on withdrawals placed before it was asked. */
	reason: Schema.optionalKey(Schema.NullOr(Schema.String)),
	destination: Schema.Struct({
		payoutAccountId: Uuid,
		bankName: Schema.NullOr(Schema.String),
		accountLast4: Schema.String,
		accountNumberMasked: Schema.String,
		accountName: Schema.String
	}),
	createdAt: IsoDateTime,
	approvedAt: Schema.NullOr(IsoDateTime),
	approvedBy: Person,
	decidedAt: Schema.NullOr(IsoDateTime),
	decidedBy: Person,
	decisionReason: Schema.NullOr(Schema.String),
	completedAt: Schema.NullOr(IsoDateTime),
	transactionId: Schema.NullOr(Uuid),
	payoutAttempts: Schema.Int
} as const;

export const Withdrawal = Schema.Struct({
	...WithdrawalFields,
	payout: Schema.NullOr(Payout),
	can: WithdrawalCaps,
	replayed: Schema.optionalKey(Schema.Boolean)
});
export type Withdrawal = typeof Withdrawal.Type;

export const WithdrawalPage = Schema.Struct({
	items: Schema.Array(Withdrawal),
	nextCursor: Schema.NullOr(Schema.String),
	counts: Schema.Struct({
		all: Schema.Int,
		open: Schema.Int,
		completed: Schema.Int,
		closed: Schema.Int,
		requested: Schema.Int,
		approved: Schema.Int,
		action: Schema.Int,
		verifying: Schema.Int
	}),
	reserved: Money
});
export type WithdrawalPage = typeof WithdrawalPage.Type;

export const WithdrawalSource = Schema.Struct({
	accountId: Uuid,
	membershipId: Uuid,
	office: Named,
	pocket: PocketRef,
	posted: Money,
	reserved: Money,
	available: Money
});
export type WithdrawalSource = typeof WithdrawalSource.Type;

export const WithdrawalSources = Schema.Struct({
	currency: Schema.Literal('NGN'),
	sources: Schema.Array(WithdrawalSource),
	payoutAccounts: Schema.Array(Schema.Struct({ ...PayoutAccount.fields, usable: Schema.Boolean }))
});
export type WithdrawalSources = typeof WithdrawalSources.Type;

/** POST /ledger/withdrawals/:id/reveal: the full number, approver only, never stored. */
export const RevealedDestination = Schema.Struct({
	withdrawalId: Uuid,
	reference: Schema.String,
	bankCode: Schema.String,
	bankName: Schema.NullOr(Schema.String),
	accountName: Schema.String,
	accountLast4: Schema.String,
	accountNumber: Schema.String.check(Schema.isPattern(/^[0-9]{10}$/))
});
export type RevealedDestination = typeof RevealedDestination.Type;

/** GET /ledger/payouts/:id/receipt: a 60-second signed link. */
export const ReceiptLink = Schema.Struct({
	url: Schema.String,
	name: Schema.String,
	mimeType: Schema.NullOr(Schema.String),
	expiresIn: Schema.Int
});
export type ReceiptLink = typeof ReceiptLink.Type;

export const ReviewCase = Schema.Struct({
	kind: Schema.Literal('payout'),
	payoutId: Uuid,
	status: PayoutStatus,
	withdrawal: Schema.Struct(WithdrawalFields),
	payout: Payout,
	canDecide: Schema.Boolean,
	replayed: Schema.optionalKey(Schema.Boolean)
});
export type ReviewCase = typeof ReviewCase.Type;

/** One queue for payouts and, since Blueprint 12, conversions, adjustments and returns. */
export const ReviewItem = Schema.Union([ReviewCase, EntryCase]);
export type ReviewItem = typeof ReviewItem.Type;

export const ReviewPage = Schema.Struct({
	items: Schema.Array(ReviewItem),
	nextCursor: Schema.NullOr(Schema.String),
	counts: Schema.Struct({
		assigned: Schema.Int,
		cleared: Schema.Int,
		rejected: Schema.Int,
		all: Schema.Int
	})
});
export type ReviewPage = typeof ReviewPage.Type;

const PocketKind = Schema.Literals(['ordinary', 'debt']);

export const PocketTransfer = Schema.Struct({
	transferId: Uuid,
	reference: Schema.String,
	status: Schema.Literals(['requested', 'completed', 'rejected', 'cancelled']),
	currency: Schema.String,
	amount: Money,
	reserved: Money,
	from: Schema.Struct({ pocketId: Uuid, name: Schema.String, kind: PocketKind }),
	to: Schema.Struct({ pocketId: Uuid, name: Schema.String, kind: PocketKind }),
	tenant: Named,
	office: Named,
	membershipId: Uuid,
	role: Role,
	walletId: Uuid,
	member: Person,
	requestedBy: Person,
	onBehalf: Schema.Boolean,
	createdAt: IsoDateTime,
	decidedAt: Schema.NullOr(IsoDateTime),
	decidedBy: Person,
	decisionReason: Schema.NullOr(Schema.String),
	transactionId: Schema.NullOr(Uuid),
	can: Schema.Struct({ approve: Schema.Boolean, reject: Schema.Boolean, cancel: Schema.Boolean }),
	replayed: Schema.optionalKey(Schema.Boolean)
});
export type PocketTransfer = typeof PocketTransfer.Type;

export const TransferPage = Schema.Struct({
	items: Schema.Array(PocketTransfer),
	nextCursor: Schema.NullOr(Schema.String),
	counts: Schema.Struct({ open: Schema.Int, history: Schema.Int, all: Schema.Int }),
	reserved: Schema.Array(Schema.Struct({ currency: Schema.String, amount: Money }))
});
export type TransferPage = typeof TransferPage.Type;

export const TransferChoice = Schema.Struct({
	pocketId: Uuid,
	name: Schema.String,
	kind: PocketKind,
	accountId: Schema.NullOr(Uuid),
	posted: Money,
	reserved: Money,
	available: Money,
	canSend: Schema.Boolean,
	canReceive: Schema.Boolean,
	maxReceive: Schema.NullOr(Money)
});
export type TransferChoice = typeof TransferChoice.Type;

export const TransferChoices = Schema.Struct({
	groups: Schema.Array(
		Schema.Struct({
			membershipId: Uuid,
			office: Named,
			currency: Schema.String,
			pockets: Schema.Array(TransferChoice)
		})
	)
});
export type TransferChoices = typeof TransferChoices.Type;

export const EvidenceUploadIntent = Schema.Struct({
	evidenceId: Uuid,
	uploadUrl: Schema.String,
	token: Schema.String,
	expiresAt: IsoDateTime
});

// ── Request bodies (Edge) and app commands (with the optional dialog PIN) ──

export const RequestWithdrawalInput = Schema.Struct({
	accountId: Uuid,
	amount: Money,
	payoutAccountId: Uuid,
	/** Blueprint 40: required, 3–500 characters after trimming. */
	reason: Reason,
	idempotencyKey: IdempotencyKey
});
export const RequestWithdrawalCommand = Schema.Struct({
	...RequestWithdrawalInput.fields,
	pin: OptionalPin
});
export type RequestWithdrawalCommand = typeof RequestWithdrawalCommand.Type;

/** Member/requester cancel: reason optional, no PIN. */
export const CancelOwnCommand = Schema.Struct({
	reason: Schema.optionalKey(Reason),
	idempotencyKey: IdempotencyKey
});

export const KeyCommand = Schema.Struct({ pin: OptionalPin, idempotencyKey: IdempotencyKey });
export const ReasonCommand = Schema.Struct({
	reason: Reason,
	pin: OptionalPin,
	idempotencyKey: IdempotencyKey
});
export const RevealCommand = Schema.Struct({ pin: OptionalPin });

export const PayoutInput = Schema.Struct({
	amount: Money,
	fee: Schema.optionalKey(Money),
	paidOn: CalendarDate,
	bankReference: Schema.optionalKey(Text(100)),
	notes: Schema.optionalKey(Text(1000)),
	evidenceId: Uuid,
	idempotencyKey: IdempotencyKey
});
export type PayoutInput = typeof PayoutInput.Type;
export const PayoutCommand = Schema.Struct({ ...PayoutInput.fields, pin: OptionalPin });
export type PayoutCommand = typeof PayoutCommand.Type;
/** The one fix (Paper U03): without evidenceId the first receipt is kept. */
export const CorrectPayoutCommand = Schema.Struct({
	...PayoutCommand.fields,
	evidenceId: Schema.optionalKey(Uuid)
});
export type CorrectPayoutCommand = typeof CorrectPayoutCommand.Type;

export const ReviewDecision = Schema.Struct({
	kind: Schema.optionalKey(EntryKind),
	decision: Schema.Literals(['clear', 'reject']),
	reason: Reason,
	idempotencyKey: IdempotencyKey
});

export const RequestTransferCommand = Schema.Struct({
	sourceAccountId: Uuid,
	destinationPocketId: Uuid,
	amount: Money,
	idempotencyKey: IdempotencyKey
});
export type RequestTransferCommand = typeof RequestTransferCommand.Type;
export const TransferKeyCommand = Schema.Struct({ idempotencyKey: IdempotencyKey });
export const TransferReasonCommand = Schema.Struct({
	reason: Reason,
	idempotencyKey: IdempotencyKey
});

export const WithdrawalRoutes = {
	sources: { method: 'GET', path: '/me/withdrawal-sources' },
	mine: { method: 'GET', path: '/me/withdrawals' },
	request: { method: 'POST', path: '/me/withdrawals' },
	mineOne: (id: string) => ({ method: 'GET', path: `/me/withdrawals/${id}` }) as const,
	cancelOwn: (id: string) => ({ method: 'POST', path: `/me/withdrawals/${id}/cancel` }) as const,
	queue: { method: 'GET', path: '/withdrawals' },
	detail: (id: string) => ({ method: 'GET', path: `/withdrawals/${id}` }) as const,
	act: (id: string, action: 'approve' | 'reject' | 'cancel' | 'reveal') =>
		({ method: 'POST', path: `/withdrawals/${id}/${action}` }) as const,
	record: (id: string) => ({ method: 'POST', path: `/withdrawals/${id}/payouts` }) as const,
	correct: (payoutId: string) =>
		({ method: 'POST', path: `/payouts/${payoutId}/correct` }) as const,
	retry: (payoutId: string) => ({ method: 'POST', path: `/payouts/${payoutId}/retry` }) as const,
	createUpload: { method: 'POST', path: '/payout-evidence/uploads' },
	finalizeUpload: (evidenceId: string) =>
		({ method: 'POST', path: `/evidence/uploads/${evidenceId}/finalize` }) as const,
	receipt: (payoutId: string) => ({ method: 'GET', path: `/payouts/${payoutId}/receipt` }) as const,
	reviews: { method: 'GET', path: '/reviews' },
	review: (payoutId: string) => ({ method: 'GET', path: `/reviews/${payoutId}` }) as const,
	decide: (payoutId: string) =>
		({ method: 'POST', path: `/reviews/${payoutId}/decision` }) as const,
	choices: { method: 'GET', path: '/me/transfer-choices' },
	myTransfers: { method: 'GET', path: '/me/pocket-transfers' },
	requestTransfer: { method: 'POST', path: '/me/pocket-transfers' },
	cancelTransfer: (id: string) =>
		({ method: 'POST', path: `/me/pocket-transfers/${id}/cancel` }) as const,
	transferQueue: { method: 'GET', path: '/pocket-transfers' },
	actTransfer: (id: string, action: 'approve' | 'reject') =>
		({ method: 'POST', path: `/pocket-transfers/${id}/${action}` }) as const
} as const;

/** Same-origin endpoints of the app server. */
export const WithdrawalAppRoutes = {
	mine: '/api/withdrawals',
	sources: '/api/withdrawals/sources',
	mineOne: (id: string) => `/api/withdrawals/${id}`,
	cancelOwn: (id: string) => `/api/withdrawals/${id}/cancel`,
	queue: '/api/queue',
	detail: (id: string) => `/api/queue/${id}`,
	act: (id: string, action: QueueAction) => `/api/queue/${id}/${action}`,
	receiptUpload: (id: string) => `/api/queue/${id}/receipt`,
	receipt: (payoutId: string, revision: number) =>
		`/api/queue/payouts/${payoutId}/receipt?revision=${revision}`,
	reviews: '/api/evidence-reviews',
	review: (payoutId: string) => `/api/evidence-reviews/${payoutId}`,
	decide: (payoutId: string) => `/api/evidence-reviews/${payoutId}/decision`,
	moves: '/api/pocket-moves',
	choices: '/api/pocket-moves/choices',
	cancelMove: (id: string) => `/api/pocket-moves/${id}/cancel`,
	transfers: '/api/transfers',
	actTransfer: (id: string, action: 'approve' | 'reject') => `/api/transfers/${id}/${action}`
} as const;

export const QUEUE_ACTIONS = [
	'approve',
	'reject',
	'cancel',
	'reveal',
	'payout',
	'correct',
	'retry'
] as const;
export type QueueAction = (typeof QUEUE_ACTIONS)[number];
