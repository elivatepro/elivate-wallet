import { describe, expect, it } from 'vitest';
import { enterHint, enterOutcome, isStop, type FieldLike } from './enter-moves-on';

const field = (
	tagName: string,
	extra: { type?: string; disabled?: boolean; attrs?: Record<string, string> } = {}
): FieldLike => ({
	tagName,
	...(extra.type ? { type: extra.type } : {}),
	disabled: extra.disabled ?? false,
	getAttribute: (name) => extra.attrs?.[name] ?? null,
	hasAttribute: (name) => !!extra.attrs && name in extra.attrs
});

describe('Enter in a form (Slice 29)', () => {
	const member = field('BUTTON', { attrs: { 'aria-haspopup': 'dialog' } });
	const currency = field('BUTTON', { attrs: { role: 'combobox' } });
	const amount = field('INPUT', { type: 'text' });
	const source = field('INPUT', { type: 'text' });
	const date = field('INPUT', { type: 'date' });
	const notes = field('TEXTAREA');
	const income = [member, currency, amount, source, date, notes];

	it('counts typing fields and pickers, never action buttons or checkboxes', () => {
		expect(income.every(isStop)).toBe(true);
		expect(isStop(field('BUTTON', { type: 'submit' }))).toBe(false);
		expect(isStop(field('BUTTON'))).toBe(false);
		expect(isStop(field('INPUT', { type: 'checkbox' }))).toBe(false);
		expect(isStop(field('INPUT', { type: 'hidden' }))).toBe(false);
		expect(isStop(field('INPUT', { type: 'text', disabled: true }))).toBe(false);
	});

	it('the amount moves on instead of submitting Record income', () => {
		expect(enterOutcome(amount, income)).toBe('next');
		expect(enterHint(amount, income)).toBe('next');
		expect(enterOutcome(date, income)).toBe('next');
	});

	it('the only text field of a form closes the keyboard, it never submits', () => {
		const withdrawal = [field('INPUT', { type: 'text' })];
		expect(enterOutcome(withdrawal[0]!, withdrawal)).toBe('done');
		expect(enterHint(withdrawal[0]!, withdrawal)).toBe('done');
	});

	it('the PIN submits: it is the last step', () => {
		const email = field('INPUT', { type: 'email' });
		const pin = field('INPUT', { type: 'password', attrs: { 'data-enter-submits': '' } });
		const invite = [email, currency, pin];
		expect(enterOutcome(email, invite)).toBe('next');
		expect(enterOutcome(pin, invite)).toBe('submit');
		expect(enterHint(pin, invite)).toBe('go');
	});

	it('leaves text areas and buttons alone', () => {
		expect(enterOutcome(notes, income)).toBe('default');
		expect(enterOutcome(member, income)).toBe('default');
	});
});
