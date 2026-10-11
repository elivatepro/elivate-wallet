import { describe, expect, it } from 'vitest';
import { pickedUid, pickerQuery } from './person-picker';

describe('pickerQuery', () => {
	it('needs two characters', () => {
		expect(pickerQuery(' f ')).toBe('short');
		expect(pickerQuery('fe')).toBe('name');
	});
	it('tells UIDs, emails and names apart', () => {
		expect(pickerQuery('ew-48213')).toBe('uid');
		expect(pickerQuery('EW-1')).toBe('name');
		expect(pickerQuery('tayo@')).toBe('email');
		expect(pickerQuery('Femi Adeyemi')).toBe('name');
	});
});

it('pickedUid: only a person carries a UID', () => {
	expect(pickedUid({ kind: 'person', uid: 'EW-48213', name: 'Femi' })).toBe('EW-48213');
	expect(pickedUid({ kind: 'invite', email: 'a@b.co' })).toBeNull();
	expect(pickedUid(null)).toBeNull();
});
