import { describe, expect, it } from 'vitest';
import { normalisePhone } from './phone.js';

describe('normalisePhone', () => {
	it('turns local and international forms into +234…', () => {
		expect(normalisePhone('803 214 5678')).toBe('+2348032145678');
		expect(normalisePhone('08032145678')).toBe('+2348032145678');
		expect(normalisePhone('+234 803-214-5678')).toBe('+2348032145678');
		expect(normalisePhone('2348032145678')).toBe('+2348032145678');
	});

	it('refuses empty and short values', () => {
		expect(normalisePhone('')).toBeNull();
		expect(normalisePhone('803')).toBeNull();
	});
});
