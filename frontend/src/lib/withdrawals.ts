// Withdrawals, payouts, evidence review and pocket moves (Blueprint 11):
// display logic shared by the member, approver and reviewer screens. Exact
// decimal strings only; NGN only for withdrawals (W-09).

import type { ApiFailure } from '#lib/contract/errors.js';
import type {
	Payout,
	PayoutRevision,
	PocketTransfer,
	Withdrawal
} from '#lib/contract/withdrawals.js';
import { formatMoney } from '#lib/money.js';

export type Tone = 'warning' | 'info' | 'success' | 'danger' | 'neutral';

const naira = (amount: string) => formatMoney(amount, 'NGN');

/** "Access Bank •• 6789" */
export const destinationTitle = (w: Pick<Withdrawal, 'destination'>) =>
	`${w.destination.bankName ?? 'Bank'} •• ${w.destination.accountLast4}`;

/** The current payout record's latest revision, if any. */
export function currentRevision(payout: Payout | null): PayoutRevision | null {
	if (!payout?.revisions?.length) return null;
	return payout.revisions.find((r) => r.revision === payout.revision) ?? null;
}

/** Where the withdrawal is, as one chip (W01 member view and T03 queue). */
export function withdrawalStage(w: Withdrawal): { label: string; tone: Tone } {
	switch (w.status) {
		case 'requested':
			return { label: 'Requested', tone: 'warning' };
		case 'completed':
			return { label: 'Completed', tone: 'success' };
		case 'rejected':
			return { label: 'Rejected', tone: 'danger' };
		case 'cancelled':
			return { label: 'Cancelled', tone: 'neutral' };
		case 'approved': {
			const p = w.payout;
			if (!p || p.status === 'rejected') return { label: 'Approved · pay out', tone: 'info' };
			if (p.status === 'correction_required') return { label: 'Correction needed', tone: 'danger' };
			if (p.status === 'needs_review') return { label: 'In review', tone: 'warning' };
			if (currentRevision(p)?.check?.status === 'dead') {
				return { label: 'Check delayed', tone: 'warning' };
			}
			return { label: 'Checking receipt', tone: 'info' };
		}
	}
}

/** The member's chip: approvers' sub-states collapse to "Approved". */
export function memberStage(w: Withdrawal): { label: string; tone: Tone } {
	return w.status === 'approved' ? { label: 'Approved', tone: 'info' } : withdrawalStage(w);
}

const day = (iso: string, timeZone?: string) =>
	new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', timeZone }).format(
		new Date(iso)
	);
const dayTime = (iso: string, timeZone?: string) =>
	new Intl.DateTimeFormat('en-GB', {
		day: 'numeric',
		month: 'short',
		hour: '2-digit',
		minute: '2-digit',
		hour12: false,
		timeZone
	}).format(new Date(iso));

/** W01 row subtitle. */
export function memberLine(w: Withdrawal, timeZone?: string): string {
	switch (w.status) {
		case 'requested':
			return `Requested ${dayTime(w.createdAt, timeZone)} · ${w.reference}`;
		case 'approved':
			return `Approved ${day(w.approvedAt ?? w.createdAt, timeZone)} · waiting for payout`;
		case 'completed':
			return `Paid ${day(w.completedAt ?? w.createdAt, timeZone)} · ${w.reference}`;
		case 'cancelled':
			return `Cancelled ${w.decidedBy && w.decidedBy.uid === w.member?.uid ? 'by you ' : ''}${day(
				w.decidedAt ?? w.createdAt,
				timeZone
			)} · hold released`;
		case 'rejected':
			return `Rejected ${day(w.decidedAt ?? w.createdAt, timeZone)}${w.decisionReason ? ` · ${w.decisionReason}` : ''}`;
	}
}

/** T03 row subtitle: "GTBank •• 0412 · requested 5 Oct". */
export function queueLine(w: Withdrawal, timeZone?: string): string {
	const where = destinationTitle(w);
	const p = w.payout;
	if (w.status === 'approved' && p && p.status !== 'rejected') {
		const rev = currentRevision(p);
		if (p.status === 'correction_required' && rev?.check?.finishedAt) {
			return `${where} · receipt checked ${day(rev.check.finishedAt, timeZone)}`;
		}
		return `${where} · receipt sent ${day(rev?.createdAt ?? p.createdAt, timeZone)}`;
	}
	if (w.status === 'approved')
		return `${where} · approved ${day(w.approvedAt ?? w.createdAt, timeZone)}`;
	if (w.status === 'completed')
		return `${where} · paid ${day(w.completedAt ?? w.createdAt, timeZone)}`;
	if (w.status === 'requested') return `${where} · requested ${day(w.createdAt, timeZone)}`;
	return `${where} · ${w.status} ${day(w.decidedAt ?? w.createdAt, timeZone)}`;
}

/** The four-step progress under the amount (T03/C05). */
export function progress(w: Withdrawal): { label: string; state: 'done' | 'current' | 'todo' }[] {
	const p = w.payout && w.payout.status !== 'rejected' ? w.payout : null;
	const reached =
		w.status === 'completed'
			? 4
			: w.status === 'approved'
				? p
					? 3
					: 2
				: w.status === 'requested'
					? 1
					: 0;
	return ['Requested', 'Approved', 'Payout recorded', 'Verified'].map((label, i) => ({
		label,
		state: i < reached ? 'done' : i === reached ? 'current' : 'todo'
	}));
}

/** Plain words for the receipt check's reasons (stored by the backend). */
const REASONS: Record<string, string> = {
	amount_missing: 'The amount isn’t readable on the receipt.',
	amount_invalid: 'The amount on the receipt isn’t a plain figure.',
	amount_mismatch: 'The amount on the receipt is different.',
	currency_missing: 'The receipt doesn’t show the currency.',
	currency_invalid: 'The currency on the receipt isn’t clear.',
	currency_mismatch: 'The receipt is in another currency.',
	recipientAccount_missing: 'The receipt doesn’t show the account number.',
	recipientAccount_invalid: 'The account number on the receipt isn’t readable.',
	recipientAccount_mismatch: 'The account number is different or masked.',
	recipientName_missing: 'The receipt doesn’t show the account name.',
	recipientName_invalid: 'The account name on the receipt isn’t readable.',
	recipientName_mismatch: 'The account name is different.',
	paymentDate_missing: 'The receipt doesn’t show the date.',
	paymentDate_invalid: 'The date on the receipt isn’t readable.',
	paymentDate_mismatch: 'The date paid is different.',
	payment_not_successful: 'The receipt doesn’t say the payment succeeded.',
	reading_confidence: 'The receipt couldn’t be read clearly.'
};
export const reasonText = (reason: string) =>
	REASONS[reason] ?? 'Something on the receipt didn’t match.';

/** Which compare rows to highlight (C07/C09 "You recorded / Receipt shows"). */
export function mismatchedFields(
	reasons: readonly string[]
): Set<'amount' | 'date' | 'account' | 'name'> {
	const out = new Set<'amount' | 'date' | 'account' | 'name'>();
	for (const r of reasons) {
		if (r.startsWith('amount_')) out.add('amount');
		if (r.startsWith('paymentDate_')) out.add('date');
		if (r.startsWith('recipientAccount_')) out.add('account');
		if (r.startsWith('recipientName_')) out.add('name');
	}
	return out;
}

/** The primary fix for one mismatch (C07 "Fix the date"), or a new receipt. */
export function fixLabel(reasons: readonly string[]): string {
	const fields = mismatchedFields(reasons);
	if (fields.size === 1 && fields.has('date')) return 'Fix the date';
	if (fields.size === 1 && fields.has('amount')) return 'Fix the amount';
	return 'Fix the record';
}

/** "₦48,000.00 · fee ₦50.00" */
export const sentLine = (rev: PayoutRevision) =>
	rev.fee ? `${naira(rev.amount)} · fee ${naira(rev.fee)}` : naira(rev.amount);

/** "2026-10-05" → "5 Oct 2026" without shifting the calendar date. */
export function calendarDate(value: string): string {
	const [y, m, d] = value.split('-').map(Number);
	return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeZone: 'UTC' }).format(
		new Date(Date.UTC(y ?? 1970, (m ?? 1) - 1, d ?? 1))
	);
}

/** Exact check that sent + fee ≤ requested (Blueprint 11 Q2), on decimal strings. */
export function withinRequested(sent: string, fee: string | null, requested: string): boolean {
	const units = (a: string) => {
		const [w = '0', f = ''] = a.split('.');
		return BigInt(w + f.padEnd(18, '0').slice(0, 18));
	};
	return units(sent) + (fee ? units(fee) : 0n) <= units(requested);
}

/** Pocket move row: "Main → Savings". */
export const moveTitle = (t: Pick<PocketTransfer, 'from' | 'to'>) =>
	`${t.from.name} → ${t.to.name}`;

export function transferStage(t: PocketTransfer): { label: string; tone: Tone } {
	switch (t.status) {
		case 'requested':
			return { label: 'Requested', tone: 'warning' };
		case 'completed':
			return { label: 'Moved', tone: 'success' };
		case 'rejected':
			return { label: 'Declined', tone: 'danger' };
		case 'cancelled':
			return { label: 'Cancelled', tone: 'neutral' };
	}
}

/** Plain refusal copy for the money-move commands (backend reasons kept). */
export function moveMessage(failure: ApiFailure | undefined): string {
	if (failure?._tag !== 'BackendError') return 'We couldn’t reach Elivate. Check your connection.';
	const reason = String(failure.details.reason ?? '');
	switch (failure.code) {
		case 'insufficient_funds':
			return 'That’s more than this pocket has available.';
		case 'self_target_forbidden':
			return 'You can’t decide your own request.';
		case 'authorization_denied':
			return 'You don’t have permission to do that.';
		case 'payout_account_unusable':
			return 'This bank account can’t receive withdrawals right now.';
		case 'conflict':
			if (reason === 'payout_open')
				return 'A payout is already recorded. Wait for the receipt check.';
			if (reason === 'debt_limit') return 'That’s more than the Debt pocket owes.';
			if (reason === 'withdrawal_state' || reason === 'transfer_state' || reason === 'payout_state')
				return 'Someone already acted on this. It’s been refreshed.';
			return failure.message;
		case 'evidence_invalid':
		case 'evidence_required':
			return 'Upload this payout’s receipt again (PDF, JPG or PNG).';
		case 'target_not_eligible':
			return 'This membership can’t move money right now.';
		case 'validation_error':
			if (failure.details.field === 'amount') return 'Check the amount.';
			if (failure.details.field === 'fee')
				return 'Amount sent plus fee can’t be more than requested.';
			if (failure.details.field === 'paidOn') return 'Check the date paid.';
			return failure.message;
		default:
			return failure.message;
	}
}
