import { describe, expect, it } from 'vitest';
import { pausedWriteRoute } from '#lib/paused.js';

describe('pausedWriteRoute', () => {
	it('turns off the write pages', () => {
		for (const path of [
			'/app/income',
			'/app/withdrawals/new',
			'/app/split/move',
			'/app/convert',
			'/app/adjust',
			'/app/reversals',
			'/app/queue/returns',
			'/app/invitations',
			'/app/income/',
			'/app/withdrawals/new/'
		]) {
			expect(pausedWriteRoute(path), path).toBe(true);
		}
	});

	it('keeps reads, payouts of approved withdrawals and Billing open', () => {
		for (const path of [
			'/app',
			'/app/activity',
			'/app/withdrawals',
			'/app/queue',
			'/app/evidence',
			'/app/transfers',
			'/app/split',
			'/app/payout-accounts',
			'/app/statements',
			'/app/reports',
			'/app/team',
			'/app/wallets',
			'/app/members',
			'/app/offices',
			'/app/access',
			'/app/audit',
			'/app/account',
			'/app/support',
			'/app/billing',
			'/app/billing/payments/abc'
		]) {
			expect(pausedWriteRoute(path), path).toBe(false);
		}
	});

	it('matches whole segments only', () => {
		expect(pausedWriteRoute('/app/incomes')).toBe(false);
		expect(pausedWriteRoute('/app/convert-later')).toBe(false);
		expect(pausedWriteRoute('/app/withdrawals/newest')).toBe(false);
		expect(pausedWriteRoute('/app/reversals/x')).toBe(true);
	});
});
