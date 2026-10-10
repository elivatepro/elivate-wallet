// Network logos (Blueprint 17, W-20): stored by this server in the private R2
// bucket bound as PHOTOS under `brand/<tenant>/`, served back only to members
// of that network through the app (never a public link). The database issues
// the key after checking manage_team_settings; the bytes decide the type.

import type { RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import type { AssetKind } from '#lib/contract/settings.js';
import { SettingsApi } from './apis-settings';
import type { VerifiedSession } from './auth';
import { appServerSecret } from './config';
import type { EdgeFailure } from './edge';
import { failureOf } from './flow';
import { photoStorage } from './onboarding';
import { sniffImage } from './photos';
import { runApi } from './request';

/** Logos stay small: the sidebar, previews and PDFs read them often. */
export const MAX_LOGO_BYTES = 1024 * 1024;

const BRAND_KEY = /^brand\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(jpg|png|webp)$/;

export type BrandUpload =
	{ ok: true; key: string } | { ok: false; error: string } | { ok: false; failure: EdgeFailure };

/** Stores one logo; the key is saved with the settings (PIN) afterwards. */
export async function storeBrandAsset(
	event: RequestEvent,
	session: VerifiedSession,
	membershipId: string,
	file: File
): Promise<BrandUpload> {
	const bucket = await photoStorage();
	const secret = appServerSecret();
	if (!bucket || !secret) return { ok: false, error: 'Logo upload isn’t available yet.' };
	if (file.size === 0) return { ok: false, error: 'Choose an image.' };
	if (file.size > MAX_LOGO_BYTES) return { ok: false, error: 'Use an image under 1 MB.' };
	const bytes = new Uint8Array(await file.arrayBuffer());
	const kind = sniffImage(bytes);
	if (!kind) return { ok: false, error: 'Use a PNG, JPEG or WebP image.' };

	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).uploadKey(membershipId, kind.ext, secret);
		})
	);
	if (Exit.isFailure(exit)) return { ok: false, failure: failureOf(exit) };
	const key = exit.value.objectKey;
	if (!BRAND_KEY.test(key)) return { ok: false, error: 'Logo upload isn’t available yet.' };
	await bucket.put(key, bytes.slice().buffer as ArrayBuffer, {
		httpMetadata: { contentType: kind.type }
	});
	return { ok: true, key };
}

/** One logo of the selected network, for one of its members; null when there is none. */
export async function readBrandAsset(
	event: RequestEvent,
	session: VerifiedSession,
	membershipId: string,
	kind: AssetKind
) {
	const bucket = await photoStorage();
	const secret = appServerSecret();
	if (!bucket || !secret) return null;
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* SettingsApi).assetKey(membershipId, kind, secret);
		})
	);
	if (Exit.isFailure(exit) || !BRAND_KEY.test(exit.value.objectKey)) return null;
	return bucket.get(exit.value.objectKey);
}

/** A stored logo as a data URI for PDFs (the runner reads it with the worker secret). */
export async function logoDataUri(key: string | null): Promise<string | null> {
	if (!key || !BRAND_KEY.test(key)) return null;
	const bucket = await photoStorage();
	const object = bucket ? await bucket.get(key) : null;
	if (!object) return null;
	const bytes = new Uint8Array(await new Response(object.body).arrayBuffer());
	const kind = sniffImage(bytes);
	if (!kind || bytes.length > MAX_LOGO_BYTES) return null;
	let binary = '';
	for (let i = 0; i < bytes.length; i += 0x8000) {
		binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
	}
	return `data:${kind.type};base64,${btoa(binary)}`;
}
