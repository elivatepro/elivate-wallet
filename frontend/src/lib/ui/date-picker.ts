// Slice 32 (owner 2026-10-11, Paper "Date picker v8" DP01/DP02): the pure
// parts of the app's date picker. Dates are calendar days as `YYYY-MM-DD`
// strings (what <input type="date"> posts and the API takes); no time zones.

export interface Day {
	readonly y: number;
	/** 1–12 */
	readonly m: number;
	readonly d: number;
}

const ISO = /^(\d{4})-(\d{2})-(\d{2})$/;

export function parseIso(value: string | null | undefined): Day | null {
	const match = value ? ISO.exec(value) : null;
	if (!match) return null;
	const day = { y: Number(match[1]), m: Number(match[2]), d: Number(match[3]) };
	return toIso(fromUtc(utc(day))) === value ? day : null;
}

export function toIso(day: Day): string {
	return `${String(day.y).padStart(4, '0')}-${String(day.m).padStart(2, '0')}-${String(day.d).padStart(2, '0')}`;
}

const utc = (day: Day) => Date.UTC(day.y, day.m - 1, day.d);
const fromUtc = (ms: number): Day => {
	const date = new Date(ms);
	return { y: date.getUTCFullYear(), m: date.getUTCMonth() + 1, d: date.getUTCDate() };
};

export function addDays(day: Day, n: number): Day {
	return fromUtc(utc(day) + n * 86_400_000);
}

/** Same day number in another month, kept inside that month (31 Jan + 1 → 28/29 Feb). */
export function addMonths(day: Day, n: number): Day {
	const index = day.y * 12 + (day.m - 1) + n;
	const y = Math.floor(index / 12);
	const m = (index % 12) + 1;
	return { y, m, d: Math.min(day.d, daysIn(y, m)) };
}

export function daysIn(y: number, m: number): number {
	return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

/** Monday = 0 … Sunday = 6. */
export function weekday(day: Day): number {
	return (new Date(utc(day)).getUTCDay() + 6) % 7;
}

export function compare(a: Day, b: Day): number {
	return utc(a) - utc(b);
}

export function within(day: Day, min: Day | null, max: Day | null): boolean {
	return (!min || compare(day, min) >= 0) && (!max || compare(day, max) <= 0);
}

export function clamp(day: Day, min: Day | null, max: Day | null): Day {
	if (min && compare(day, min) < 0) return min;
	if (max && compare(day, max) > 0) return max;
	return day;
}

/** The month's weeks, Monday first; days outside the month are null. */
export function monthGrid(y: number, m: number): (Day | null)[][] {
	const first = { y, m, d: 1 };
	const cells: (Day | null)[] = Array.from({ length: weekday(first) }, () => null);
	for (let d = 1; d <= daysIn(y, m); d += 1) cells.push({ y, m, d });
	while (cells.length % 7) cells.push(null);
	const weeks: (Day | null)[][] = [];
	for (let i = 0; i < cells.length; i += 7) weeks.push(cells.slice(i, i + 7));
	return weeks;
}

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
] as const;
const DAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

export const monthName = (m: number) => MONTHS[m - 1]!;
export const shortMonth = (m: number) => monthName(m).slice(0, 3);

/** The field: "2 Oct 2026" (never 11/10/2026, which reads two ways). */
export function fieldLabel(day: Day): string {
	return `${day.d} ${shortMonth(day.m)} ${day.y}`;
}

/** The sheet's line: "Fri 2 Oct 2026". */
export function shortLabel(day: Day): string {
	return `${DAYS[weekday(day)]!.slice(0, 3)} ${fieldLabel(day)}`;
}

/** A day button's accessible name: "Friday 2 October 2026". */
export function spokenLabel(day: Day): string {
	return `${DAYS[weekday(day)]} ${day.d} ${monthName(day.m)} ${day.y}`;
}

/** The day a key moves to, or null for keys the grid doesn't handle. */
export function keyMove(key: string, from: Day, shift = false): Day | null {
	switch (key) {
		case 'ArrowLeft':
			return addDays(from, -1);
		case 'ArrowRight':
			return addDays(from, 1);
		case 'ArrowUp':
			return addDays(from, -7);
		case 'ArrowDown':
			return addDays(from, 7);
		case 'Home':
			return addDays(from, -weekday(from));
		case 'End':
			return addDays(from, 6 - weekday(from));
		case 'PageUp':
			return addMonths(from, shift ? -12 : -1);
		case 'PageDown':
			return addMonths(from, shift ? 12 : 1);
		default:
			return null;
	}
}

/** Today in the device's own calendar (the field's "Today"). */
export function todayLocal(now = new Date()): Day {
	return { y: now.getFullYear(), m: now.getMonth() + 1, d: now.getDate() };
}
