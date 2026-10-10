import { describe, expect, it } from 'vitest';
import { formatPhone, readApplication } from './founders';

const form = (values: Record<string, string>) => {
	const data = new FormData();
	for (const [k, v] of Object.entries(values)) data.set(k, v);
	return data;
};

const good = {
	fullName: '  Adaeze   Okafor ',
	email: ' Adaeze@Example.TEST ',
	phone: '0803 555 0142',
	teamName: 'Harmony Builders',
	rank: 'ruby_director_4'
};

describe('readApplication', () => {
	it('cleans the form exactly like the database will', () => {
		const parsed = readApplication(form(good));
		expect(parsed.ok).toBe(true);
		if (!parsed.ok) return;
		expect(parsed.request).toEqual({
			fullName: 'Adaeze Okafor',
			email: 'adaeze@example.test',
			phone: '08035550142',
			teamName: 'Harmony Builders',
			rank: 'ruby_director_4'
		});
		// The form shows back what was typed (squashed), not the stripped phone.
		expect(parsed.values.phone).toBe('0803 555 0142');
	});

	it('accepts +234 numbers with spaces and dashes', () => {
		const parsed = readApplication(form({ ...good, phone: '+234 803-555-0142' }));
		expect(parsed.ok && parsed.request.phone).toBe('+2348035550142');
	});

	it('names every bad field', () => {
		const parsed = readApplication(
			form({
				fullName: 'A',
				email: 'nope',
				phone: 'call me',
				teamName: 'X',
				rank: 'ruby_director_3'
			})
		);
		expect(parsed.ok).toBe(false);
		if (parsed.ok) return;
		expect(Object.keys(parsed.errors).sort()).toEqual(
			['email', 'fullName', 'phone', 'rank', 'teamName'].sort()
		);
	});
});

describe('formatPhone', () => {
	it('groups Nigerian numbers and leaves others alone', () => {
		expect(formatPhone('08035550142')).toBe('0803 555 0142');
		expect(formatPhone('+2348035550142')).toBe('+234 803 555 0142');
		expect(formatPhone('+447700900123')).toBe('+447700900123');
	});
});
