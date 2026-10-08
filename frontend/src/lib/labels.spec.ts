import { describe, expect, it } from 'vitest';
import { maskEmail } from './labels.js';

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
