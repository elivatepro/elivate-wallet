// Statements and reports (Blueprint 15): WAT periods (owner decision Q1),
// their titles (the same words the backend prints), file labels and states.
// Pure functions, shared by the pages and the export runner.

import type { ExportFile, ExportKind, PeriodKind } from '#lib/contract/exports.js';

/** Periods and printed times are WAT, whatever the device's zone. */
export const STATEMENT_ZONE = 'Africa/Lagos';

const MONTHS = [
	'January',
	'February',
	'March',
	'April',
	'May',
	'June',
	'July',
	'August',
	'September',
	'October',
	'November',
	'December'
];
const SHORT = MONTHS.map((m) => m.slice(0, 3));

/** Today's date in WAT, "YYYY-MM-DD". */
export function watToday(now: Date = new Date()): string {
	return new Intl.DateTimeFormat('en-CA', {
		timeZone: STATEMENT_ZONE,
		year: 'numeric',
		month: '2-digit',
		day: '2-digit'
	}).format(now);
}

const parts = (iso: string) => {
	const [y = 0, m = 1, d = 1] = iso.split('-').map(Number);
	return { y, m, d };
};
const iso = (y: number, m: number, d: number) =>
	`${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
const lastDay = (y: number, m: number) => new Date(Date.UTC(y, m, 0)).getUTCDate();

export interface Period {
	readonly kind: PeriodKind;
	readonly from: string;
	readonly to: string;
}

export interface PeriodPreset extends Period {
	readonly id: 'this_month' | 'last_month' | 'last_quarter' | 'year_to_date';
	readonly label: string;
}

/** Paper S05/S08 chips: This month · <last month> · <last quarter> · <year> so far. */
export function periodPresets(today: string): PeriodPreset[] {
	const { y, m } = parts(today);
	const lastMonthY = m === 1 ? y - 1 : y;
	const lastMonth = m === 1 ? 12 : m - 1;
	const quarter = Math.floor((m - 1) / 3); // 0-based current quarter
	const qY = quarter === 0 ? y - 1 : y;
	const q = quarter === 0 ? 4 : quarter;
	const qStart = (q - 1) * 3 + 1;
	return [
		{
			id: 'this_month',
			label: 'This month',
			kind: 'month',
			from: iso(y, m, 1),
			to: iso(y, m, lastDay(y, m))
		},
		{
			id: 'last_month',
			label: MONTHS[lastMonth - 1] ?? '',
			kind: 'month',
			from: iso(lastMonthY, lastMonth, 1),
			to: iso(lastMonthY, lastMonth, lastDay(lastMonthY, lastMonth))
		},
		{
			id: 'last_quarter',
			label: `Q${q} ${qY}`,
			kind: 'quarter',
			from: iso(qY, qStart, 1),
			to: iso(qY, qStart + 2, lastDay(qY, qStart + 2))
		},
		{
			id: 'year_to_date',
			label: `${y} so far`,
			kind: 'year_to_date',
			from: iso(y, 1, 1),
			to: today
		}
	];
}

/**
 * A custom range as the most specific period kind the backend accepts: a whole
 * calendar month, quarter or year keeps its name ("annual" is a whole year).
 */
export function customPeriod(from: string, to: string): Period {
	const a = parts(from);
	const b = parts(to);
	if (a.d === 1 && a.y === b.y && b.d === lastDay(b.y, b.m)) {
		if (a.m === 1 && b.m === 12) return { kind: 'year', from, to };
		if (a.m === b.m) return { kind: 'month', from, to };
		if ((a.m - 1) % 3 === 0 && b.m === a.m + 2) return { kind: 'quarter', from, to };
	}
	return { kind: 'custom', from, to };
}

/** "September 2026", "Q3 2026", "2026", "2026 so far", "1 Sep – 15 Oct 2026" (as the backend). */
export function periodTitle(period: Period): string {
	const a = parts(period.from);
	const b = parts(period.to);
	switch (period.kind) {
		case 'month':
			return `${MONTHS[a.m - 1]} ${a.y}`;
		case 'quarter':
			return `Q${Math.floor((a.m - 1) / 3) + 1} ${a.y}`;
		case 'year':
			return String(a.y);
		case 'year_to_date':
			return `${a.y} so far`;
		case 'custom':
			return a.y === b.y
				? `${a.d} ${SHORT[a.m - 1]} – ${b.d} ${SHORT[b.m - 1]} ${b.y}`
				: `${a.d} ${SHORT[a.m - 1]} ${a.y} – ${b.d} ${SHORT[b.m - 1]} ${b.y}`;
	}
}

/** "1 – 30 September 2026" (Paper S01 subtitle). */
export function periodRange(period: Pick<Period, 'from' | 'to'>): string {
	const a = parts(period.from);
	const b = parts(period.to);
	if (a.y === b.y && a.m === b.m) return `${a.d} – ${b.d} ${MONTHS[a.m - 1]} ${a.y}`;
	if (a.y === b.y) return `${a.d} ${SHORT[a.m - 1]} – ${b.d} ${SHORT[b.m - 1]} ${a.y}`;
	return `${a.d} ${SHORT[a.m - 1]} ${a.y} – ${b.d} ${SHORT[b.m - 1]} ${b.y}`;
}

/** "1 Oct 2026, 08:12 WAT" for an instant. */
export function watDateTime(instant: string): string {
	const date = new Date(instant);
	const day = new Intl.DateTimeFormat('en-GB', {
		timeZone: STATEMENT_ZONE,
		day: 'numeric',
		month: 'short',
		year: 'numeric'
	}).format(date);
	const time = new Intl.DateTimeFormat('en-GB', {
		timeZone: STATEMENT_ZONE,
		hour: '2-digit',
		minute: '2-digit',
		hourCycle: 'h23'
	}).format(date);
	return `${day}, ${time} WAT`;
}

/** "2 Sep" from "2026-09-02". */
export function shortDate(isoDate: string): string {
	const { m, d } = parts(isoDate);
	return `${d} ${SHORT[m - 1]}`;
}

export const KIND_LABELS: Record<ExportKind, string> = {
	statement_pdf: 'Statement',
	statement_csv: 'Transactions',
	office_pdf: 'Office report',
	transactions_csv: 'Transactions',
	member_balances_csv: 'Member balances'
};

export const CURRENCY_NAMES = { NGN: 'Nigerian naira', USD: 'US dollar' } as const;

/** Second line of a file row (Paper S08/S11 and S06). */
export function fileLine(file: ExportFile, now: Date = new Date()): string {
	switch (file.status) {
		case 'queued':
		case 'preparing':
		case 'rendering':
			return file.background ? 'Big one: we’ll email you when it’s ready' : 'Preparing…';
		case 'too_large':
			return 'Too large for one file. Pick a shorter period.';
		case 'failed':
			return `${KIND_LABELS[file.kind]} · couldn’t finish`;
		case 'expired':
			return `${KIND_LABELS[file.kind]} · removed after 7 days`;
		case 'ready': {
			const ready = file.readyAt ? shortDate(watToday(new Date(file.readyAt))) : '';
			const size =
				file.format === 'pdf' && file.pageCount
					? `${file.pageCount} ${file.pageCount === 1 ? 'page' : 'pages'}`
					: file.rowCount !== null
						? `${file.rowCount} ${file.rowCount === 1 ? 'row' : 'rows'}`
						: '';
			void now;
			return [KIND_LABELS[file.kind], size, ready].filter(Boolean).join(' · ');
		}
	}
}

export type FileState = 'preparing' | 'ready' | 'failed' | 'too_large' | 'expired';

export const fileState = (file: ExportFile): FileState =>
	file.status === 'queued' || file.status === 'preparing' || file.status === 'rendering'
		? 'preparing'
		: file.status;

export const isWorking = (file: ExportFile) => fileState(file) === 'preparing';
