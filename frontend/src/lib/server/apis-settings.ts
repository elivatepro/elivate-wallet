// SettingsApi (Blueprint 17): team settings, the brand, quick search, the
// Team Backup Vault and restore requests on the `org` Edge Function. Reads
// retry; commands never do (the caller keeps its idempotency key). Storage
// keys are asked for with the app-server secret and never leave this server.

import { Context, Effect, Layer, Schedule } from 'effect';
import { isRetryableRead } from '#lib/contract/errors.js';
import {
	Brand,
	ObjectTarget,
	RestoreResult,
	SearchResults,
	SettingsRoutes,
	SettingsView,
	StartedBackup,
	VaultView,
	type AssetKind,
	type SettingsPatch
} from '#lib/contract/settings.js';
import { EdgeTransport, type EdgeFailure } from './edge';

const readPolicy = {
	times: 2,
	while: isRetryableRead,
	schedule: Schedule.exponential('200 millis').pipe(Schedule.jittered)
};

export interface SettingsApiShape {
	readonly settings: (membershipId: string) => Effect.Effect<SettingsView, EdgeFailure>;
	readonly save: (
		membershipId: string,
		body: {
			readonly expectedRevision: number;
			readonly fields: SettingsPatch;
			readonly idempotencyKey: string;
		}
	) => Effect.Effect<SettingsView, EdgeFailure>;
	readonly restoreRevision: (
		membershipId: string,
		body: {
			readonly expectedRevision: number;
			readonly revision: number;
			readonly idempotencyKey: string;
		}
	) => Effect.Effect<SettingsView, EdgeFailure>;
	readonly brand: (membershipId: string) => Effect.Effect<Brand, EdgeFailure>;
	readonly assetKey: (
		membershipId: string,
		kind: AssetKind,
		appServerSecret: string
	) => Effect.Effect<ObjectTarget, EdgeFailure>;
	readonly uploadKey: (
		membershipId: string,
		ext: 'jpg' | 'png' | 'webp',
		appServerSecret: string
	) => Effect.Effect<ObjectTarget, EdgeFailure>;
	readonly search: (membershipId: string, q: string) => Effect.Effect<SearchResults, EdgeFailure>;
	readonly vault: (membershipId: string) => Effect.Effect<VaultView, EdgeFailure>;
	readonly startBackup: (
		membershipId: string,
		body: { readonly idempotencyKey: string }
	) => Effect.Effect<StartedBackup, EdgeFailure>;
	readonly authorizeBackupDownload: (
		membershipId: string,
		backupId: string,
		appServerSecret: string
	) => Effect.Effect<ObjectTarget, EdgeFailure>;
	readonly requestRestore: (
		membershipId: string,
		body: { readonly backupId: string; readonly reason: string; readonly idempotencyKey: string }
	) => Effect.Effect<RestoreResult, EdgeFailure>;
	readonly cancelRestore: (
		membershipId: string,
		restoreId: string,
		body: { readonly idempotencyKey: string }
	) => Effect.Effect<RestoreResult, EdgeFailure>;
}

export class SettingsApi extends Context.Service<SettingsApi, SettingsApiShape>()('SettingsApi') {}

export const SettingsApiLive = Layer.effect(
	SettingsApi,
	Effect.gen(function* () {
		const edge = yield* EdgeTransport;
		const fn = 'org' as const;
		return {
			settings: (membershipId) =>
				edge
					.call({ fn, route: SettingsRoutes.settings, membershipId }, SettingsView)
					.pipe(Effect.retry(readPolicy)),
			save: (membershipId, body) =>
				edge.call({ fn, route: SettingsRoutes.save, membershipId, body }, SettingsView),
			restoreRevision: (membershipId, body) =>
				edge.call({ fn, route: SettingsRoutes.restoreRevision, membershipId, body }, SettingsView),
			brand: (membershipId) =>
				edge
					.call({ fn, route: SettingsRoutes.brand, membershipId }, Brand)
					.pipe(Effect.retry(readPolicy)),
			assetKey: (membershipId, kind, appServerSecret) =>
				edge.call(
					{ fn, route: SettingsRoutes.assetKey, membershipId, body: { kind }, appServerSecret },
					ObjectTarget
				),
			uploadKey: (membershipId, ext, appServerSecret) =>
				edge.call(
					{ fn, route: SettingsRoutes.uploadKey, membershipId, body: { ext }, appServerSecret },
					ObjectTarget
				),
			search: (membershipId, q) =>
				edge
					.call({ fn, route: SettingsRoutes.search, membershipId, query: { q } }, SearchResults)
					.pipe(Effect.retry(readPolicy)),
			vault: (membershipId) =>
				edge
					.call({ fn, route: SettingsRoutes.vault, membershipId }, VaultView)
					.pipe(Effect.retry(readPolicy)),
			startBackup: (membershipId, body) =>
				edge.call({ fn, route: SettingsRoutes.startBackup, membershipId, body }, StartedBackup),
			authorizeBackupDownload: (membershipId, backupId, appServerSecret) =>
				edge.call(
					{
						fn,
						route: SettingsRoutes.backupDownload(backupId),
						membershipId,
						body: {},
						appServerSecret
					},
					ObjectTarget
				),
			requestRestore: (membershipId, body) =>
				edge.call({ fn, route: SettingsRoutes.requestRestore, membershipId, body }, RestoreResult),
			cancelRestore: (membershipId, restoreId, body) =>
				edge.call(
					{ fn, route: SettingsRoutes.cancelRestore(restoreId), membershipId, body },
					RestoreResult
				)
		};
	})
);
