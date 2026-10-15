// Blueprint 41: the tapped element answers a slow navigation. A link or
// button whose navigation is still running after PENDING_DELAY_MS gets a
// small spinner (accent colour) until the navigation completes or is
// cancelled. The spinner takes the place of the element's marked icon
// (`data-pending-slot`, else a trailing chevron) or sits at its trailing edge.
// One listener for the whole site (root layout): app, sign-in and admin.

import { plainClick } from '#lib/nav.js';

/** Fast navigations never show a spinner. */
export const PENDING_DELAY_MS = 150;
/** A navigation this soon after a tap is the tap's (goto after a click). */
export const TAP_WINDOW_MS = 1000;

/** What a tap may start a navigation from. */
const TAPPABLE = 'a[href], button, [role="button"], [role="option"], [role="tab"]';
/** The icon the spinner replaces, when the element marks none. */
const SLOT = '[data-pending-slot], .chev, .lucide-chevron-right';
const SIZE = 16;

/** Is this tap still the likely cause of a navigation starting at `now`? */
export const tapStarted = (tappedAt: number, now: number) =>
	now >= tappedAt && now - tappedAt <= TAP_WINDOW_MS;

/** Where the spinner sits inside its host: the slot's centre, else the trailing edge. */
export function spinnerBox(
	host: {
		readonly left: number;
		readonly top: number;
		readonly width: number;
		readonly height: number;
	},
	slot: {
		readonly left: number;
		readonly top: number;
		readonly width: number;
		readonly height: number;
	} | null,
	size: number = SIZE
): { left: number; top: number } {
	if (slot && slot.width > 0 && slot.height > 0) {
		return {
			left: Math.round(slot.left - host.left + (slot.width - size) / 2),
			top: Math.round(slot.top - host.top + (slot.height - size) / 2)
		};
	}
	const inset = Math.min(14, Math.max(4, (host.height - size) / 2));
	return {
		left: Math.round(Math.max(0, host.width - size - inset)),
		top: Math.round((host.height - size) / 2)
	};
}

let tapped: { element: HTMLElement; at: number } | null = null;
let marked: {
	element: HTMLElement;
	host: HTMLElement;
	spinner: HTMLElement;
	slot: Element | null;
	position: string;
} | null = null;

function onTap(event: MouseEvent) {
	if (!plainClick(event) || !(event.target instanceof Element)) return;
	const element = event.target.closest<HTMLElement>(TAPPABLE);
	if (!element) return;
	if (element instanceof HTMLAnchorElement && (element.target || element.hasAttribute('download')))
		return;
	tapped = { element, at: performance.now() };
}

/** Listens for taps (capture, so a page's own handlers can't hide them). */
export function listenForTaps(): () => void {
	document.addEventListener('click', onTap, true);
	return () => {
		document.removeEventListener('click', onTap, true);
		clear();
	};
}

function mark(element: HTMLElement) {
	// A command that already shows its own progress keeps it.
	if (element.getAttribute('aria-busy') === 'true' || element.matches(':disabled')) return;
	clear();
	const slot = element.querySelector(SLOT);
	const spinner = document.createElement('span');
	spinner.className = 'ew-pending';
	spinner.setAttribute('aria-hidden', 'true');
	// An element slot holds the spinner itself (centred, whatever its layout
	// does next); an icon slot (an svg) is hidden and the spinner placed over it.
	const host = slot instanceof HTMLElement ? slot : element;
	if (slot instanceof HTMLElement) {
		spinner.classList.add('centred');
		slot.setAttribute('data-pending-in', '');
	} else {
		const box = spinnerBox(
			element.getBoundingClientRect(),
			slot ? slot.getBoundingClientRect() : null
		);
		spinner.style.left = `${box.left}px`;
		spinner.style.top = `${box.top}px`;
		slot?.setAttribute('data-pending-hidden', '');
	}
	const position = host.style.position;
	if (getComputedStyle(host).position === 'static') host.style.position = 'relative';
	element.dataset.pending = '';
	host.append(spinner);
	marked = { element, host, spinner, slot, position };
}

function clear() {
	if (!marked) return;
	const { element, host, spinner, slot, position } = marked;
	marked = null;
	spinner.remove();
	slot?.removeAttribute('data-pending-hidden');
	slot?.removeAttribute('data-pending-in');
	delete element.dataset.pending;
	host.style.position = position;
}

/**
 * A navigation started (call when `navigating.to` appears), or a read a tap
 * started on the same page (e.g. Activity's transaction detail). The element that
 * was just tapped shows the spinner if the navigation is still running after
 * PENDING_DELAY_MS. The returned function ends it (completed or cancelled).
 */
export function navigationStarted(): () => void {
	const tap = tapped;
	if (!tap || !tapStarted(tap.at, performance.now())) return () => undefined;
	let mine: typeof marked = null;
	const timer = setTimeout(() => {
		if (!tap.element.isConnected) return;
		mark(tap.element);
		mine = marked;
	}, PENDING_DELAY_MS);
	return () => {
		clearTimeout(timer);
		// Only its own spinner: a later tap's feedback stays.
		if (mine && marked === mine) clear();
	};
}
