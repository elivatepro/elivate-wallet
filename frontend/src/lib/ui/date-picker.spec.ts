import { describe, expect, it } from 'vitest';
import {
	addMonths,
	clamp,
	fieldLabel,
	keyMove,
	monthGrid,
	parseIso,
	shortLabel,
	spokenLabel,
	toIso,
	within
} from './date-picker';

const day = (iso: string) => parseIso(iso)!;

describe('date picker (Slice 32)', () => {
	it('reads and writes calendar days, refusing impossible ones', () => {
		expect(toIso(day('2026-10-02'))).toBe('2026-10-02');
		expect(parseIso('2026-02-30')).toBeNull();
		expect(parseIso('11/10/2026')).toBeNull();
		expect(parseIso('')).toBeNull();
	});

	it('labels the field "2 Oct 2026", never 11/10/2026', () => {
		expect(fieldLabel(day('2026-10-02'))).toBe('2 Oct 2026');
		expect(shortLabel(day('2026-10-02'))).toBe('Fri 2 Oct 2026');
		expect(spokenLabel(day('2026-10-11'))).toBe('Sunday 11 October 2026');
	});

	it('lays October 2026 out Monday first (the 1st is a Thursday)', () => {
		const weeks = monthGrid(2026, 10);
		expect(weeks[0]!.map((d) => d?.d ?? null)).toEqual([null, null, null, 1, 2, 3, 4]);
		expect(weeks.at(-1)!.map((d) => d?.d ?? null)).toEqual([26, 27, 28, 29, 30, 31, null]);
	});

	it('moves by key like the WAI-ARIA date picker', () => {
		const from = day('2026-10-11');
		expect(toIso(keyMove('ArrowLeft', from)!)).toBe('2026-10-10');
		expect(toIso(keyMove('ArrowDown', from)!)).toBe('2026-10-18');
		expect(toIso(keyMove('Home', from)!)).toBe('2026-10-05');
		expect(toIso(keyMove('End', day('2026-10-07'))!)).toBe('2026-10-11');
		expect(toIso(keyMove('PageUp', from)!)).toBe('2026-09-11');
		expect(toIso(keyMove('PageDown', from, true)!)).toBe('2027-10-11');
		expect(keyMove('a', from)).toBeNull();
	});

	it('keeps month jumps inside short months', () => {
		expect(toIso(addMonths(day('2026-01-31'), 1))).toBe('2026-02-28');
		expect(toIso(addMonths(day('2024-01-31'), 1))).toBe('2024-02-29');
	});

	it('honours min and max', () => {
		const max = day('2026-10-11');
		expect(within(day('2026-10-12'), null, max)).toBe(false);
		expect(within(day('2026-10-11'), null, max)).toBe(true);
		expect(toIso(clamp(day('2026-12-01'), null, max))).toBe('2026-10-11');
		expect(toIso(clamp(day('2026-01-01'), day('2026-02-01'), null))).toBe('2026-02-01');
	});
});
