// Slice 28: unlock in place (Paper "PIN unlock v7", PU01–PU03). When the
// session owes its PIN again (15 minutes without a server call, B3), the app
// does not leave the page or say "no access": it locks where it is and asks
// for the PIN over a blurred outline of the page.
//
// The lock is enforced by the backend, not here: identity.require_session
// refuses every protected read and command until the PIN is verified, so
// removing the sheet in the browser gets nothing. What this module adds is that
// nothing readable stays behind while locked (owner decision 2026-10-11):
// - the page and the shell's data are unmounted (the layout renders an outline
//   with no names or amounts);
// - every saved device copy is deleted (the first page after unlocking reads
//   from the server);
// - other open tabs of this app lock too.

import { observeReplies } from '#lib/contract/transport.js';
import { browserStore, CACHE_KINDS, clearKinds } from './device-cache';

/** identity.pin_idle_timeout() (B3). */
export const PIN_IDLE_MS = 15 * 60 * 1000;
/** Checked a little after the server's limit, so the check itself never keeps a session alive. */
const IDLE_MARGIN_MS = 5_000;
const CHECK_EVERY_MS = 30_000;
/** Tells the app's other tabs to lock (value) or that the PIN was entered (removed). */
export const LOCK_KEY = 'ew:lock:v1';
/** When this browser last heard from the server (any tab), for opening the app later. */
export const LAST_REPLY_KEY = 'ew:last-reply:v1';
const LAST_REPLY_WRITE_MS = 10_000;

export class PinLock {
	locked = $state(false);
	/** Bumps on every unlock: the page mounts again and reads afresh. */
	generation = $state(0);
	#lastReply = Date.now();
	#lastWritten = 0;
	#active = false;

	/** The in-place lock is mounted (the /app shell); elsewhere gates still redirect. */
	get active(): boolean {
		return this.#active;
	}

	/**
	 * Before the app renders anything: if this browser last heard from the server
	 * longer ago than the PIN idle limit, the PIN is owed, so lock at once and
	 * no saved copy is ever shown. The session read then confirms (or unlocks).
	 */
	prime(): void {
		let raw: string | null;
		try {
			raw = localStorage.getItem(LAST_REPLY_KEY);
		} catch {
			return;
		}
		const last = raw === null ? null : Number(raw);
		if (last !== null && Number.isFinite(last) && Date.now() - last > PIN_IDLE_MS) {
			this.owe(false);
		}
	}

	/**
	 * Starts watching replies, idle time and other tabs. `check` asks the server
	 * for the session gate (the shell's session read), which locks if owed.
	 */
	start(check: () => void): () => void {
		this.#active = true;
		this.#lastReply = Date.now();
		const stopObserving = observeReplies({
			replied: () => {
				this.#lastReply = Date.now();
				this.#remember();
			},
			refused: (code) => {
				if (code === 'pin_required') this.owe();
			}
		});
		const idleCheck = () => {
			if (this.locked || document.visibilityState !== 'visible') return;
			if (Date.now() - this.#lastReply >= PIN_IDLE_MS + IDLE_MARGIN_MS) {
				this.#lastReply = Date.now(); // one check per idle period
				check();
			}
		};
		const onStorage = (event: StorageEvent) => {
			if (event.key !== LOCK_KEY) return;
			if (event.newValue !== null) this.owe(false);
			else if (this.locked) check(); // entered in another tab: confirm with the server
		};
		const timer = setInterval(idleCheck, CHECK_EVERY_MS);
		document.addEventListener('visibilitychange', idleCheck);
		window.addEventListener('storage', onStorage);
		return () => {
			this.#active = false;
			stopObserving();
			clearInterval(timer);
			document.removeEventListener('visibilitychange', idleCheck);
			window.removeEventListener('storage', onStorage);
		};
	}

	#remember(): void {
		if (this.#lastReply - this.#lastWritten < LAST_REPLY_WRITE_MS) return;
		this.#lastWritten = this.#lastReply;
		try {
			localStorage.setItem(LAST_REPLY_KEY, String(this.#lastReply));
		} catch {
			// best-effort
		}
	}

	/** The server says the PIN is owed: lock, forget saved copies, tell other tabs. */
	owe(broadcast = true): void {
		if (this.locked) return;
		this.locked = true;
		const store = browserStore();
		if (store) clearKinds(store, CACHE_KINDS);
		if (!broadcast) return;
		try {
			localStorage.setItem(LOCK_KEY, String(Date.now()));
		} catch {
			// best-effort: the other tabs lock on their next read anyway
		}
	}

	/** The server accepted the PIN (here or in another tab). */
	unlocked(): void {
		if (!this.locked) return;
		this.locked = false;
		this.generation += 1;
		this.#lastReply = Date.now();
		try {
			localStorage.removeItem(LOCK_KEY);
		} catch {
			// best-effort
		}
	}
}

export const pinLock = new PinLock();
