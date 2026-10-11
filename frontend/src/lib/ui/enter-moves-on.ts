// Slice 29 (owner 2026-10-11: "the form tries to submit when I've not even
// gotten there yet"): in a form with several fields, Enter (and a phone
// keyboard's Go / Done / Next key, which send Enter) moves to the next field
// instead of submitting the whole form. On the last field it closes the
// keyboard. Only a field marked `data-enter-submits` (the PIN, the natural last
// step) still submits on Enter. The form's submit button is unchanged.
//
// Usage: <form {@attach enterMovesOn} ...>

/** Inputs whose Enter would submit the form (implicit submission). */
const TYPING = new Set([
	'text',
	'email',
	'search',
	'tel',
	'url',
	'number',
	'password',
	'date',
	'datetime-local',
	'month',
	'time',
	'week'
]);

/** The minimal shape of a form control this logic needs (testable without a DOM). */
export interface FieldLike {
	readonly tagName: string;
	readonly type?: string;
	readonly disabled?: boolean;
	readonly hidden?: boolean;
	getAttribute(name: string): string | null;
	hasAttribute(name: string): boolean;
}

/** A control a person fills in: a typing input, a text area, or a picker trigger. */
export function isStop(el: FieldLike): boolean {
	if (el.disabled || el.hidden) return false;
	const tag = el.tagName.toUpperCase();
	if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
	if (tag === 'INPUT') return TYPING.has((el.type ?? 'text').toLowerCase());
	if (tag === 'BUTTON') {
		// Picker triggers (the wheel, the member picker), never action buttons.
		return el.getAttribute('role') === 'combobox' || el.getAttribute('aria-haspopup') === 'dialog';
	}
	return false;
}

export type EnterOutcome = 'default' | 'submit' | 'next' | 'done';

/**
 * What Enter does in `target`, given the form's stops in order:
 * - `default`: not ours (text areas, buttons, other keys): leave it alone;
 * - `submit`: a field that submits on Enter (`data-enter-submits`);
 * - `next`: move to the following stop;
 * - `done`: the last stop: close the keyboard, don't submit.
 */
export function enterOutcome(target: FieldLike, stops: readonly FieldLike[]): EnterOutcome {
	if (target.tagName.toUpperCase() !== 'INPUT') return 'default';
	if (!TYPING.has((target.type ?? 'text').toLowerCase())) return 'default';
	if (target.hasAttribute('data-enter-submits')) return 'submit';
	const at = stops.indexOf(target);
	return at >= 0 && at < stops.length - 1 ? 'next' : 'done';
}

/** The keyboard's Enter label to match: "next" until the last stop. */
export function enterHint(target: FieldLike, stops: readonly FieldLike[]): 'next' | 'done' | 'go' {
	if (target.hasAttribute('data-enter-submits')) return 'go';
	const at = stops.indexOf(target);
	return at >= 0 && at < stops.length - 1 ? 'next' : 'done';
}

function stopsOf(form: HTMLFormElement): HTMLElement[] {
	return [...form.querySelectorAll<HTMLElement>('input, textarea, select, button')].filter(
		(el) =>
			// Inside a picker's own sheet (the wheel's search) the picker decides.
			!el.closest('[data-wheel-picker]') &&
			isStop(el as unknown as FieldLike) &&
			el.getClientRects().length > 0
	);
}

/** Svelte attachment for a <form>: see the file comment. */
export function enterMovesOn(form: HTMLFormElement): () => void {
	const onKeydown = (event: KeyboardEvent) => {
		if (event.key !== 'Enter' || event.isComposing) return;
		if (event.shiftKey || event.ctrlKey || event.metaKey || event.altKey) return;
		const target = event.target as HTMLElement;
		if (target.closest('[data-wheel-picker]')) return;
		const stops = stopsOf(form);
		const outcome = enterOutcome(target as unknown as FieldLike, stops as unknown as FieldLike[]);
		if (outcome === 'default' || outcome === 'submit') return;
		event.preventDefault();
		if (outcome === 'next') stops[stops.indexOf(target) + 1]?.focus();
		else target.blur();
	};
	const onFocusin = (event: FocusEvent) => {
		const target = event.target as HTMLElement;
		if (!(target instanceof HTMLInputElement) || target.closest('[data-wheel-picker]')) return;
		const stops = stopsOf(form);
		target.enterKeyHint = enterHint(
			target as unknown as FieldLike,
			stops as unknown as FieldLike[]
		);
	};
	form.addEventListener('keydown', onKeydown);
	form.addEventListener('focusin', onFocusin);
	return () => {
		form.removeEventListener('keydown', onKeydown);
		form.removeEventListener('focusin', onFocusin);
	};
}
