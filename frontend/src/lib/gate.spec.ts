import { describe, expect, it } from 'vitest';
import { GATE_PATHS, pathForGateCode, safeAppNext, safeNext, withNext } from './gate.js';

describe('gate routing', () => {
	it('maps every gate value and gate error code to a page', () => {
		expect(GATE_PATHS.pin_setup_required).toBe('/pin/setup');
		expect(pathForGateCode('pin_required')).toBe('/pin');
		expect(pathForGateCode('pin_locked')).toBe('/pin/locked');
		expect(pathForGateCode('account_blocked')).toBe('/blocked');
		expect(pathForGateCode('authentication_required')).toBe('/sign-in');
		expect(pathForGateCode('conflict')).toBeNull();
	});

	it('only follows same-origin relative `next` paths', () => {
		expect(safeNext('/app')).toBe('/app');
		expect(safeNext('//evil.example')).toBeNull();
		expect(safeNext('https://evil.example')).toBeNull();
		expect(safeNext('/\\evil.example')).toBeNull();
		expect(safeNext('')).toBeNull();
		expect(safeNext(null)).toBeNull();
	});

	it('returns only to pages of the signed-in app', () => {
		expect(safeAppNext('/app')).toBe('/app');
		expect(safeAppNext('/app/invitations')).toBe('/app/invitations');
		expect(safeAppNext('/app/activity?tx=1')).toBe('/app/activity?tx=1');
		expect(safeAppNext('/apply')).toBeNull();
		expect(safeAppNext('/admin')).toBeNull();
		expect(safeAppNext('/sign-out')).toBeNull();
		expect(safeAppNext('//evil.example/app')).toBeNull();
		expect(safeAppNext('/app\n/x')).toBeNull();
		expect(safeAppNext('/app/\u0000')).toBeNull();
		expect(safeAppNext(null)).toBeNull();
	});

	it('adds the next page to a gate path', () => {
		expect(withNext('/pin', '/app/invitations')).toBe('/pin?next=%2Fapp%2Finvitations');
		expect(withNext('/workspaces?switch', '/app/team')).toBe(
			'/workspaces?switch&next=%2Fapp%2Fteam'
		);
		expect(withNext('/pin', 'https://evil.example')).toBe('/pin');
		expect(withNext('/pin', null)).toBe('/pin');
	});
});
