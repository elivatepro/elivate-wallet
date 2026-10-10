// Team themes (Blueprint 17, Paper TS01d): every preset keeps the contrast
// promised to the owner, in dark and light, straight from tokens.css.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { THEMES } from '#lib/contract/settings.js';

const css = readFileSync(new URL('./ui/tokens.css', import.meta.url), 'utf8');

const channel = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
function luminance(hex: string): number {
	const [r, g, b] = [1, 3, 5].map((i) => channel(parseInt(hex.slice(i, i + 2), 16) / 255));
	return 0.2126 * r! + 0.7152 * g! + 0.0722 * b!;
}
const contrast = (a: string, b: string) => {
	const [x, y] = [luminance(a), luminance(b)];
	return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
};

function block(selector: string): Record<string, string> {
	const at = css.indexOf(`${selector} {`);
	expect(at, selector).toBeGreaterThan(-1);
	const body = css.slice(at, css.indexOf('}', at));
	return Object.fromEntries(
		[...body.matchAll(/--([a-z-]+):\s*(#[0-9a-f]{6})\s*;/gi)].map((m) => [
			m[1]!,
			m[2]!.toLowerCase()
		])
	);
}

const INK = '#14100e';
const DARK_SURFACE = '#1a1d1e';
const WHITE = '#ffffff';

describe('team themes', () => {
	for (const theme of THEMES.filter((t) => t !== 'ember')) {
		it(`${theme} keeps its contrast in dark and light`, () => {
			const dark = block(`[data-team-theme='${theme}']`);
			const light = block(`[data-team-theme='${theme}'][data-theme='light']`);
			expect(contrast(INK, dark['color-accent']!)).toBeGreaterThanOrEqual(7.5);
			expect(contrast(dark['color-accent-text']!, DARK_SURFACE)).toBeGreaterThanOrEqual(7);
			expect(contrast(light['color-accent-text']!, WHITE)).toBeGreaterThanOrEqual(5.6);
			expect(
				contrast(light['color-accent-text']!, light['color-accent-subtle']!)
			).toBeGreaterThanOrEqual(4.5);
		});
	}

	it('never recolours the Elivate mark', () => {
		expect(css).not.toMatch(/data-team-theme[^{]*\{[^}]*--color-brand/);
	});
});
