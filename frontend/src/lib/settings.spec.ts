import { describe, expect, it } from 'vitest';
import type { Revision, TeamSettings } from '#lib/contract/settings.js';
import {
	buildPatch,
	checkForm,
	formOf,
	formatBytes,
	normalizePhone,
	revisionTitle,
	shortChecksum
} from './settings';

const saved: TeamSettings = {
	revision: 4,
	name: 'Cedar Network',
	shortName: 'CDR',
	theme: 'ember',
	slogan: 'Grow together',
	supportName: null,
	supportEmail: 'help@cedar.example',
	supportPhone: null,
	helpUrl: null,
	locale: 'en-NG',
	timeZone: 'Africa/Lagos',
	hasLogo: false,
	hasIcon: false,
	hasLogoLight: false,
	updatedAt: '2026-10-05T10:40:00Z'
};

describe('buildPatch', () => {
	it('sends only what changed', () => {
		expect(buildPatch(saved, formOf(saved))).toEqual({});
		expect(
			buildPatch(saved, { ...formOf(saved), theme: 'cobalt', slogan: ' Grow together ' })
		).toEqual({ theme: 'cobalt' });
	});
	it('clears optional text and keeps uploads', () => {
		expect(
			buildPatch(saved, { ...formOf(saved), supportEmail: '  ' }, { logoKey: 'brand/a/b.png' })
		).toEqual({ supportEmail: null, logoKey: 'brand/a/b.png' });
	});
});

describe('checkForm', () => {
	it('repeats the database limits', () => {
		const form = formOf(saved);
		expect(checkForm(form)).toEqual({});
		expect(checkForm({ ...form, name: 'C' }).name).toBeDefined();
		expect(checkForm({ ...form, slogan: 'x'.repeat(61) }).slogan).toBeDefined();
		expect(checkForm({ ...form, supportEmail: 'nope' }).supportEmail).toBeDefined();
		expect(checkForm({ ...form, helpUrl: 'http://help.example' }).helpUrl).toBeDefined();
		expect(checkForm({ ...form, helpUrl: 'https://u:p@help.example' }).helpUrl).toBeDefined();
		expect(checkForm({ ...form, helpUrl: 'https://help.example/start' }).helpUrl).toBeUndefined();
		expect(checkForm({ ...form, supportPhone: '12' }).supportPhone).toBeDefined();
	});
});

describe('normalizePhone', () => {
	it('stores Nigerian numbers in full', () => {
		expect(normalizePhone('0801 234 2210')).toBe('+2348012342210');
		expect(normalizePhone('+234 (801) 234-2210')).toBe('+2348012342210');
		expect(normalizePhone('')).toBe('');
		expect(normalizePhone('abc')).toBeNull();
	});
});

describe('labels', () => {
	const rev = (changed: Revision['changed'], restoredFrom: number | null = null): Revision => ({
		revision: 12,
		changed,
		restoredFrom,
		actor: null,
		createdAt: '2026-10-03T09:00:00Z'
	});
	it('names a revision like Paper F02', () => {
		expect(revisionTitle(rev(['slogan']))).toBe('Slogan updated');
		expect(revisionTitle(rev(['supportPhone']))).toBe('Support phone changed');
		expect(revisionTitle(rev(['logoKey']))).toBe('New logo uploaded');
		expect(revisionTitle(rev(['theme', 'slogan']))).toBe('Theme changed + 1 more');
		expect(revisionTitle(rev([], 3))).toBe('Restored revision 3');
		expect(revisionTitle(rev([]))).toBe('Network created');
	});
	it('formats sizes and checksums', () => {
		expect(formatBytes(38 * 1024 * 1024)).toBe('38 MB');
		expect(formatBytes(1536)).toBe('1.5 kB');
		expect(formatBytes(null)).toBe('—');
		expect(shortChecksum('9f4c' + 'a'.repeat(56) + 'a1e7')).toBe('sha256 · 9f4c…a1e7');
		expect(shortChecksum(null)).toBe('—');
	});
});
