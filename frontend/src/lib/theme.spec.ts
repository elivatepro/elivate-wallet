// Blueprint 41: the More page's Dark mode switch shows the theme on screen.
import { describe, expect, it } from 'vitest';
import { effectiveTheme, parseTheme } from '#lib/theme.js';

describe('effective theme', () => {
	it('a chosen theme is what shows', () => {
		expect(effectiveTheme('dark', true)).toBe('dark');
		expect(effectiveTheme('light', false)).toBe('light');
	});

	it('System follows the device', () => {
		expect(effectiveTheme('system', true)).toBe('light');
		expect(effectiveTheme('system', false)).toBe('dark');
	});

	it('an unknown cookie is dark', () => {
		expect(effectiveTheme(parseTheme('sepia'), true)).toBe('dark');
	});
});
