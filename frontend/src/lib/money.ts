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
