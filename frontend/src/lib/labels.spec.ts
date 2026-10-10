import { describe, expect, it } from 'vitest';
import { maskEmail, rankLabel } from './labels.js';

describe('maskEmail', () => {
	it('keeps the first character and the domain only', () => {
		expect(maskEmail('adaeze@example.com')).toBe('a•••••@example.com');
		expect(maskEmail('a@example.com')).toBe('a•••••@example.com');
	});

	it('never echoes a malformed value', () => {
		expect(maskEmail('no-at-sign')).toBe('•••••');
		expect(maskEmail('@example.com')).toBe('•••••');
	});
});

describe('rankLabel', () => {
	it('puts the level number first', () => {
		expect(rankLabel('Ruby Director 4')).toBe('4 Ruby Director');
		expect(rankLabel('Ruby Director 1')).toBe('1 Ruby Director');
		expect(rankLabel('ruby_director_5')).toBe('5 Ruby Director');
	});

	it('leaves ranks without a level as they are', () => {
		expect(rankLabel('Diamond Director')).toBe('Diamond Director');
		expect(rankLabel('diamond_director')).toBe('Diamond Director');
		expect(rankLabel('Senior Manager')).toBe('Senior Manager');
	});
});
