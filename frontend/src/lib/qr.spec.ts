import { describe, expect, it } from 'vitest';
import { qrPath } from './qr.js';

describe('install QR (Blueprint 35)', () => {
	it('keeps a 4-module quiet zone around the code', () => {
		const { size, d } = qrPath('https://app.elivatewallet.com/app');
		// Version 3 (29 modules) plus 4 on each side.
		expect(size).toBe(37);
		const cells = [...d.matchAll(/M(\d+) (\d+)/g)].map((m) => ({
			x: Number(m[1]),
			y: Number(m[2])
		}));
		expect(cells.length).toBeGreaterThan(100);
		expect(cells.every(({ x, y }) => x >= 4 && y >= 4 && x < size - 4 && y < size - 4)).toBe(true);
	});
});
