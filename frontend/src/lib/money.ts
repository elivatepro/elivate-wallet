// Exact money display from the ledger's decimal strings (never floats).
// Currencies stay separate: nothing here adds amounts of different currencies.

import type { Currency } from '#lib/contract/ledger.js';

const SYMBOL: Record<Currency, string> = { NGN: '₦', USD: '$' };

export const currencySymbol = (currency: Currency) => SYMBOL[currency];

/** What "Hide amounts" shows instead of a figure. */
export const hiddenMoney = (currency: Currency) => `${SYMBOL[currency]}••••••`;

/** "482350.00" → "₦482,350.00"; signed: "+₦180,000.00" / "−₦48,000.00". */
export function formatMoney(amount: string, currency: Currency, signed = false): string {
	const negative = amount.startsWith('-');
	const [whole = '0', fraction] = amount.replace(/^[-+]/, '').split('.');
	const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
	const body = `${SYMBOL[currency]}${grouped}${fraction !== undefined ? `.${fraction}` : ''}`;
	if (negative) return `−${body}`;
	return signed && /[1-9]/.test(amount) ? `+${body}` : body;
}

export const isZero = (amount: string) => !/[1-9]/.test(amount);

/** Exact sum of decimal strings of one currency (BigInt on scaled units, never floats). */
export function sumMoney(amounts: readonly string[]): string {
	const scale = Math.max(0, ...amounts.map((a) => a.split('.')[1]?.length ?? 0));
	let total = 0n;
	for (const amount of amounts) {
		const negative = amount.startsWith('-');
		const [whole = '0', fraction = ''] = amount.replace(/^[-+]/, '').split('.');
		const units = BigInt(whole + fraction.padEnd(scale, '0'));
		total += negative ? -units : units;
	}
	const sign = total < 0n ? '-' : '';
	const digits = (total < 0n ? -total : total).toString().padStart(scale + 1, '0');
	return scale === 0
		? `${sign}${digits}`
		: `${sign}${digits.slice(0, -scale)}.${digits.slice(-scale)}`;
}
