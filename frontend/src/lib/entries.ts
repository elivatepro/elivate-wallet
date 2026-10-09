// Conversions, adjustments, returned funds and reversals (Blueprint 12): pure
// presentation rules. Every amount stays a decimal string; rates are worked
// out with BigInt, never floats (F-01.4). The backend decides everything.

import type { ApiFailure } from '#lib/contract/errors.js';
import type { Currency } from '#lib/contract/ledger.js';
import type { Entry, EntryKind, ReversalCategory } from '#lib/contract/entries.js';
import { currencySymbol, formatMoney } from '#lib/money.js';
import type { Tone } from '#lib/withdrawals.js';

export const KIND_LABELS: Record<EntryKind, string> = {
	conversion: 'Conversion',
	adjustment: 'Adjustment',
	returned_funds: 'Returned funds'
};

/** "Conversion · USD → NGN", "Adjustment · credit", "Returned funds". */
export function entryTitle(
	e: Pick<Entry, 'kind' | 'direction' | 'currency' | 'conversion'>
): string {
	if (e.kind === 'conversion' && e.conversion)
		return `Conversion · ${e.currency} → ${e.conversion.destinationCurrency}`;
	if (e.kind === 'adjustment') return `Adjustment · ${e.direction}`;
	return KIND_LABELS[e.kind];
}

export function entryStage(status: Entry['status']): { label: string; tone: Tone } {
	switch (status) {
		case 'needs_review':
			return { label: 'Needs review', tone: 'warning' };
		case 'posted':
			return { label: 'Cleared', tone: 'success' };
		case 'rejected':
			return { label: 'Rejected', tone: 'danger' };
	}
}

/** Rates are quoted per one unit of the base: USD when it is one side (Paper B07). */
export const rateBase = (a: Currency, b: Currency): Currency =>
	a === 'USD' || b === 'USD' ? 'USD' : a < b ? a : b;

const SCALE = 6;
const toUnits = (value: string, scale: number): bigint => {
	const [whole = '0', fraction = ''] = value.split('.');
	return BigInt(whole + fraction.padEnd(scale, '0').slice(0, scale));
};
const fromUnits = (units: bigint, scale: number): string => {
	const text = units.toString().padStart(scale + 1, '0');
	return `${text.slice(0, -scale)}.${text.slice(-scale)}`;
};

/**
 * Quote-currency units per one base unit, exact to 6 decimals (half-up):
 * 638400.00 NGN for 420.00 USD → "1520.000000". Null when either is zero.
 */
export function effectiveRate(
	amount: string,
	currency: Currency,
	received: string,
	receivedCurrency: Currency
): string | null {
	const base = rateBase(currency, receivedCurrency);
	const [quote, per] = base === currency ? [received, amount] : [amount, received];
	const q = toUnits(quote, 2);
	const p = toUnits(per, 2);
	if (p === 0n || q === 0n) return null;
	const scaled = q * 10n ** BigInt(SCALE + 1);
	const raw = scaled / p;
	return fromUnits((raw + 5n) / 10n, SCALE);
}

/** "₦1,520.00 per $1" (trailing rate decimals trimmed to at least 2). */
export function formatRate(rate: string, quote: Currency, base: Currency): string {
	const [whole = '0', fraction = ''] = rate.split('.');
	const trimmed = fraction.replace(/0+$/, '').padEnd(2, '0');
	const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
	return `${currencySymbol(quote)}${grouped}.${trimmed} per ${currencySymbol(base)}1`;
}

/**
 * Received − amount × quoted rate, in the quote currency, when the quote is
 * known: the "Difference from quote" line (B07). Exact; null when unknown.
 */
export function differenceFromQuote(
	amount: string,
	currency: Currency,
	received: string,
	receivedCurrency: Currency,
	quotedRate: string | null
): string | null {
	if (!quotedRate || !/^\d{1,12}(\.\d{1,8})?$/.test(quotedRate)) return null;
	const base = rateBase(currency, receivedCurrency);
	const rate = toUnits(quotedRate, 8);
	// Expected quote amount at 2 decimals (half-up), in minor units.
	if (base === currency) {
		const expected = (toUnits(amount, 2) * rate + 50_000_000n) / 100_000_000n;
		return fromUnits(expected - toUnits(received, 2), 2);
	}
	const expected = (toUnits(received, 2) * rate + 50_000_000n) / 100_000_000n;
	return fromUnits(expected - toUnits(amount, 2), 2);
}

/** A `datetime-local` value ("2026-10-02T16:40") in the browser zone → ISO with offset. */
export function localMoment(value: string, offsetMinutes?: number): string | null {
	const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})$/.exec(value);
	if (!match) return null;
	const [, y, mo, d, h, mi] = match.map(Number) as [number, number, number, number, number, number];
	const local = new Date(y, mo - 1, d, h, mi);
	if (Number.isNaN(local.getTime())) return null;
	const offset = offsetMinutes ?? -local.getTimezoneOffset();
	const sign = offset >= 0 ? '+' : '-';
	const abs = Math.abs(offset);
	const pad = (n: number) => String(n).padStart(2, '0');
	return `${value}:00${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
}

/** Now as a `datetime-local` value (minutes). */
export function localNow(now: Date = new Date()): string {
	const pad = (n: number) => String(n).padStart(2, '0');
	return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}T${pad(now.getHours())}:${pad(now.getMinutes())}`;
}

/** Paper E05's reason list; "Other" asks for the person's own words. */
export const ADJUSTMENT_REASONS = [
	'Goodwill credit from the network',
	'Refund of a charge',
	'Recovery of an overpayment',
	'Correction agreed with the member'
] as const;

export const REVERSAL_LABELS: Record<ReversalCategory, string> = {
	recorded_twice: 'Recorded twice',
	wrong_member: 'Recorded for the wrong member',
	wrong_amount: 'Wrong amount',
	wrong_pocket: 'Wrong pocket',
	other: 'Other'
};

/** "+₦12,000.00" / "−₦9,000.00" for an adjustment. */
export const signedEntryAmount = (e: Pick<Entry, 'direction' | 'amount' | 'currency'>) =>
	formatMoney(e.direction === 'debit' ? `-${e.amount}` : e.amount, e.currency, true);

/** Plain refusal copy for these commands (backend reasons kept). */
export function entryMessage(failure: ApiFailure | undefined): string {
	if (failure?._tag !== 'BackendError') return 'We couldn’t reach Elivate. Check your connection.';
	const reason = String(failure.details.reason ?? '');
	switch (failure.code) {
		case 'insufficient_funds':
			return failure.details.pocket
				? `${String(failure.details.pocket)} doesn’t have enough available for its share.`
				: 'A pocket doesn’t have that much available right now.';
		case 'self_target_forbidden':
			return 'You can’t do this for your own money.';
		case 'authorization_denied':
			return 'You don’t have permission to do that.';
		case 'target_not_eligible':
			return 'This member can’t receive changes right now.';
		case 'evidence_required':
			return 'Add at least one evidence file.';
		case 'evidence_invalid':
			return 'Upload the evidence again (PDF, JPG or PNG).';
		case 'not_found':
			return 'We couldn’t find that. Check the reference.';
		case 'conflict':
			if (reason === 'exceeds_returnable') return 'That’s more than can still come back.';
			if (reason === 'confirmation_mismatch') return 'Type the reference exactly as shown.';
			if (reason === 'already_reversed') return 'This transaction has already been reversed.';
			if (reason === 'not_reversible')
				return 'A completed withdrawal can’t be reversed. Record returned funds instead.';
			if (reason === 'entry_state' || reason === 'withdrawal_state')
				return 'Someone already acted on this. It’s been refreshed.';
			return failure.message;
		case 'validation_error':
			switch (failure.details.field) {
				case 'amount':
					return 'Check the amount.';
				case 'destinationAmount':
					return 'Check the amount received.';
				case 'destinationCurrency':
					return 'Pick a different currency to convert into.';
				case 'quotedRate':
					return 'Check the quoted rate.';
				case 'convertedAt':
				case 'seenAt':
					return 'Check the date and time (not in the future).';
				case 'reason':
					return 'Give a reason (3–500 characters).';
				case 'note':
					return 'Add a note (3–500 characters).';
				default:
					return failure.message;
			}
		default:
			return failure.message;
	}
}
