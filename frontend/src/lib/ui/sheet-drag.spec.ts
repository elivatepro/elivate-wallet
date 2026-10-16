// Blueprint 43: when a drag on a bottom sheet starts, follows and closes.
import { describe, expect, it } from 'vitest';
import {
	begin,
	closes,
	decide,
	FLICK_MIN,
	follow,
	RUBBER_MAX,
	scrolledToTop,
	SLOP,
	track,
	velocity,
	type ScrollLike
} from './sheet-drag.js';

const header = { grab: true, atTop: true };
const content = { grab: false, atTop: true };
const scrolled = { grab: false, atTop: false };

describe('sheet drag: starting', () => {
	it('waits inside the slop', () => {
		const g = begin(100, 100, 0, header);
		expect(decide(g, 102, 100 + SLOP - 2, true)).toBe('wait');
	});

	it('drags down from the grabber or header, even with the content scrolled', () => {
		expect(decide(begin(100, 100, 0, header), 101, 130, true)).toBe('drag');
		expect(decide(begin(100, 100, 0, { grab: true, atTop: false }), 101, 130, true)).toBe('drag');
	});

	it('drags from the content only when it is scrolled to the top', () => {
		expect(decide(begin(100, 100, 0, content), 100, 130, true)).toBe('drag');
		expect(decide(begin(100, 100, 0, scrolled), 100, 130, true)).toBe('native');
	});

	it('leaves sideways and upward moves to the browser', () => {
		expect(decide(begin(100, 100, 0, header), 140, 110, true)).toBe('native');
		expect(decide(begin(100, 100, 0, header), 120, 120, true)).toBe('native');
		expect(decide(begin(100, 100, 0, content), 100, 70, true)).toBe('native');
	});

	it('never moves a sheet that may not close (busy)', () => {
		expect(decide(begin(100, 100, 0, header), 100, 160, false)).toBe('native');
	});

	it('keeps a decision once made', () => {
		const g = begin(100, 100, 0, header);
		g.phase = decide(g, 100, 130, true);
		expect(decide(g, 200, 50, true)).toBe('drag');
	});
});

describe('sheet drag: following', () => {
	it('follows the finger down and only rubber-bands up', () => {
		expect(follow(0)).toBe(0);
		expect(follow(120)).toBe(120);
		expect(follow(-20)).toBe(-5);
		expect(follow(-400)).toBe(-RUBBER_MAX);
	});

	it('reads the speed over the end of the drag', () => {
		const g = begin(0, 0, 0, header);
		track(g, 300, 20);
		track(g, 380, 40);
		track(g, 400, 80);
		// The early, slow part is dropped: 60 px over the last 100 ms.
		expect(velocity(g.samples)).toBeCloseTo(0.6);
		expect(velocity([{ t: 5, y: 10 }])).toBe(0);
	});
});

describe('sheet drag: letting go', () => {
	const height = 420;

	it('closes past a third of the sheet', () => {
		expect(closes({ offset: 141, height, velocity: 0, canClose: true })).toBe(true);
		expect(closes({ offset: 139, height, velocity: 0.1, canClose: true })).toBe(false);
	});

	it('closes on a quick flick down, not on a jitter', () => {
		expect(closes({ offset: 40, height, velocity: 0.8, canClose: true })).toBe(true);
		expect(closes({ offset: FLICK_MIN - 1, height, velocity: 2, canClose: true })).toBe(false);
		expect(closes({ offset: 60, height, velocity: -0.8, canClose: true })).toBe(false);
	});

	it('springs back when the sheet may not close or was pulled up', () => {
		expect(closes({ offset: 400, height, velocity: 2, canClose: false })).toBe(false);
		expect(closes({ offset: -RUBBER_MAX, height, velocity: 0, canClose: true })).toBe(false);
	});
});

describe('sheet drag: scrolled content', () => {
	const node = (scrollTop: number, parentElement: ScrollLike | null): ScrollLike => ({
		scrollTop,
		parentElement
	});

	it('is at the top only when nothing up to the sheet is scrolled', () => {
		const sheet = node(0, null);
		const list = node(0, sheet);
		const row = node(0, list);
		expect(scrolledToTop(row, sheet)).toBe(true);
		expect(scrolledToTop(node(0, node(48, sheet)), sheet)).toBe(false);
		expect(scrolledToTop(row, node(0, null))).toBe(true);
	});

	it('ignores scrolling outside the sheet', () => {
		const page = node(900, null);
		const sheet = node(0, page);
		expect(scrolledToTop(node(0, sheet), sheet)).toBe(true);
		expect(scrolledToTop(node(0, node(30, page)), page)).toBe(false);
	});
});
