import { describe, expect, it } from 'vitest';
import { formatMoney, isZero, sumMoney } from './money.js';

describe('formatMoney', () => {
	it('groups digits without floating point', () => {
		expect(formatMoney('482350.00', 'NGN')).toBe('₦482,350.00');
		expect(formatMoney('1234567890123456789.01', 'USD')).toBe('$1,234,567,890,123,456,789.01');
		expect(formatMoney('0.00', 'NGN')).toBe('₦0.00');
	});

	it('signs credits and debits', () => {
		expect(formatMoney('180000.00', 'NGN', true)).toBe('+₦180,000.00');
		expect(formatMoney('-48000.00', 'NGN', true)).toBe('−₦48,000.00');
		expect(formatMoney('0.00', 'NGN', true)).toBe('₦0.00');
	});

	it('knows zero', () => {
		expect(isZero('0.00')).toBe(true);
		expect(isZero('-0.01')).toBe(false);
	});
});

describe('sumMoney', () => {
	it('adds exactly, keeping the largest scale', () => {
		expect(sumMoney(['72000.00', '18000.00', '27000.00', '45000.00', '18000.00'])).toBe(
			'180000.00'
		);
		expect(sumMoney(['0.10', '0.20'])).toBe('0.30');
		expect(sumMoney(['-1.5', '0.25'])).toBe('-1.25');
		expect(sumMoney(['99999999999999999999.99', '0.01'])).toBe('100000000000000000000.00');
	});
});
