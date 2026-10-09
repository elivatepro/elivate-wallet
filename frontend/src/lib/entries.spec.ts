import { describe, expect, it } from 'vitest';
import { BackendError } from '#lib/contract/errors.js';
import {
	differenceFromQuote,
	effectiveRate,
	entryMessage,
	entryStage,
	entryTitle,
	formatRate,
	localMoment,
	localNow,
	rateBase
} from './entries';

const backend = (code: string, details: Record<string, unknown> = {}) =>
	new BackendError({
		status: 409,
		code: code as never,
		message: 'Refused.',
		retryable: false,
		details,
		requestId: null
	});

describe('conversion rates', () => {
	it('quotes per one US dollar whichever way it goes', () => {
		expect(rateBase('USD', 'NGN')).toBe('USD');
		expect(rateBase('NGN', 'USD')).toBe('USD');
	});

	it('works out the rate actually used, exactly (Paper B07)', () => {
		expect(effectiveRate('420.00', 'USD', '638400.00', 'NGN')).toBe('1520.000000');
		expect(effectiveRate('152000.00', 'NGN', '100.00', 'USD')).toBe('1520.000000');
		expect(effectiveRate('3.00', 'USD', '10.00', 'NGN')).toBe('3.333333');
		expect(effectiveRate('3.00', 'USD', '20.00', 'NGN')).toBe('6.666667');
		expect(effectiveRate('0.00', 'USD', '20.00', 'NGN')).toBeNull();
	});

	it('shows the difference from the quote in the quoted currency', () => {
		expect(differenceFromQuote('420.00', 'USD', '638400.00', 'NGN', '1525')).toBe('2100.00');
		expect(differenceFromQuote('640500.00', 'NGN', '420.00', 'USD', '1525')).toBe('0.00');
		expect(differenceFromQuote('1.00', 'USD', '1520.50', 'NGN', '1520')).toBe('-0.50');
		expect(differenceFromQuote('1.00', 'USD', '1600.00', 'NGN', '1520')).toBe('-80.00');
		expect(differenceFromQuote('420.00', 'USD', '638400.00', 'NGN', null)).toBeNull();
		expect(differenceFromQuote('420.00', 'USD', '638400.00', 'NGN', '1,525')).toBeNull();
	});

	it('formats rates like the design', () => {
		expect(formatRate('1520.000000', 'NGN', 'USD')).toBe('₦1,520.00 per $1');
		expect(formatRate('1525', 'NGN', 'USD')).toBe('₦1,525.00 per $1');
		expect(formatRate('3.333333', 'NGN', 'USD')).toBe('₦3.333333 per $1');
	});
});

describe('moments', () => {
	it('turns a local date-time into ISO with the offset', () => {
		expect(localMoment('2026-10-02T16:40', 60)).toBe('2026-10-02T16:40:00+01:00');
		expect(localMoment('2026-10-02T16:40', -330)).toBe('2026-10-02T16:40:00-05:30');
		expect(localMoment('2026-10-02', 60)).toBeNull();
	});

	it('gives now as a date-time field value', () => {
		expect(localNow(new Date(2026, 9, 2, 9, 5))).toBe('2026-10-02T09:05');
	});
});

describe('labels', () => {
	it('names entries and their states', () => {
		expect(
			entryTitle({
				kind: 'conversion',
				direction: 'debit',
				currency: 'USD',
				conversion: {
					destinationCurrency: 'NGN',
					destinationAmount: '1.00',
					rateBase: 'USD',
					rateQuote: 'NGN',
					effectiveRate: '1',
					quotedRate: null
				}
			})
		).toBe('Conversion · USD → NGN');
		expect(
			entryTitle({ kind: 'adjustment', direction: 'credit', currency: 'NGN', conversion: null })
		).toBe('Adjustment · credit');
		expect(entryStage('needs_review').label).toBe('Needs review');
		expect(entryStage('posted').tone).toBe('success');
	});

	it('explains refusals with the backend reason kept', () => {
		expect(entryMessage(backend('conflict', { reason: 'exceeds_returnable' }))).toBe(
			'That’s more than can still come back.'
		);
		expect(entryMessage(backend('conflict', { reason: 'confirmation_mismatch' }))).toBe(
			'Type the reference exactly as shown.'
		);
		expect(entryMessage(backend('insufficient_funds', { pocket: 'Savings' }))).toBe(
			'Savings doesn’t have enough available for its share.'
		);
		expect(entryMessage(backend('validation_error', { field: 'convertedAt' }))).toBe(
			'Check the date and time (not in the future).'
		);
		expect(entryMessage(undefined)).toBe('We couldn’t reach Elivate. Check your connection.');
	});
});
