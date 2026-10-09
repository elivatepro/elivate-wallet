// Statement and report files in the browser (Blueprint 15): the list, polling
// while a file is being made, and downloads. Downloads go through the app
// server (which streams from private storage); a leadership report answers
// step_up_required until the PIN is entered (Paper S14d).

import { Cause, Effect, Exit, Option, Schema } from 'effect';
import { ExportFile, ExportPage } from '#lib/contract/exports.js';
import type { ApiFailure } from '#lib/contract/errors.js';
import { isWorking } from '#lib/statements.js';
import { getJson, sendAccountCommand } from './api';

export type DownloadResult =
	| { readonly kind: 'ok'; readonly blob: Blob; readonly name: string }
	| { readonly kind: 'step_up' }
	| { readonly kind: 'expired' }
	| { readonly kind: 'error'; readonly message: string };

/** The filename the server sent, or a safe default. */
export function fileNameOf(header: string | null, fallback: string): string {
	const match = header?.match(/filename="([A-Za-z0-9._-]{1,200})"/);
	return match?.[1] ?? fallback;
}

export async function fetchFile(
	file: ExportFile,
	part: 'file' | 'preview' = 'file'
): Promise<DownloadResult> {
	let response: Response;
	try {
		response = await fetch(`/api/exports/${file.exportId}/${part}`, { cache: 'no-store' });
	} catch {
		return {
			kind: 'error',
			message: 'We couldn’t reach Wallet. Check your connection and try again.'
		};
	}
	if (response.ok) {
		return {
			kind: 'ok',
			blob: await response.blob(),
			name: fileNameOf(
				response.headers.get('content-disposition'),
				`${file.reference}.${file.format}`
			)
		};
	}
	const body = (await response.json().catch(() => null)) as {
		error?: { code?: string; message?: string; details?: { reason?: string } };
	} | null;
	if (body?.error?.code === 'step_up_required') return { kind: 'step_up' };
	if (body?.error?.details?.reason === 'export_expired') return { kind: 'expired' };
	return {
		kind: 'error',
		message: body?.error?.message ?? 'We couldn’t download this file. Try again.'
	};
}

/** Saves a downloaded file with the browser's own download. */
export function saveBlob(blob: Blob, name: string): void {
	const url = URL.createObjectURL(blob);
	const link = document.createElement('a');
	link.href = url;
	link.download = name;
	link.rel = 'noopener';
	document.body.append(link);
	link.click();
	link.remove();
	setTimeout(() => URL.revokeObjectURL(url), 30_000);
}

export const messageOf = (exit: Exit.Exit<unknown, ApiFailure>, fallback: string): string => {
	if (Exit.isSuccess(exit)) return '';
	const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
	return failure?._tag === 'BackendError' ? failure.message : fallback;
};

/**
 * A list of files with polling: while any is being made, its state is asked
 * again (1.5 s, slowing to 10 s); the list stops polling when none is.
 */
export class ExportFiles {
	files = $state<ExportFile[]>([]);
	/** Cursor of the next (older) page, when there is one. */
	nextCursor = $state<string | null>(null);
	loadingMore = $state(false);
	#stopped = false;
	#timer: ReturnType<typeof setTimeout> | null = null;
	#delay = 1500;
	#onReady: ((file: ExportFile) => void) | null;

	constructor(onReady: ((file: ExportFile) => void) | null = null) {
		this.#onReady = onReady;
	}

	set(files: readonly ExportFile[], nextCursor: string | null = null): void {
		this.files = [...files];
		this.nextCursor = nextCursor;
		this.#schedule();
	}

	/** Older files (the list pages by creation time, newest first). */
	async loadMore(path: string): Promise<void> {
		if (!this.nextCursor || this.loadingMore) return;
		this.loadingMore = true;
		const exit = await Effect.runPromiseExit(
			getJson(`${path}?cursor=${encodeURIComponent(this.nextCursor)}`, ExportPage)
		);
		this.loadingMore = false;
		if (Exit.isFailure(exit) || this.#stopped) return;
		const known = this.files.map((f) => f.exportId);
		this.files = [...this.files, ...exit.value.items.filter((f) => !known.includes(f.exportId))];
		this.nextCursor = exit.value.nextCursor;
		this.#schedule();
	}

	/** A new or retried file goes to the top (replacing its old row). */
	upsert(file: ExportFile): void {
		this.files = [file, ...this.files.filter((f) => f.exportId !== file.exportId)];
		this.#delay = 1500;
		this.#schedule();
	}

	/** Leaving the page: no timer, and a poll already under way schedules nothing. */
	stop(): void {
		this.#stopped = true;
		this.#clear();
	}

	#clear(): void {
		if (this.#timer) clearTimeout(this.#timer);
		this.#timer = null;
	}

	#schedule(): void {
		this.#clear();
		if (this.#stopped || !this.files.some(isWorking)) return;
		this.#timer = setTimeout(() => void this.#poll(), this.#delay);
		this.#delay = Math.min(this.#delay * 1.5, 10_000);
	}

	async #poll(): Promise<void> {
		const working = this.files.filter(isWorking);
		const results = await Promise.all(
			working.map((f) => Effect.runPromiseExit(getJson(`/api/exports/${f.exportId}`, ExportFile)))
		);
		if (this.#stopped) return;
		for (const exit of results) {
			if (!Exit.isSuccess(exit)) continue;
			const next = exit.value;
			const before = this.files.find((f) => f.exportId === next.exportId);
			this.files = this.files.map((f) => (f.exportId === next.exportId ? next : f));
			if (before && isWorking(before) && next.status === 'ready') this.#onReady?.(next);
		}
		this.#schedule();
	}
}

export const retryFile = (file: ExportFile) =>
	Effect.runPromiseExit(
		sendAccountCommand(`/api/exports/${file.exportId}`, 'POST', {}, ExportFile)
	);

const UnlockResult = Schema.Struct({ unlocked: Schema.Boolean });

/** Verifies the PIN: opens the 5-minute step-up a report download needs. */
export const unlockDownloads = (pin: string) =>
	Effect.runPromiseExit(sendAccountCommand('/api/exports/unlock', 'POST', { pin }, UnlockResult));
