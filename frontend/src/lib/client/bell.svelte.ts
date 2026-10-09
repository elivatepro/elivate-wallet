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

const POLL_MS = 60_000;

/**
 * A bell read for the workspace this tab shows: the server refuses it when
 * another tab switched workspace, so a stale tab never shows another
 * network's items or count.
 */
function read<S extends Schema.ConstraintDecoder<unknown>>(
	path: string,
	workspace: string,
	schema: S
) {
	return requestJson(
		{
			fetch,
			url: path,
			method: 'GET',
			route: `GET ${path.split('?')[0]}`,
			headers: { 'x-ew-workspace': workspace },
			timeoutMs: READ_TIMEOUT_MS
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
	view: NotificationView = $state('unread');
	list: BellList = $state({ kind: 'idle' });
	more = $state(false);
	#workspace: () => string | null;
	#generation = 0;

	constructor(workspace: () => string | null) {
		this.#workspace = workspace;
	}

	/** Polls the badge; returns the stop function. */
	start(): () => void {
		const tick = () => {
			if (document.visibilityState === 'visible' && navigator.onLine) void this.refreshCount();
		};
		const timer = setInterval(tick, POLL_MS);
		window.addEventListener('focus', tick);
		document.addEventListener('visibilitychange', tick);
		tick();
		return () => {
			clearInterval(timer);
			window.removeEventListener('focus', tick);
			document.removeEventListener('visibilitychange', tick);
		};
	}

	async refreshCount(): Promise<void> {
		const workspace = this.#workspace();
		if (!workspace) return;
		const exit = await Effect.runPromiseExit(read(BellRoutes.unread, workspace, UnreadCount));
		if (Exit.isSuccess(exit)) this.unread = exit.value.unread;
	}

	async load(view: NotificationView = this.view): Promise<void> {
		this.view = view;
		const workspace = this.#workspace();
		if (!workspace) return;
		const generation = ++this.#generation;
		if (this.list.kind !== 'ready') this.list = { kind: 'loading' };
		const exit = await Effect.runPromiseExit(
			read(`${BellRoutes.list}?view=${view}&limit=20`, workspace, NotificationPage)
		);
		if (generation !== this.#generation) return; // a newer load won
		if (Exit.isFailure(exit)) {
			this.list = { kind: 'error' };
			return;
		}
		const page = exit.value;
		this.unread = page.unread;
		this.list = {
			kind: 'ready',
			actions: page.actions,
			items: page.items,
			nextCursor: page.nextCursor
		};
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

	async #mark(body: { ids: string[] } | { all: true }): Promise<boolean> {
		const workspace = this.#workspace();
		if (!workspace) return false;
		const exit = await Effect.runPromiseExit(
			sendCommand(BellRoutes.read, 'POST', body, workspace, MarkedRead)
		);
		if (Exit.isFailure(exit)) return false;
		this.unread = exit.value.unread;
		return true;
	}
}
