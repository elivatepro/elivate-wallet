// Pure helpers for the payout-accounts screens (W-17; Paper Y02): row labels,
// cooling-off, which actions a row offers, and the copy for backend outcomes.
// Only masked numbers (last 4) ever pass through here.

import type { ApiFailure } from '#lib/contract/errors.js';
import type { PayoutAccount } from '#lib/contract/payout.js';

/** The backend's limit on active accounts (payout.max_active_accounts). */
export const MAX_ACTIVE_ACCOUNTS = 5;

/** "Test Bank •• 6789". */
export const accountTitle = (a: Pick<PayoutAccount, 'bankName' | 'bankCode' | 'accountLast4'>) =>
	`${a.bankName ?? a.bankCode} •• ${a.accountLast4}`;

/** Removed and replaced accounts are history, not choices. */
export const activeAccounts = (items: ReadonlyArray<PayoutAccount>) =>
	items.filter((a) => a.status === 'active');

/** Inside the 24 h cooling-off (W-17): saved, but cannot receive a withdrawal yet. */
export const isCoolingOff = (a: Pick<PayoutAccount, 'usableFrom'>, now: number) =>
	a.usableFrom !== null && Date.parse(a.usableFrom) > now;

/**
 * Offer "Make primary" only for an active, non-primary account that could
 * receive a withdrawal now (Paper Y02: not while cooling off, never on a name
 * mismatch). The backend still decides.
 */
export const canMakePrimary = (a: PayoutAccount, now: number) =>
	a.status === 'active' && !a.isPrimary && a.nameMatch !== 'mismatched' && !isCoolingOff(a, now);

/** The earliest future cooling-off end, to re-render when it passes. */
export const nextUsableAt = (items: ReadonlyArray<PayoutAccount>, now: number): number | null => {
	const times = items
		.map((a) => (a.usableFrom ? Date.parse(a.usableFrom) : NaN))
		.filter((t) => t > now);
	return times.length ? Math.min(...times) : null;
};

interface DateOptions {
	readonly locale?: string;
	readonly timeZone?: string;
}

/** "9 Oct, 14:20". */
export function formatUsable(iso: string, { locale, timeZone }: DateOptions = {}): string {
	const date = new Date(iso);
	const day = new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'short', timeZone }).format(
		date
	);
	const time = new Intl.DateTimeFormat(locale, {
		hour: '2-digit',
		minute: '2-digit',
		hourCycle: 'h23',
		timeZone
	}).format(date);
	return `${day}, ${time}`;
}

/** "14 Mar 2026". */
export const formatAdded = (iso: string, { locale, timeZone }: DateOptions = {}) =>
	new Intl.DateTimeFormat(locale, {
		day: 'numeric',
		month: 'short',
		year: 'numeric',
		timeZone
	}).format(new Date(iso));

/** Digits only; spaces the person typed are dropped. */
export const cleanAccountNumber = (value: string) => value.replace(/\s/g, '');

export type PinProblem =
	{ readonly kind: 'pin'; readonly message: string } | { readonly kind: 'locked' } | null;

/** step_up_required / pin_incorrect stay in the dialog; pin_locked leaves. */
export function pinProblem(
	failure: ApiFailure | undefined,
	ask = 'Enter your PIN to confirm.'
): PinProblem {
	if (failure?._tag !== 'BackendError') return null;
	if (failure.code === 'step_up_required') return { kind: 'pin', message: ask } as const;
	if (failure.code === 'pin_incorrect') {
		const left = Number(failure.details.attemptsRemaining);
		return {
			kind: 'pin',
			message: Number.isInteger(left)
				? `That PIN is incorrect. ${left} ${left === 1 ? 'try' : 'tries'} left.`
				: 'That PIN is incorrect.'
		} as const;
	}
	if (failure.code === 'pin_locked') return { kind: 'locked' } as const;
	return null;
}

/** A refusal gets a new idempotency key; an unknown outcome keeps it (W-00). */
export const isRefusal = (failure: ApiFailure | undefined) => failure?._tag === 'BackendError';

export type PayoutAction = 'lookup' | 'confirm' | 'primary' | 'remove';

/** Field the lookup error belongs to, when it is about one input. */
export function lookupFieldError(
	failure: ApiFailure | undefined
): { field: 'bankCode' | 'accountNumber'; message: string } | null {
	if (failure?._tag !== 'BackendError') return null;
	if (failure.code === 'account_not_found')
		return { field: 'accountNumber', message: 'No account with that number at this bank.' };
	if (failure.code === 'bank_unknown')
		return { field: 'bankCode', message: 'Choose your bank from the list.' };
	if (failure.code === 'validation_error') {
		return failure.details.field === 'accountNumber'
			? { field: 'accountNumber', message: 'Enter the 10-digit account number.' }
			: { field: 'bankCode', message: 'Choose your bank from the list.' };
	}
	return null;
}

/** One short line for a failed payout command. */
export function payoutMessage(failure: ApiFailure | undefined, action: PayoutAction): string {
	if (failure?._tag !== 'BackendError') {
		return action === 'lookup'
			? 'We couldn’t check the account right now. Try again shortly.'
			: 'We couldn’t confirm that. Try again.';
	}
	switch (failure.code) {
		case 'rate_limited':
			return 'Too many account checks. Try again later.';
		case 'provider_unavailable':
			return 'We couldn’t check the account right now. Try again shortly.';
		case 'payout_lookup_expired':
			return 'That check expired. Look the account up again.';
		case 'payout_name_mismatch':
			return 'This account’s name doesn’t match your verified name.';
		case 'payout_account_exists':
			return 'This account is already saved.';
		case 'no_wallet':
			return 'You don’t have a wallet in this network.';
		case 'not_found':
			return 'That account is no longer available. Reload to see your accounts.';
		case 'conflict': {
			const reason = failure.details.reason;
			if (reason === 'account_limit')
				return `You can keep up to ${MAX_ACTIVE_ACCOUNTS} accounts. Remove one first.`;
			if (reason === 'not_active') return 'That account was already removed.';
			if (reason === 'name_mismatch')
				return 'This account’s name doesn’t match your verified name.';
			if (reason === 'unverified') return 'This account isn’t verified.';
			return 'Something changed. Reload to see your accounts.';
		}
		default:
			return failure.message;
	}
}
