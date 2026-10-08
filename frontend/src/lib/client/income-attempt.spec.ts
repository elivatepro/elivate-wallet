import { describe, expect, it } from 'vitest';
import { MemoryStore } from './device-cache.js';
import {
	ATTEMPT_MAX_AGE_MS,
	clearAttempt,
	loadAttempt,
	saveAttempt,
	type IncomeAttempt
} from './income-attempt.js';

const alice = { uid: 'EW-10042', workspaceId: '6b0f8f3e-2a4c-4b8e-9d55-0c7a1d2e3f40' };
const bob = { uid: 'EW-10077', workspaceId: alice.workspaceId };
const now = Date.parse('2026-10-08T12:00:00Z');

const attempt: IncomeAttempt = {
	savedAt: now,
	target: { name: 'Adaeze Nwosu', uid: 'EW-48213', officeName: 'Lagos office' },
	request: {
		targetMembershipId: '9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d',
		currency: 'NGN',
		amount: '180000.00',
		source: 'Fiverr order',
		receivedOn: '2026-10-02',
		evidenceIds: ['1b0f8f3e-2a4c-4b8e-9d55-0c7a1d2e3f40'],
		idempotencyKey: 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'
	}
};

describe('income attempt store (F-03)', () => {
	it('keeps the attempt for the same person and workspace only', () => {
		const store = new MemoryStore();
		saveAttempt(store, alice, attempt);
		expect(loadAttempt(store, alice, now)).toEqual(attempt);
		expect(loadAttempt(store, bob, now)).toBeNull();
		clearAttempt(store, alice);
		expect(loadAttempt(store, alice, now)).toBeNull();
	});

	it('never stores a PIN, even if one is passed along', () => {
		const store = new MemoryStore();
		const withPin = { ...attempt, request: { ...attempt.request, pin: '1357' } } as IncomeAttempt;
		saveAttempt(store, alice, withPin);
		const raw = store
			.keys()
			.map((k) => store.getItem(k) ?? '')
			.join('');
		expect(raw).not.toContain('1357');
		expect(raw).not.toContain('"pin"');
	});

	it('drops attempts older than 24 h and unreadable ones', () => {
		const store = new MemoryStore();
		saveAttempt(store, alice, attempt);
		expect(loadAttempt(store, alice, now + ATTEMPT_MAX_AGE_MS + 1)).toBeNull();
		expect(store.keys()).toHaveLength(0);
		store.setItem(`ew:attempt:v1:income:${alice.uid}:${alice.workspaceId}`, '{"nope":1}');
		expect(loadAttempt(store, alice, now)).toBeNull();
		expect(store.keys()).toHaveLength(0);
	});

	it('reports when the device cannot keep the attempt', () => {
		const full = {
			getItem: () => null,
			setItem: () => {
				throw new Error('QuotaExceededError');
			},
			removeItem: () => {}
		};
		expect(saveAttempt(full, alice, attempt)).toBe(false);
		expect(saveAttempt(new MemoryStore(), alice, attempt)).toBe(true);
	});
});
