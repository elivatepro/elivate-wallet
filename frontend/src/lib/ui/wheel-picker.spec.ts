// Blueprint 24: the wheel picker's search, keyboard and type-ahead rules.
import { describe, expect, it } from 'vitest';
import {
	filterOptions,
	keyTarget,
	normalise,
	rowAt,
	SEARCH_THRESHOLD,
	shouldSearch,
	startIndex,
	typeahead,
	type WheelOption
} from './wheel-picker.js';

const banks: WheelOption[] = [
	{ value: '044', label: 'Access Bank' },
	{ value: '063', label: 'Access Bank (Diamond)' },
	{ value: '050', label: 'Ecobank Nigeria' },
	{ value: '070', label: 'Fidelity Bank' },
	{ value: '011', label: 'First Bank of Nigeria' },
	{ value: '058', label: 'Guaranty Trust Bank' },
	{ value: '999', label: 'Stanbic IBTC Bank', hint: 'Lagos' },
	{ value: '033', label: 'United Bank For Africa' },
	{ value: '035', label: 'Wema Bank' }
];
const labels = (list: readonly WheelOption[]) => list.map((o) => o.label);

describe('search', () => {
	it('shows a search field for long lists only, unless told', () => {
		expect(shouldSearch('auto', SEARCH_THRESHOLD)).toBe(false);
		expect(shouldSearch('auto', SEARCH_THRESHOLD + 1)).toBe(true);
		expect(shouldSearch(true, 2)).toBe(true);
		expect(shouldSearch(false, 200)).toBe(false);
	});

	it('normalises case, accents and punctuation', () => {
		expect(normalise('  Ćafé–Ügo (Ltd.) ')).toBe('cafe ugo ltd');
	});

	it('shows everything for an empty or blank query', () => {
		expect(filterOptions(banks, '')).toBe(banks);
		expect(filterOptions(banks, '   ')).toBe(banks);
	});

	it('matches inside labels, ignoring case', () => {
		expect(labels(filterOptions(banks, 'TRUST'))).toEqual(['Guaranty Trust Bank']);
		expect(labels(filterOptions(banks, 'nigeria'))).toEqual([
			'Ecobank Nigeria',
			'First Bank of Nigeria'
		]);
	});

	it('puts labels that start with the query first, keeping order otherwise', () => {
		expect(labels(filterOptions(banks, 'bank')).slice(0, 3)).toEqual([
			'Access Bank',
			'Access Bank (Diamond)',
			'Ecobank Nigeria'
		]);
		const more = [...banks, { value: '001', label: 'Bank of Industry' }];
		expect(labels(filterOptions(more, 'bank')).slice(0, 2)).toEqual([
			'Bank of Industry',
			'Access Bank'
		]);
		expect(labels(filterOptions(banks, 'access'))).toEqual([
			'Access Bank',
			'Access Bank (Diamond)'
		]);
	});

	it('needs every word, in any order', () => {
		expect(labels(filterOptions(banks, 'bank first'))).toEqual(['First Bank of Nigeria']);
		expect(labels(filterOptions(banks, 'diamond access'))).toEqual(['Access Bank (Diamond)']);
	});

	it('matches the start of a hint word but not the middle of one', () => {
		expect(labels(filterOptions(banks, 'lag'))).toEqual(['Stanbic IBTC Bank']);
		expect(filterOptions(banks, 'agos')).toEqual([]);
	});

	it('returns nothing when nothing matches', () => {
		expect(filterOptions(banks, 'zenith')).toEqual([]);
	});
});

describe('start row', () => {
	const list: WheelOption[] = [
		{ value: 'a', label: 'A', disabled: true },
		{ value: 'b', label: 'B' },
		{ value: 'c', label: 'C' }
	];

	it('starts on the chosen value, else the initial one, else the first enabled row', () => {
		expect(startIndex(list, 'c')).toBe(2);
		expect(startIndex(list, null, 'c')).toBe(2);
		expect(startIndex(list, 'zz', 'zz')).toBe(1);
		expect(startIndex([], null)).toBe(0);
	});

	it('finds the empty value when it is a real option', () => {
		expect(
			startIndex(
				[
					{ value: 'x', label: 'X' },
					{ value: '', label: 'None' }
				],
				''
			)
		).toBe(1);
	});
});

describe('keyboard', () => {
	it('steps, pages and jumps within the list', () => {
		expect(keyTarget('ArrowDown', 0, 9)).toBe(1);
		expect(keyTarget('ArrowUp', 0, 9)).toBe(0);
		expect(keyTarget('ArrowDown', 8, 9)).toBe(8);
		expect(keyTarget('PageDown', 2, 9)).toBe(7);
		expect(keyTarget('PageDown', 6, 9)).toBe(8);
		expect(keyTarget('PageUp', 3, 9)).toBe(0);
		expect(keyTarget('Home', 5, 9)).toBe(0);
		expect(keyTarget('End', 0, 9)).toBe(8);
	});

	it('ignores other keys and empty lists', () => {
		expect(keyTarget('Enter', 2, 9)).toBeNull();
		expect(keyTarget('a', 2, 9)).toBeNull();
		expect(keyTarget('ArrowDown', 0, 0)).toBeNull();
	});

	it('type-ahead jumps to the next label with the letters typed', () => {
		expect(typeahead(banks, 'g', 0)).toBe(5);
		expect(typeahead(banks, 'fi', 0)).toBe(3);
		expect(typeahead(banks, 'fir', 3)).toBe(4);
		expect(typeahead(banks, 'q', 0)).toBeNull();
	});

	it('a repeated letter cycles through the rows with that letter, wrapping', () => {
		expect(typeahead(banks, 'a', 0)).toBe(1);
		expect(typeahead(banks, 'aa', 1)).toBe(0);
		expect(typeahead(banks, 'f', 3)).toBe(4);
		expect(typeahead(banks, 'f', 4)).toBe(3);
	});

	it('maps a scroll offset to the row under the lens', () => {
		expect(rowAt(0, 52, 9)).toBe(0);
		expect(rowAt(25, 52, 9)).toBe(0);
		expect(rowAt(27, 52, 9)).toBe(1);
		expect(rowAt(52 * 20, 52, 9)).toBe(8);
		expect(rowAt(-40, 52, 9)).toBe(0);
	});
});
