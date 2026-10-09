import { describe, expect, it } from 'vitest';
import {
	bandPeople,
	dateLabel,
	daysLeftLabel,
	lastDayLabel,
	periodLabel,
	seatsLeftLabel
} from './billing';

describe('billing labels', () => {
	it('shows the last paid day of an exclusive end, in WAT', () => {
		// 14 Mar 2027 00:00 WAT is 13 Mar 23:00 UTC.
		expect(lastDayLabel('2027-03-13T23:00:00Z')).toBe('13 Mar 2027');
		expect(periodLabel('2026-03-13T23:00:00Z', '2027-03-13T23:00:00Z')).toBe(
			'14 Mar 2026 – 13 Mar 2027'
		);
		expect(dateLabel('2027-03-13')).toBe('13 Mar 2027');
	});
	it('names bands and seats like Paper', () => {
		expect(bandPeople(400)).toBe('Up to 400 people');
		expect(bandPeople(1000)).toBe('Up to 1,000 people');
		expect(bandPeople(null)).toBe('1,001+ people');
		expect(seatsLeftLabel(38, 400)).toBe('362 seats left');
		expect(seatsLeftLabel(400, 400)).toBe('No seats left');
		expect(daysLeftLabel(6)).toBe('6 days left');
		expect(daysLeftLabel(1)).toBe('1 day left');
	});
});
