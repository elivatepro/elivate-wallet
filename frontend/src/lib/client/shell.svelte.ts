// Signed-in shell state (decision 36/36a, W-00/W-25). One of: loading, ready
// (live), offline (showing labelled device-cache data, or nothing), or error.
// Commands are never queued: `canAct` is false whenever the shell is offline.

import { Cause, Effect, Exit, Option } from 'effect';
import type { SessionView } from '#lib/contract/app.js';
import type { Workspace } from '#lib/contract/org.js';
import type { Theme } from '#lib/contract/settings.js';
import type { ApiFailure } from '#lib/contract/errors.js';
import { GATE_PATHS, pathForGateCode, SIGN_IN_PATH } from '#lib/gate.js';
import { sweepAttempts } from '#lib/recovery.js';
import { loadSession } from './api';
import {
	browserStore,
	lastScope,
	readCache,
	rememberScope,
	SCOPE_KEY,
	sweepExpired,
	writeCache,
	type CacheScope
} from './device-cache';

/** The cached workspace label: no ids beyond the scope, no money, no secrets. */
export interface WorkspaceSummary {
	readonly tenantName: string;
	readonly officeName: string | null;
	readonly role: Workspace['role'];
	/** Blueprint 17: the team theme, so an offline shell keeps the network's look. */
	readonly theme?: Theme;
}

export type ShellState =
	| { readonly kind: 'loading' }
	| {
			readonly kind: 'ready';
			readonly view: SessionView & { workspace: Workspace };
			readonly summary: WorkspaceSummary;
			readonly loadedAt: number;
	  }
	| {
			readonly kind: 'offline';
			readonly summary: WorkspaceSummary | null;
			readonly savedAt: number | null;
	  }
	| { readonly kind: 'error'; readonly message: string; readonly reference: string | null };

const HIDE_AMOUNTS_KEY = 'ew:pref:hide-amounts';

export class Shell {
	state: ShellState = $state({ kind: 'loading' });
	online = $state(true);
	hideAmounts = $state(false);
	/** Blueprint 18: operations Elivate has stopped (kill switches), read on write pages. */
	stopped = $state<readonly string[]>([]);
	#controller: AbortController | null = null;

	get canAct(): boolean {
		return this.online && this.state.kind === 'ready';
	}

	/** A stopped operation: new submissions are off; recovery of open attempts is not. */
	paused(operation: string): boolean {
		return this.stopped.includes(operation);
	}

	start(): () => void {
		this.online = navigator.onLine;
		try {
			this.hideAmounts = localStorage.getItem(HIDE_AMOUNTS_KEY) === '1';
		} catch {
			this.hideAmounts = false; // storage blocked: keep the default
		}
		const store = browserStore();
		if (store) {
			sweepExpired(store);
			sweepAttempts(store);
		}
		const onOnline = () => {
			this.online = true;
			void this.load();
		};
		const onOffline = () => {
			this.online = false;
			this.#showOffline();
		};
		// Sign-out in another tab erases the remembered scope; this tab must not
		// keep showing that person's workspace (36a).
		const onStorage = (event: StorageEvent) => {
			if (event.key === null || (event.key === SCOPE_KEY && event.newValue === null)) {
				this.state = { kind: 'loading' };
				go(SIGN_IN_PATH);
			}
		};
		window.addEventListener('online', onOnline);
		window.addEventListener('offline', onOffline);
		window.addEventListener('storage', onStorage);
		void this.load();
		return () => {
			this.#controller?.abort();
			window.removeEventListener('online', onOnline);
			window.removeEventListener('offline', onOffline);
			window.removeEventListener('storage', onStorage);
		};
	}

	setHideAmounts(value: boolean): void {
		this.hideAmounts = value;
		try {
			localStorage.setItem(HIDE_AMOUNTS_KEY, value ? '1' : '0');
		} catch {
			// preference is best-effort
		}
	}

	async load(): Promise<void> {
		this.#controller?.abort();
		const controller = new AbortController();
		this.#controller = controller;
		if (this.state.kind !== 'ready') this.state = { kind: 'loading' };

		const exit = await Effect.runPromiseExit(loadSession(fetch, controller.signal));
		if (controller.signal.aborted) return; // a newer load or a workspace switch won

		if (Exit.isSuccess(exit)) return this.#onView(exit.value);
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		if (failure) return this.#onFailure(failure);
		this.state = { kind: 'error', message: 'Something went wrong. Try again.', reference: null };
	}

	#onView(view: SessionView): void {
		if (view.state.gate !== 'ready') return go(GATE_PATHS[view.state.gate]);
		if (!view.workspace) return go('/workspaces');
		const workspace = view.workspace;
		const summary: WorkspaceSummary = {
			tenantName: workspace.tenantName,
			officeName: workspace.officeName,
			role: workspace.role,
			...(view.brand ? { theme: view.brand.theme } : {})
		};
		const scope: CacheScope = { uid: view.state.uid, workspaceId: workspace.membershipId };
		const store = browserStore();
		if (store) {
			rememberScope(store, scope);
			writeCache(store, scope, 'workspace', summary);
		}
		this.online = true;
		this.state = { kind: 'ready', view: { ...view, workspace }, summary, loadedAt: Date.now() };
	}

	#onFailure(failure: ApiFailure): void {
		if (failure._tag === 'TransportError' && failure.reason === 'aborted') return;
		if (failure._tag === 'TransportError' && failure.status === 401) return go(SIGN_IN_PATH);
		if (failure._tag === 'TransportError' && (failure.reason === 'network' || !navigator.onLine)) {
			this.online = false;
			return this.#showOffline();
		}
		if (failure._tag === 'BackendError') {
			const path = pathForGateCode(failure.code);
			if (path) return go(path);
			if (failure.code === 'workspace_invalid') return go('/workspaces?switch');
			this.state = { kind: 'error', message: failure.message, reference: failure.requestId };
			return;
		}
		this.state = { kind: 'error', message: 'Something went wrong. Try again.', reference: null };
	}

	#showOffline(): void {
		if (this.state.kind === 'ready') {
			// Keep what is on screen; it is now labelled stale by the banner.
			this.state = { kind: 'offline', summary: this.state.summary, savedAt: this.state.loadedAt };
			return;
		}
		const store = browserStore();
		const scope = store ? lastScope(store) : null;
		const cached = store && scope ? readCache<WorkspaceSummary>(store, scope, 'workspace') : null;
		this.state = {
			kind: 'offline',
			summary: cached?.data ?? null,
			savedAt: cached?.savedAt ?? null
		};
	}
}

function go(path: string): void {
	window.location.assign(path);
}
