// Blueprint 41: the tapped element's spinner (when it shows, and where).
import { describe, expect, it } from 'vitest';
import { PENDING_DELAY_MS, spinnerBox, tapStarted, TAP_WINDOW_MS } from './pending-tap.js';

describe('pending tap', () => {
	it('waits long enough that fast pages never spin', () => {
		expect(PENDING_DELAY_MS).toBeGreaterThanOrEqual(150);
	});

	it('belongs to a navigation that starts soon after the tap', () => {
		expect(tapStarted(1000, 1000)).toBe(true);
		expect(tapStarted(1000, 1000 + TAP_WINDOW_MS)).toBe(true);
		expect(tapStarted(1000, 1001 + TAP_WINDOW_MS)).toBe(false);
		expect(tapStarted(1000, 999)).toBe(false);
	});

	it('takes the place of the icon it replaces', () => {
		const host = { left: 20, top: 100, width: 350, height: 54 };
		const chevron = { left: 338, top: 119, width: 16, height: 16 };
		expect(spinnerBox(host, chevron)).toEqual({ left: 318, top: 19 });
	});

	it('else sits at the trailing edge, centred on the height', () => {
		expect(spinnerBox({ left: 0, top: 0, width: 200, height: 48 }, null)).toEqual({
			left: 170,
			top: 16
		});
		// A short element keeps a small inset.
		expect(spinnerBox({ left: 0, top: 0, width: 100, height: 20 }, null)).toEqual({
			left: 80,
			top: 2
		});
	});
});
