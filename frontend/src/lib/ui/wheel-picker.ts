/**
 * Blueprint 24: the pure parts of the wheel picker (WheelPicker.svelte):
 * which options a search shows, where the keyboard moves the wheel, and
 * type-ahead. No DOM here, so it is unit tested in node.
 */

export type WheelOption = {
	readonly value: string;
	readonly label: string;
	/** A second, smaller line under the label (and after it on the trigger). */
	readonly hint?: string;
	readonly disabled?: boolean;
};

/** Lists longer than this get a search field ("auto"). */
export const SEARCH_THRESHOLD = 8;

export function shouldSearch(searchable: boolean | 'auto', count: number): boolean {
	return searchable === 'auto' ? count > SEARCH_THRESHOLD : searchable;
}

/** Lower case, accents dropped, runs of space and punctuation made one space. */
export function normalise(text: string): string {
	return text
		.normalize('NFD')
		.replace(/\p{M}/gu, '')
		.toLowerCase()
		.replace(/[^\p{L}\p{N}]+/gu, ' ')
		.trim();
}

/**
 * The options a search shows: every word typed must start a word of the label
 * or hint, or appear inside the label. Labels that start with the query come
 * first; otherwise the list keeps its order. An empty query shows everything.
 */
export function filterOptions<T extends WheelOption>(
	options: readonly T[],
	query: string
): readonly T[] {
	const q = normalise(query);
	if (!q) return options;
	const words = q.split(' ');
	const first: T[] = [];
	const rest: T[] = [];
	for (const option of options) {
		const label = normalise(option.label);
		const text = option.hint ? `${label} ${normalise(option.hint)}` : label;
		const starts = ` ${text}`;
		const hit = words.every((w) => label.includes(w) || starts.includes(` ${w}`));
		if (!hit) continue;
		(label.startsWith(q) ? first : rest).push(option);
	}
	return [...first, ...rest];
}

/** The row the wheel starts on: the chosen value, else `initial`, else the first enabled row. */
export function startIndex(
	options: readonly WheelOption[],
	value: string | null | undefined,
	initial?: string | null
): number {
	for (const wanted of [value, initial]) {
		if (wanted == null) continue;
		const i = options.findIndex((o) => o.value === wanted);
		if (i >= 0) return i;
	}
	return Math.max(
		0,
		options.findIndex((o) => !o.disabled)
	);
}

/** Rows moved by Page Up / Page Down (one wheel's height). */
export const PAGE = 5;

/**
 * Where a key moves the wheel from `current`, or null when the key doesn't
 * move it. Arrows step one row, Page keys five, Home and End jump to the ends.
 */
export function keyTarget(key: string, current: number, count: number): number | null {
	if (count <= 0) return null;
	const clamp = (n: number) => Math.min(count - 1, Math.max(0, n));
	switch (key) {
		case 'ArrowDown':
			return clamp(current + 1);
		case 'ArrowUp':
			return clamp(current - 1);
		case 'PageDown':
			return clamp(current + PAGE);
		case 'PageUp':
			return clamp(current - PAGE);
		case 'Home':
			return 0;
		case 'End':
			return count - 1;
		default:
			return null;
	}
}

/**
 * Type-ahead: the next row (after `current`, wrapping) whose label starts with
 * `typed`. A repeated single letter cycles through the rows with that letter.
 */
export function typeahead(
	options: readonly WheelOption[],
	typed: string,
	current: number
): number | null {
	const q = normalise(typed);
	if (!q || options.length === 0) return null;
	const single = [...q].every((c) => c === q[0]) ? q[0] : null;
	const wanted = single ?? q;
	// A word may match the current row; a (repeated) single letter moves on.
	const from = single ? current + 1 : current;
	for (let step = 0; step < options.length; step++) {
		const i = (from + step) % options.length;
		if (normalise(options[i]?.label ?? '').startsWith(wanted)) return i;
	}
	return null;
}

/** The row under the lens for a scroll offset (rows are `row` px tall). */
export function rowAt(scrollTop: number, row: number, count: number): number {
	if (count <= 0) return 0;
	return Math.min(count - 1, Math.max(0, Math.round(scrollTop / row)));
}
