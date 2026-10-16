// Blueprint 43 (owner 2026-10-16): every bottom sheet closes with a drag down,
// the way its grabber suggests. Phones only (the sheet layout, under 1024 px);
// the desktop dialogs are unchanged.
// - A drag starts on the grabber or the sheet's header (`data-sheet-grab`), or
//   on the content when everything under the finger is scrolled to the top and
//   the finger moves down. Sideways moves, inner scrolling (the wheel), fields,
//   buttons and links are never taken over.
// - The sheet follows the finger (a small rubber band upwards). Let go past a
//   third of its height, or with a quick flick down, and it closes through the
//   sheet's own close (the Cancel / Escape path: state, focus return, onclose);
//   otherwise it springs back (a snap with reduced motion).
// - `canClose` is the sheet's Escape / backdrop rule: while it says no (busy,
//   posting) the sheet doesn't move at all.
// Keyboard and screen readers close the sheet as before (Escape, buttons).
//
// Usage: <div class="sheet" {@attach sheetDrag({ close, canClose: () => !busy })}>

import type { Attachment } from 'svelte/attachments';

/** Movement before a gesture is read as a drag, a scroll or a sideways move. */
export const SLOP = 6;
/** Let go past this share of the sheet's height and it closes. */
export const CLOSE_SHARE = 1 / 3;
/** A flick: px per ms downwards (0.5 = 500 px/s), over at least FLICK_MIN px. */
export const FLICK_SPEED = 0.5;
export const FLICK_MIN = 16;
/** Most the sheet rises above its place when pulled up. */
export const RUBBER_MAX = 12;
/** Velocity is read over the last stretch of the drag. */
const VELOCITY_WINDOW = 100;
const SPRING_MS = 200;
const EXIT_MS = 180;

/** Starting a drag here would take over a control (or the wheel's own scroll). */
export const NO_DRAG =
	'input, textarea, select, button, a[href], label, [contenteditable], [role="button"], [role="listbox"], [role="option"], [role="slider"], [role="switch"], [data-no-sheet-drag]';

export type Phase = 'wait' | 'drag' | 'native';

export interface Sample {
	readonly t: number;
	readonly y: number;
}

/** One finger (or mouse) on the sheet, from down to up. */
export interface Gesture {
	readonly x0: number;
	readonly y0: number;
	/** Started on the grabber or header: drags even if the content is scrolled. */
	readonly grab: boolean;
	/** Everything between the finger and the sheet is scrolled to the top. */
	readonly atTop: boolean;
	phase: Phase;
	samples: Sample[];
}

export function begin(
	x: number,
	y: number,
	t: number,
	where: { grab: boolean; atTop: boolean }
): Gesture {
	return { x0: x, y0: y, ...where, phase: 'wait', samples: [{ t, y }] };
}

/**
 * What a move means while the gesture is still undecided: keep waiting (inside
 * the slop), a drag of the sheet, or the browser's own (scroll, sideways,
 * upwards, a sheet that may not close now).
 */
export function decide(g: Gesture, x: number, y: number, canClose: boolean): Phase {
	if (g.phase !== 'wait') return g.phase;
	const dx = x - g.x0;
	const dy = y - g.y0;
	if (Math.hypot(dx, dy) < SLOP) return 'wait';
	if (!canClose) return 'native';
	if (dy <= 0 || Math.abs(dx) >= dy) return 'native';
	return g.grab || g.atTop ? 'drag' : 'native';
}

/** Where the sheet sits for a finger `dy` below where it started. */
export function follow(dy: number): number {
	return dy >= 0 ? dy : -Math.min(RUBBER_MAX, -dy / 4);
}

/** Remember a point (only the last VELOCITY_WINDOW ms are kept). */
export function track(g: Gesture, t: number, y: number): void {
	g.samples.push({ t, y });
	while (g.samples.length > 2 && t - g.samples[0]!.t > VELOCITY_WINDOW) g.samples.shift();
}

/** Downward speed at the end of the drag, px per ms. */
export function velocity(samples: readonly Sample[]): number {
	const first = samples[0];
	const last = samples[samples.length - 1];
	if (!first || !last || last.t <= first.t) return 0;
	return (last.y - first.y) / (last.t - first.t);
}

/** Let go: close (past a third, or a flick down) or spring back. */
export function closes(input: {
	offset: number;
	height: number;
	velocity: number;
	canClose: boolean;
}): boolean {
	if (!input.canClose || input.offset <= 0) return false;
	if (input.offset > input.height * CLOSE_SHARE) return true;
	return input.velocity >= FLICK_SPEED && input.offset >= FLICK_MIN;
}

/** The minimal shape `scrolledToTop` walks (testable without a DOM). */
export interface ScrollLike {
	readonly scrollTop: number;
	readonly parentElement: ScrollLike | null;
}

/** True when nothing from `from` up to `root` (inclusive) is scrolled down. */
export function scrolledToTop(from: ScrollLike | null, root: ScrollLike): boolean {
	for (let el = from; el; el = el.parentElement) {
		if (el.scrollTop > 1) return false;
		if (el === root) return true;
	}
	return true;
}

export interface SheetDragOptions {
	/** Close the sheet exactly as its Cancel / Escape does. */
	close: () => void;
	/** The sheet's Escape / backdrop rule (false while busy). Default: always. */
	canClose?: () => boolean;
	/** The sheet layout is on screen. Default: under 1024 px. */
	active?: () => boolean;
	/** The element that moves (default: the attached one). */
	panel?: (node: HTMLElement) => HTMLElement;
}

const phoneLayout = () => matchMedia('(max-width: 1023.98px)').matches;
const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;

export function sheetDrag(options: SheetDragOptions): Attachment<HTMLElement> {
	return (node) => {
		const canClose = () => options.canClose?.() ?? true;
		const active = options.active ?? phoneLayout;
		let g: Gesture | null = null;
		let pointer = -1;
		let panel: HTMLElement = node;
		let height = 0;
		let offset = 0;
		let closing = false;
		let timer: ReturnType<typeof setTimeout> | undefined;

		const place = (y: number, ms: number, easing = 'cubic-bezier(0.2, 0.8, 0.2, 1)') => {
			panel.style.transition = ms ? `translate ${ms}ms ${easing}` : 'none';
			panel.style.translate = y ? `0 ${y}px` : '';
		};
		const clear = () => {
			panel.style.transition = '';
			panel.style.translate = '';
			panel.style.willChange = '';
		};

		// After a drag the pointer's click lands on the sheet (a native dialog
		// reads a click on itself as the backdrop): swallow that one click.
		const swallow = (event: Event) => {
			event.preventDefault();
			event.stopPropagation();
		};
		const swallowNextClick = () => {
			window.addEventListener('click', swallow, { capture: true, once: true });
			setTimeout(() => window.removeEventListener('click', swallow, { capture: true }), 400);
		};

		function down(event: PointerEvent) {
			if (g || closing || !event.isPrimary || event.button !== 0 || !active()) return;
			const target = event.target instanceof Element ? event.target : null;
			if (!target || target.closest(NO_DRAG)) return;
			panel = options.panel?.(node) ?? node;
			// A native <dialog> is also hit on its backdrop: only the sheet counts.
			const box = panel.getBoundingClientRect();
			if (event.clientY < box.top || event.clientX < box.left || event.clientX > box.right) return;
			g = begin(event.clientX, event.clientY, event.timeStamp, {
				grab: !!target.closest('[data-sheet-grab]'),
				atTop: scrolledToTop(target, panel)
			});
			pointer = event.pointerId;
		}

		function move(event: PointerEvent) {
			if (!g || event.pointerId !== pointer) return;
			if (g.phase === 'wait') {
				g.phase = decide(g, event.clientX, event.clientY, canClose());
				if (g.phase === 'native') return end();
				if (g.phase === 'wait') return;
				clearTimeout(timer);
				height = panel.getBoundingClientRect().height;
				panel.style.willChange = 'translate';
				try {
					node.setPointerCapture(pointer);
				} catch {
					// the pointer is already gone
				}
			}
			event.preventDefault();
			track(g, event.timeStamp, event.clientY);
			offset = follow(event.clientY - g.y0);
			place(offset, 0);
		}

		function up(event: PointerEvent) {
			if (!g || event.pointerId !== pointer) return;
			const dragged = g.phase === 'drag';
			// The release point too: a drag that stopped before letting go is no flick.
			track(g, event.timeStamp, event.clientY);
			const speed = velocity(g.samples);
			end();
			if (!dragged) return;
			swallowNextClick();
			if (closes({ offset, height, velocity: speed, canClose: canClose() })) shut();
			else settle();
		}

		function cancel(event: PointerEvent) {
			if (!g || event.pointerId !== pointer) return;
			const dragged = g.phase === 'drag';
			end();
			if (dragged) settle();
		}

		function end() {
			if (node.hasPointerCapture?.(pointer)) node.releasePointerCapture(pointer);
			g = null;
			pointer = -1;
		}

		function settle() {
			if (reduced()) return clear();
			place(0, SPRING_MS);
			timer = setTimeout(clear, SPRING_MS + 20);
		}

		function shut() {
			closing = true;
			navigator.vibrate?.(8);
			const done = () => {
				closing = false;
				options.close();
				clear();
			};
			if (reduced()) return done();
			place(Math.max(offset, height), EXIT_MS, 'ease-in');
			timer = setTimeout(done, EXIT_MS);
		}

		// A touch moving down where a drag may start: stop the browser's own pan
		// (it would cancel the pointer) before it begins.
		function touchmove(event: TouchEvent) {
			if (!g) return;
			if (event.touches.length > 1) {
				const dragged = g.phase === 'drag';
				end();
				if (dragged) settle();
				return;
			}
			if (g.phase === 'drag') return event.preventDefault();
			if (g.phase !== 'wait' || !canClose()) return;
			const t = event.touches[0];
			if (!t) return;
			const dx = t.clientX - g.x0;
			const dy = t.clientY - g.y0;
			if (dy > 0 && dy >= Math.abs(dx) && (g.grab || g.atTop)) event.preventDefault();
		}

		node.addEventListener('pointerdown', down);
		node.addEventListener('pointermove', move);
		node.addEventListener('pointerup', up);
		node.addEventListener('pointercancel', cancel);
		node.addEventListener('touchmove', touchmove, { passive: false });
		return () => {
			clearTimeout(timer);
			node.removeEventListener('pointerdown', down);
			node.removeEventListener('pointermove', move);
			node.removeEventListener('pointerup', up);
			node.removeEventListener('pointercancel', cancel);
			node.removeEventListener('touchmove', touchmove);
			window.removeEventListener('click', swallow, { capture: true });
		};
	};
}
