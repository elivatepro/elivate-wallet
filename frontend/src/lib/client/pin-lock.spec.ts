import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Effect, Exit, Schema } from 'effect';
import { requestJson } from '#lib/contract/transport.js';
import { LAST_REPLY_KEY, LOCK_KEY, PIN_IDLE_MS, PinLock } from './pin-lock.svelte';
import { SCOPE_KEY } from './device-cache';

/** A Storage-like map for window.localStorage. */
function storage() {
	const map = new Map<string, string>();
	return {
		map,
		get length() {
			return map.size;
		},
		key: (i: number) => [...map.keys()][i] ?? null,
		getItem: (k: string) => map.get(k) ?? null,
		setItem: (k: string, v: string) => void map.set(k, v),
		removeItem: (k: string) => void map.delete(k)
	};
}

let ls: ReturnType<typeof storage>;
let listeners: Record<string, ((event: unknown) => void)[]>;
beforeEach(() => {
	vi.useFakeTimers();
	ls = storage();
	listeners = {};
	const target = {
		addEventListener: (type: string, fn: (event: unknown) => void) =>
			(listeners[type] ??= []).push(fn),
		removeEventListener: (type: string, fn: (event: unknown) => void) => {
			listeners[type] = (listeners[type] ?? []).filter((f) => f !== fn);
		}
	};
	vi.stubGlobal('window', { ...target, localStorage: ls });
	vi.stubGlobal('localStorage', ls);
	vi.stubGlobal('document', { ...target, visibilityState: 'visible' });
});
afterEach(() => {
	vi.useRealTimers();
	vi.unstubAllGlobals();
});

const refusal = (code: string) =>
	Effect.runPromiseExit(
		requestJson(
			{
				fetch: async () =>
					new Response(
						JSON.stringify({
							ok: false,
							error: { code, message: 'No', retryable: false, details: {} },
							requestId: 'r1'
						}),
						{
							status: 403,
							headers: { 'content-type': 'application/json' }
						}
					),
				url: '/api/overview',
				method: 'GET',
				route: 'GET /api/overview',
				timeoutMs: 1000
			},
			Schema.Unknown
		)
	);

describe('PinLock (Slice 28)', () => {
	it('locks when any reply says the PIN is owed, and forgets every saved copy', async () => {
		ls.setItem('ew:cache:v1:EW-1:ws:balances', '{"data":1,"savedAt":1}');
		ls.setItem('ew:cache:v1:EW-1:ws:members', '{"data":1,"savedAt":1}');
		ls.setItem(SCOPE_KEY, '{"uid":"EW-1","workspaceId":"ws"}');
		const lock = new PinLock();
		const stop = lock.start(() => {});
		const exit = await refusal('pin_required');
		expect(Exit.isFailure(exit)).toBe(true);
		expect(lock.locked).toBe(true);
		expect([...ls.map.keys()].some((k) => k.startsWith('ew:cache:'))).toBe(false);
		// The scope stays: other tabs must not read the lock as a sign-out.
		expect(ls.getItem(SCOPE_KEY)).not.toBeNull();
		expect(ls.getItem(LOCK_KEY)).not.toBeNull();
		stop();
	});

	it('ignores other refusals', async () => {
		const lock = new PinLock();
		const stop = lock.start(() => {});
		await refusal('authorization_denied');
		await refusal('pin_incorrect');
		expect(lock.locked).toBe(false);
		stop();
	});

	it('unlocking remounts the page and tells the other tabs', () => {
		const lock = new PinLock();
		lock.owe();
		lock.unlocked();
		expect(lock.locked).toBe(false);
		expect(lock.generation).toBe(1);
		expect(ls.getItem(LOCK_KEY)).toBeNull();
	});

	it('another tab locking locks this one; its unlock asks the server', () => {
		const check = vi.fn();
		const lock = new PinLock();
		const stop = lock.start(check);
		for (const fn of listeners.storage ?? []) fn({ key: LOCK_KEY, newValue: '1' });
		expect(lock.locked).toBe(true);
		for (const fn of listeners.storage ?? []) fn({ key: LOCK_KEY, newValue: null });
		expect(check).toHaveBeenCalledTimes(1);
		stop();
	});

	it('asks the server only after the idle limit, so the check never keeps a session alive', () => {
		const check = vi.fn();
		const lock = new PinLock();
		const stop = lock.start(check);
		vi.advanceTimersByTime(PIN_IDLE_MS - 1000);
		expect(check).not.toHaveBeenCalled();
		vi.advanceTimersByTime(60_000);
		expect(check).toHaveBeenCalledTimes(1);
		stop();
	});

	it('opens locked, before any page shows a saved copy, when the browser was idle too long', () => {
		ls.setItem('ew:cache:v1:EW-1:ws:balances', '{"data":1,"savedAt":1}');
		ls.setItem(LAST_REPLY_KEY, String(Date.now() - PIN_IDLE_MS - 1000));
		const lock = new PinLock();
		lock.prime();
		expect(lock.locked).toBe(true);
		expect([...ls.map.keys()].some((k) => k.startsWith('ew:cache:'))).toBe(false);

		const fresh = new PinLock();
		ls.setItem(LAST_REPLY_KEY, String(Date.now() - 60_000));
		fresh.prime();
		expect(fresh.locked).toBe(false);
		ls.removeItem(LAST_REPLY_KEY);
		fresh.prime();
		expect(fresh.locked).toBe(false);
	});

	it('is inactive until started (gates elsewhere still redirect)', () => {
		const lock = new PinLock();
		expect(lock.active).toBe(false);
		const stop = lock.start(() => {});
		expect(lock.active).toBe(true);
		stop();
		expect(lock.active).toBe(false);
	});
});
