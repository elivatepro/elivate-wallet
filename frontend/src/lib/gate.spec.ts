import { describe, expect, it } from 'vitest';
import { GATE_PATHS, pathForGateCode, safeNext } from './gate.js';

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
});
