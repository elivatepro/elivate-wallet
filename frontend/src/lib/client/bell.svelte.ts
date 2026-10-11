// The bell's browser state (Blueprint 13): the unread badge, polled every
// minute and on focus while the shell is live, and the list for the popover
// (desktop) and the Notifications page (mobile). Reading never queues work
// offline; marking read is idempotent, so a failed mark is simply retried
// by the next tap.

import { Effect, Exit, Schedule, type Schema } from 'effect';
import {
	BellRoutes,
	MarkedRead,
	NotificationPage,
	UnreadCount,
	type NotificationItem,
	type NotificationView
} from '#lib/contract/notifications.js';
import { isRetryableRead, type ApiFailure } from '#lib/contract/errors.js';
import { READ_TIMEOUT_MS, requestJson } from '#lib/contract/transport.js';
import { sendCommand } from './api';
import type { CacheScope } from './device-cache';
import { CachedRead, onInvalidate } from './page-cache.svelte';
import { countTasks, type TaskCounts } from '#lib/nav.js';

const POLL_MS = 60_000;

/**
 * A bell read for the workspace this tab shows: the server refuses it when
 * another tab switched workspace, so a stale tab never shows another
 * network's items or count.
 */
function read<S extends Schema.ConstraintDecoder<unknown>>(
	path: string,
	workspace: string,
	schema: S,
	/** Slice 34: a silent poll (count, tasks); list loads show their errors. */
	background = false
) {
	return requestJson(
		{
			fetch,
			url: path,
			method: 'GET',
			route: `GET ${path.split('?')[0]}`,
			headers: { 'x-ew-workspace': workspace },
			timeoutMs: READ_TIMEOUT_MS,
			background
		},
		schema
	).pipe(
		Effect.retry({
			times: 2,
			while: (e: ApiFailure) =>
				isRetryableRead(e) && !(e._tag === 'TransportError' && e.reason === 'network'),
			schedule: Schedule.exponential('300 millis').pipe(Schedule.jittered)
		})
	);
}

export type BellList =
	| { readonly kind: 'idle' }
	| { readonly kind: 'loading' }
	| { readonly kind: 'error' }
	| {
			readonly kind: 'ready';
			readonly actions: readonly NotificationItem[];
			readonly items: readonly NotificationItem[];
			readonly nextCursor: string | null;
	  };

export class Bell {
	unread = $state(0);
	/**
	 * Blueprint 25: live "needs your action" tasks by kind, for the Approvals
	 * badges and Home's "Needs your action". Null before the first read.
	 */
	tasks: TaskCounts | null = $state(null);
	/**
	 * Blueprint 25: read the tasks on every poll and focus (a task another
	 * leader finished changes no unread count here). Set for people who approve.
	 */
	watchTasks = $state(false);
	view: NotificationView = $state('unread');
	list: BellList = $state({ kind: 'idle' });
	more = $state(false);
	/** Blueprint 23: when the shown list was saved; null once fresh (or nothing cached). */
	savedAt: number | null = $state(null);
	/** Blueprint 23: the refresh failed while a saved list is shown. */
	failed = $state(false);
	#workspace: () => string | null;
	#scope: () => CacheScope | null;
	#confirmed: CacheScope | null = null;
	#generation = 0;
	#marking = false;
	// Blueprint 23: the first page of each view, cached as kind 'notifications'
	// with part 'unread' or 'all' (safe display params only, Blueprint 13).
	readonly #reads: Record<NotificationView, CachedRead<NotificationPage>> = {
		unread: new CachedRead<NotificationPage>('notifications', 'unread'),
		all: new CachedRead<NotificationPage>('notifications', 'all')
	};

	/**
	 * `scope` (optional) is the shell's confirmed user and workspace; without
	 * it a fresh list is kept once a page calls `confirm`.
	 */
	constructor(workspace: () => string | null, scope: () => CacheScope | null = () => null) {
		this.#workspace = workspace;
		this.#scope = scope;
	}

	/** Blueprint 23: the session named the scope: keep or drop the cached lists. */
	confirm(scope: CacheScope): void {
		this.#confirmed = scope;
		for (const view of ['unread', 'all'] as const) this.#reads[view].confirm(scope);
		// The saved list shown belonged to another person or workspace: hide it.
		if (this.savedAt !== null && this.#reads[this.view].data === null) {
			this.savedAt = null;
			this.list = { kind: 'loading' };
		}
	}

	/**
	 * Blueprint 23: shows the saved first page of `view` before the workspace
	 * is known (the read itself waits for it). Nothing happens when a list is
	 * already shown or nothing is saved.
	 */
	preview(view: NotificationView): void {
		if (this.list.kind === 'ready') return;
		const cache = this.#reads[view];
		if (!cache.show() || !cache.data) return;
		this.view = view;
		this.#show(cache.data);
		this.savedAt = cache.savedAt;
	}

	/** Polls the badge and follows the cached lists; returns the stop function. */
	start(): () => void {
		const unwatch = (['unread', 'all'] as const).map((view) =>
			// Blueprint 23: a command cleared the cache, or the saved copy belonged
			// to another person or workspace: read the shown view again.
			this.#reads[view].watch(() => {
				if (this.#marking || this.view !== view) return;
				if (this.#reads[view].data === null && this.savedAt !== null) {
					this.savedAt = null;
					this.list = { kind: 'loading' };
				}
				void this.load(view);
			})
		);
		const tick = () => {
			if (document.visibilityState === 'visible' && navigator.onLine) void this.refreshCount();
		};
		// Blueprint 25: an approval, a new request or a review changes the tasks.
		const stopTasks = onInvalidate(['queue', 'transfers', 'evidence', 'nin-reviews'], () => {
			void this.refreshTasks();
		});
		const timer = setInterval(tick, POLL_MS);
		window.addEventListener('focus', tick);
		document.addEventListener('visibilitychange', tick);
		tick();
		return () => {
			clearInterval(timer);
			window.removeEventListener('focus', tick);
			document.removeEventListener('visibilitychange', tick);
			for (const stop of unwatch) stop();
			stopTasks();
		};
	}

	async refreshCount(): Promise<void> {
		const workspace = this.#workspace();
		if (!workspace) return;
		const exit = await Effect.runPromiseExit(read(BellRoutes.unread, workspace, UnreadCount, true));
		if (!Exit.isSuccess(exit)) return;
		const changed = exit.value.unread !== this.unread;
		this.unread = exit.value.unread;
		// A new task always arrives as an unread item; read the tasks again then.
		if (changed || this.tasks === null || this.watchTasks) void this.refreshTasks();
	}

	/**
	 * Blueprint 25: the open tasks only (they come first on the bell's first
	 * page, whatever the limit).
	 */
	async refreshTasks(): Promise<void> {
		const workspace = this.#workspace();
		if (!workspace) return;
		const exit = await Effect.runPromiseExit(
			read(`${BellRoutes.list}?view=unread&limit=1`, workspace, NotificationPage, true)
		);
		if (Exit.isSuccess(exit) && this.#workspace() === workspace) {
			this.tasks = countTasks(exit.value.actions);
		}
	}

	async load(view: NotificationView = this.view): Promise<void> {
		const switched = view !== this.view;
		this.view = view;
		const workspace = this.#workspace();
		if (!workspace) return;
		const generation = ++this.#generation;
		const cache = this.#reads[view];
		this.failed = false;
		// Blueprint 23: the saved first page of this view at once, then the fresh one.
		if ((this.list.kind !== 'ready' || switched) && cache.show() && cache.data) {
			this.#show(cache.data);
			this.savedAt = cache.savedAt;
		} else {
			if (switched) this.savedAt = null;
			if (this.list.kind !== 'ready') this.list = { kind: 'loading' };
		}
		const ticket = cache.begin();
		const exit = await Effect.runPromiseExit(
			read(`${BellRoutes.list}?view=${view}&limit=20`, workspace, NotificationPage)
		);
		if (generation !== this.#generation) return; // a newer load won
		if (Exit.isFailure(exit)) {
			// A saved list stays on screen; the page says when it was saved.
			if (this.savedAt !== null && this.list.kind === 'ready') this.failed = true;
			else this.list = { kind: 'error' };
			return;
		}
		const page = exit.value;
		if (!cache.fresh(page, this.#scopeFor(workspace), ticket)) {
			// Another tab switched person or workspace while this ran.
			this.savedAt = null;
			this.list = { kind: 'loading' };
			return;
		}
		this.savedAt = null;
		this.failed = false;
		this.unread = page.unread;
		this.#show(page);
	}

	async loadMore(): Promise<void> {
		const list = this.list;
		const workspace = this.#workspace();
		if (list.kind !== 'ready' || !list.nextCursor || this.more || !workspace) return;
		this.more = true;
		const exit = await Effect.runPromiseExit(
			read(
				`${BellRoutes.list}?view=${this.view}&limit=20&cursor=${encodeURIComponent(list.nextCursor)}`,
				workspace,
				NotificationPage
			)
		);
		this.more = false;
		if (Exit.isFailure(exit) || this.list !== list) return;
		this.list = {
			...list,
			items: [...list.items, ...exit.value.items],
			nextCursor: exit.value.nextCursor
		};
	}

	/** Marks one item read (before following its link). */
	async markRead(item: NotificationItem): Promise<void> {
		if (item.read) return;
		if (!(await this.#mark({ ids: [item.id] }))) return;
		const list = this.list;
		if (list.kind === 'ready') {
			const read = (i: NotificationItem) => (i.id === item.id ? { ...i, read: true } : i);
			this.list = { ...list, actions: list.actions.map(read), items: list.items.map(read) };
		}
	}

	async markAll(): Promise<void> {
		if (await this.#mark({ all: true })) await this.load();
	}

	#show(page: NotificationPage): void {
		this.tasks = countTasks(page.actions);
		this.list = {
			kind: 'ready',
			actions: page.actions,
			items: page.items,
			nextCursor: page.nextCursor
		};
	}

	/** The confirmed scope, only when it names the workspace this read was for. */
	#scopeFor(workspace: string): CacheScope | null {
		const scope = this.#scope() ?? this.#confirmed;
		return scope && scope.workspaceId === workspace ? scope : null;
	}

	async #mark(body: { ids: string[] } | { all: true }): Promise<boolean> {
		const workspace = this.#workspace();
		if (!workspace) return false;
		// The command clears the cached lists (invalidation.ts); this tab updates
		// its own list instead of reading it again.
		this.#marking = true;
		const exit = await Effect.runPromiseExit(
			sendCommand(BellRoutes.read, 'POST', body, workspace, MarkedRead)
		).finally(() => (this.#marking = false));
		if (Exit.isFailure(exit)) return false;
		this.unread = exit.value.unread;
		return true;
	}
}
