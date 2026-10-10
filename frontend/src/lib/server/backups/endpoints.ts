// App-server glue for the Team Backup Vault (Blueprint 17): building the
// backup runner from this deployment's bindings, starting it right after
// "Back up now", and streaming an archive after the backend authorized the
// download (manage_team_settings + PIN, audited).

import type { RequestEvent } from '@sveltejs/kit';
import { Cause, Effect, Exit, Option } from 'effect';
import { TransportError } from '#lib/contract/errors.js';
import { SettingsApi } from '../apis-settings';
import { appServerSecret, exportsWorkerSecret, requireConfig } from '../config';
import { readWorkspace } from '../cookies';
import { respondError, toBackendError, unauthenticated, workspaceChanged } from '../relay';
import { runApi } from '../request';
import { edgeBackupClient, runBackups, type BackupRunnerDeps } from './runner';
import { backupStorage } from './storage';

/** Null when this deployment cannot make backups (no secret or bucket). */
export async function backupRunnerDeps(): Promise<BackupRunnerDeps | null> {
	const secret = exportsWorkerSecret();
	const storage = await backupStorage();
	if (!secret || !storage) return null;
	const config = requireConfig();
	return {
		client: edgeBackupClient({
			supabaseUrl: config.supabaseUrl,
			publishableKey: config.publishableKey,
			secret,
			fetch: globalThis.fetch.bind(globalThis)
		}),
		storage,
		log: (entry) => console.log(JSON.stringify({ route: 'backups.run', ...entry }))
	};
}

/** Starts the runner after "Back up now" (pg_cron/pg_net also wakes it; jobs are leased). */
export function kickBackups(): void {
	const run = (async () => {
		const deps = await backupRunnerDeps();
		if (deps) await runBackups(deps, 25_000);
	})().catch((error: unknown) =>
		console.log(JSON.stringify({ route: 'backups.kick', error: String(error).slice(0, 200) }))
	);
	import('cloudflare:workers').then(
		(m) => (m as unknown as { waitUntil?: (p: Promise<unknown>) => void }).waitUntil?.(run),
		() => undefined
	);
}

const ARCHIVE_NAME = /^elivate-backup-[a-z0-9-]{1,40}-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\.zip$/;

/** Sends one archive after the backend re-checked authority, the PIN and expiry. */
export async function streamBackup(event: RequestEvent, id: string): Promise<Response> {
	const session = await event.locals.session();
	if (!session) return respondError(unauthenticated());
	const membershipId = readWorkspace(event.cookies);
	if (!membershipId) return respondError(workspaceChanged());
	const secret = appServerSecret();
	const storage = await backupStorage();
	if (!secret || !storage) {
		return respondError(toBackendError(new TransportError({ reason: 'network', status: null })));
	}
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).authorizeBackupDownload(membershipId, id, secret);
		})
	);
	if (Exit.isFailure(exit)) {
		const failure = Option.getOrUndefined(Cause.findErrorOption(exit.cause));
		return respondError(
			toBackendError(failure ?? new TransportError({ reason: 'network', status: null }))
		);
	}
	const target = exit.value;
	const stored = await storage.get(target.objectKey);
	if (!stored) {
		return new Response(
			JSON.stringify({
				ok: false,
				error: {
					code: 'conflict',
					message: 'This backup is no longer available.',
					retryable: false,
					details: { reason: 'backup_expired' }
				},
				requestId: crypto.randomUUID()
			}),
			{
				status: 409,
				headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
			}
		);
	}
	const fileName =
		target.fileName && ARCHIVE_NAME.test(target.fileName) ? target.fileName : 'elivate-backup.zip';
	const headers: Record<string, string> = {
		'content-type': 'application/zip',
		'content-disposition': `attachment; filename="${fileName}"`,
		'cache-control': 'private, no-store',
		'x-content-type-options': 'nosniff',
		'content-security-policy': "default-src 'none'; sandbox"
	};
	if (target.byteSize) headers['content-length'] = String(target.byteSize);
	if (target.sha256) headers['x-checksum-sha256'] = target.sha256;
	const body =
		stored.body instanceof Uint8Array ? (stored.body.slice().buffer as ArrayBuffer) : stored.body;
	return new Response(body, { headers });
}
