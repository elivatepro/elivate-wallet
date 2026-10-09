// Activity presentation rules (W-07 Activity, Blueprint 08). Grouping and
// labels only; every amount and month total comes from the backend as an
// exact decimal string, and currencies are never added together here.

import type { ActivityItem, ActivityMonth, Currency } from '#lib/contract/ledger.js';
import { formatMoney, isZero } from '#lib/money.js';

/** The browser's IANA zone, or UTC when unavailable. */
export function browserTimeZone(): string {
	try {
		return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
	} catch {
		return 'UTC';
	}
}

/** "2026-10" for an instant, in the given zone (matches the backend's month buckets). */
export function monthKey(iso: string, timeZone: string): string {
	const parts = new Intl.DateTimeFormat('en-CA', {
		timeZone,
		year: 'numeric',
		month: '2-digit'
	}).formatToParts(new Date(iso));
	const year = parts.find((p) => p.type === 'year')?.value ?? '0000';
	const month = parts.find((p) => p.type === 'month')?.value ?? '01';
	return `${year}-${month}`;
}

/** "October", or "October 2025" when not the current year. */
export function monthLabel(key: string, now: Date = new Date(), locale = 'en-GB'): string {
	const [year, month] = key.split('-').map(Number) as [number, number];
	const date = new Date(Date.UTC(year, month - 1, 15));
	return new Intl.DateTimeFormat(locale, {
		month: 'long',
		...(year === now.getUTCFullYear() ? {} : { year: 'numeric' }),
		timeZone: 'UTC'
	}).format(date);
}

export interface MonthGroup {
	readonly key: string;
	readonly items: ActivityItem[];
	readonly totals: ActivityMonth['currencies'];
}

/** Items in backend order, grouped by month, with that month's backend totals. */
export function groupByMonth(
	items: readonly ActivityItem[],
	months: readonly ActivityMonth[],
	timeZone: string
): MonthGroup[] {
	const groups: MonthGroup[] = [];
	for (const item of items) {
		const key = monthKey(item.postedAt, timeZone);
		let group = groups.at(-1);
		if (!group || group.key !== key) {
			group = { key, items: [], totals: months.find((m) => m.month === key)?.currencies ?? [] };
			groups.push(group);
		}
		group.items.push(item);
	}
	return groups;
}

/** "In +₦240,000.00 · +$420.00" / "Out −₦75,000.00"; null when nothing moved that way. */
export function monthTotals(
	totals: MonthGroup['totals'],
	hidden: (currency: Currency) => string | null = () => null
): { in: string | null; out: string | null } {
	const show = (pick: 'in' | 'out') => {
		const parts = totals
			.filter((t) => !isZero(t[pick]))
			.map((t) => hidden(t.currency) ?? formatMoney(t[pick], t.currency, true));
		return parts.length ? parts.join(' · ') : null;
	};
	return { in: show('in'), out: show('out') };
}

const TYPE_LABELS: Record<string, string> = { income: 'Income', reversal: 'Reversal' };

/** Movement types the activity type filter offers (Blueprint 08). */
export const TYPE_FILTERS: Record<string, string> = { income: 'Income', reversal: 'Reversal' };

export const typeLabel = (type: string) =>
	TYPE_LABELS[type] ?? type.charAt(0).toUpperCase() + type.slice(1).replaceAll('_', ' ');

/** Durable statuses the activity filter offers (Blueprint 08 B4.2). */
export const STATUS_LABELS: Record<string, string> = { posted: 'Posted', reversed: 'Reversed' };
export const statusLabel = (status: string) => STATUS_LABELS[status] ?? typeLabel(status);

/** Tone of a status pill; unknown statuses stay neutral. */
export const statusTone = (status: string): 'success' | 'warning' | 'danger' | 'neutral' =>
	status === 'posted' ? 'success' : status === 'reversed' ? 'danger' : 'neutral';

export const isCredit = (amount: string) => !amount.startsWith('-') && !isZero(amount);

export type DateRange =
	'any' | '7d' | '30d' | 'this_month' | 'last_month' | 'last_3_months' | 'this_year';

export const DATE_RANGE_LABELS: Record<DateRange, string> = {
	any: 'Any date',
	'7d': 'Last 7 days',
	'30d': 'Last 30 days',
	this_month: 'This month',
	last_month: 'Last month',
	last_3_months: 'Last 3 months',
	this_year: 'This year'
};

const ymd = (y: number, m: number, d: number) => {
	const date = new Date(Date.UTC(y, m, d));
	return date.toISOString().slice(0, 10);
};

/** Inclusive local calendar dates (YYYY-MM-DD in `timeZone`) for a range. */
export function dateRange(
	range: DateRange,
	timeZone: string,
	now: Date = new Date()
): { from?: string; to?: string } {
	if (range === 'any') return {};
	const parts = new Intl.DateTimeFormat('en-CA', {
		timeZone,
		year: 'numeric',
		month: '2-digit',
		day: '2-digit'
	}).formatToParts(now);
	const get = (type: string) => Number(parts.find((p) => p.type === type)?.value);
	const y = get('year');
	const m = get('month') - 1;
	const d = get('day');
	const today = ymd(y, m, d);
	switch (range) {
		case '7d':
			return { from: ymd(y, m, d - 6), to: today };
		case '30d':
			return { from: ymd(y, m, d - 29), to: today };
		case 'this_month':
			return { from: ymd(y, m, 1), to: today };
		case 'last_month':
			return { from: ymd(y, m - 1, 1), to: ymd(y, m, 0) };
		case 'last_3_months':
			return { from: ymd(y, m - 2, 1), to: today };
		case 'this_year':
			return { from: ymd(y, 0, 1), to: today };
	}
}

/** Initials for avatars ("Kemi Okafor" → "KO"); the UID's digits when there is no name. */
export function initials(name: string | null | undefined, uid: string): string {
	const words = (name ?? '').trim().split(/\s+/).filter(Boolean);
	if (words.length === 0) return uid.slice(-2);
	return (
		(words[0]?.[0] ?? '') + (words.length > 1 ? (words.at(-1)?.[0] ?? '') : '')
	).toUpperCase();
}
