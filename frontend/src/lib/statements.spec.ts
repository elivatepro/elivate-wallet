import { describe, expect, it } from 'vitest';
import {
	customPeriod,
	periodPresets,
	periodRange,
	periodTitle,
	watDateTime,
	watToday
} from './statements';

describe('WAT periods', () => {
	it('uses Lagos time for today, not the device zone', () => {
		// 23:30 UTC on 30 Sep is already 1 Oct in Lagos (UTC+1).
		expect(watToday(new Date('2026-09-30T23:30:00Z'))).toBe('2026-10-01');
		expect(watToday(new Date('2026-09-30T22:59:00Z'))).toBe('2026-09-30');
	});

	it('offers the Paper chips', () => {
		const presets = periodPresets('2026-10-09');
		expect(presets.map((p) => p.label)).toEqual([
			'This month',
			'September',
			'Q3 2026',
			'2026 so far'
		]);
		expect(presets[0]).toMatchObject({ kind: 'month', from: '2026-10-01', to: '2026-10-31' });
		expect(presets[2]).toMatchObject({ kind: 'quarter', from: '2026-07-01', to: '2026-09-30' });
		expect(presets[3]).toMatchObject({
			kind: 'year_to_date',
			from: '2026-01-01',
			to: '2026-10-09'
		});
	});

	it('rolls back across a year in January', () => {
		const presets = periodPresets('2027-01-15');
		expect(presets[1]).toMatchObject({ label: 'December', from: '2026-12-01', to: '2026-12-31' });
		expect(presets[2]).toMatchObject({ label: 'Q4 2026', from: '2026-10-01', to: '2026-12-31' });
	});

	it('knows leap years', () => {
		expect(periodPresets('2028-03-10')[1]).toMatchObject({ to: '2028-02-29' });
	});

	it('names whole months, quarters and years in a custom range', () => {
		expect(customPeriod('2025-01-01', '2025-12-31').kind).toBe('year');
		expect(customPeriod('2026-04-01', '2026-06-30').kind).toBe('quarter');
		expect(customPeriod('2026-02-01', '2026-02-28').kind).toBe('month');
		expect(customPeriod('2026-02-02', '2026-02-28').kind).toBe('custom');
		expect(customPeriod('2026-05-01', '2026-07-31').kind).toBe('custom');
	});
});

describe('titles match the backend', () => {
	it('prints each kind', () => {
		expect(periodTitle({ kind: 'month', from: '2026-09-01', to: '2026-09-30' })).toBe(
			'September 2026'
		);
		expect(periodTitle({ kind: 'quarter', from: '2026-07-01', to: '2026-09-30' })).toBe('Q3 2026');
		expect(periodTitle({ kind: 'year', from: '2025-01-01', to: '2025-12-31' })).toBe('2025');
		expect(periodTitle({ kind: 'year_to_date', from: '2026-01-01', to: '2026-10-09' })).toBe(
			'2026 so far'
		);
		expect(periodTitle({ kind: 'custom', from: '2026-09-01', to: '2026-10-15' })).toBe(
			'1 Sep – 15 Oct 2026'
		);
		expect(periodTitle({ kind: 'custom', from: '2025-12-28', to: '2026-01-03' })).toBe(
			'28 Dec 2025 – 3 Jan 2026'
		);
	});

	it('prints the statement range and WAT times', () => {
		expect(periodRange({ from: '2026-09-01', to: '2026-09-30' })).toBe('1 – 30 September 2026');
		expect(watDateTime('2026-10-01T07:12:00Z')).toBe('1 Oct 2026, 08:12 WAT');
	});
});
