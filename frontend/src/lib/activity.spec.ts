import { describe, expect, it } from 'vitest';
import type { ActivityItem } from '#lib/contract/ledger.js';
import { dateRange, groupByMonth, initials, monthKey, monthLabel, monthTotals } from './activity';

const item = (postedAt: string, amount: string, currency: 'NGN' | 'USD' = 'NGN'): ActivityItem => ({
	transactionId: '00000000-0000-0000-0000-000000000001',
	reference: 'INC-7F2K-0931',
	type: 'income',
	status: 'posted',
	title: 'Fiverr order',
	postedAt,
	tenantId: '00000000-0000-0000-0000-0000000000e1',
	currency,
	amount,
	pocketCount: 5
});

describe('months', () => {
	it('buckets in the given zone like the backend', () => {
		expect(monthKey('2026-09-30T23:30:00Z', 'UTC')).toBe('2026-09');
		expect(monthKey('2026-09-30T23:30:00Z', 'Africa/Lagos')).toBe('2026-10');
	});
	it('labels the current year without the year', () => {
		const now = new Date('2026-10-08T12:00:00Z');
		expect(monthLabel('2026-10', now)).toBe('October');
		expect(monthLabel('2025-09', now)).toBe('September 2025');
	});
	it('groups in backend order and attaches backend totals, currencies apart', () => {
		const groups = groupByMonth(
			[item('2026-10-02T13:12:00Z', '180000.00'), item('2026-09-24T16:48:00Z', '420.00', 'USD')],
			[
				{ month: '2026-10', currencies: [{ currency: 'NGN', in: '180000.00', out: '-48000.00' }] },
				{
					month: '2026-09',
					currencies: [
						{ currency: 'NGN', in: '240000.00', out: '0.00' },
						{ currency: 'USD', in: '420.00', out: '0.00' }
					]
				}
			],
			'Africa/Lagos'
		);
		expect(groups.map((g) => g.key)).toEqual(['2026-10', '2026-09']);
		expect(monthTotals(groups[1]!.totals)).toEqual({ in: '+₦240,000.00 · +$420.00', out: null });
		expect(monthTotals(groups[0]!.totals).out).toBe('−₦48,000.00');
	});
});

it('date ranges are inclusive local dates', () => {
	const now = new Date('2026-10-08T23:30:00Z');
	expect(dateRange('this_month', 'Africa/Lagos', now)).toEqual({
		from: '2026-10-01',
		to: '2026-10-09'
	});
	expect(dateRange('last_month', 'UTC', now)).toEqual({ from: '2026-09-01', to: '2026-09-30' });
	expect(dateRange('7d', 'UTC', now)).toEqual({ from: '2026-10-02', to: '2026-10-08' });
	expect(dateRange('any', 'UTC', now)).toEqual({});
});

it('initials', () => {
	expect(initials('Kemi Okafor', 'EW-48213')).toBe('KO');
	expect(initials(null, 'EW-48213')).toBe('13');
});
