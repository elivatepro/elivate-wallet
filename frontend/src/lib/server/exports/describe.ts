// How a posted movement reads on a statement or report (Paper S01/S02): a
// plain description, badges, and a mono detail line with its reference.
// Safe fields only; never bank details, evidence, reasons or notes.

import type { Currency } from '#lib/contract/ledger.js';
import type { TxnRow } from '#lib/contract/exports.js';
import { formatMoney } from '#lib/money.js';

const CATEGORY: Record<string, string> = {
	recorded_twice: 'recorded twice',
	wrong_member: 'wrong member',
	wrong_amount: 'wrong amount',
	wrong_pocket: 'wrong pocket',
	other: 'correction'
};

/** "₦72,000" when whole, else "₦72,000.50" (Paper's pocket split line). */
function compact(amount: string, currency: Currency): string {
	const text = formatMoney(amount.replace(/^-/, ''), currency);
	return text.endsWith('.00') ? text.slice(0, -3) : text;
}

export function description(row: TxnRow): string {
	switch (row.type) {
		case 'income':
			return `Income · ${row.office}`;
		case 'withdrawal':
			return 'Withdrawal · paid to bank';
		case 'pocket_transfer':
			return row.transfer
				? `Pocket move · ${row.transfer.from} → ${row.transfer.to}`
				: 'Pocket move';
		case 'reversal':
			return `Reversal · ${CATEGORY[row.reversalCategory ?? 'other'] ?? 'correction'}`;
		case 'conversion':
			return row.conversion
				? `Conversion · ${row.conversion.currency} → ${row.conversion.destinationCurrency}`
				: 'Conversion';
		case 'adjustment':
			return `Adjustment · ${row.adjustment?.direction === 'debit' ? 'debit' : 'credit'}`;
		case 'returned_funds':
			return 'Returned funds · payout came back';
		default:
			return row.type.charAt(0).toUpperCase() + row.type.slice(1).replaceAll('_', ' ');
	}
}

/** Badges after the description: Reversed (original) or Correction (the reversal). */
export function badges(row: TxnRow): string[] {
	const out: string[] = [];
	if (row.status === 'reversed') out.push('Reversed');
	if (row.type === 'reversal') out.push('Correction');
	return out;
}

/** "INC-5A1B-0712 · Spend ₦72,000 · Save ₦36,000" and friends. */
export function detail(row: TxnRow, currency: Currency): string {
	const parts = [row.reference];
	if (row.reversedBy) parts.push(`reversed by ${row.reversedBy}`);
	if (row.reverses) parts.push(`reverses ${row.reverses}`);
	switch (row.type) {
		case 'income':
			if (!row.reversedBy) {
				for (const p of row.pockets) parts.push(`${p.pocket} ${compact(p.amount, currency)}`);
			}
			break;
		case 'withdrawal': {
			const from = row.pockets.map((p) => p.pocket);
			if (from.length) parts.push(`from ${from.join(', ')}`);
			break;
		}
		case 'pocket_transfer':
			if (row.transfer)
				parts.push(formatMoney(row.transfer.amount, currency), 'no change to total');
			break;
		case 'conversion':
			if (row.conversion) {
				parts.push(
					`${formatMoney(row.conversion.amount, row.conversion.currency)} → ${formatMoney(
						row.conversion.destinationAmount,
						row.conversion.destinationCurrency
					)}`
				);
			}
			break;
		case 'returned_funds':
			if (row.returnedFor) parts.push(`for ${row.returnedFor}`);
			break;
	}
	return parts.join(' · ');
}

/** Pockets as one CSV cell: "Point Value 4000.00; Savings 1000.00". */
export const pocketCell = (row: TxnRow) =>
	row.pockets.map((p) => `${p.pocket} ${p.amount}`).join('; ');
