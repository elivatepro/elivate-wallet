// Profile photos (Blueprint 06 B4): stored by this server in the private R2
// bucket bound as PHOTOS, served back only to their owner. The browser never
// sees the storage key; the database keeps only the key.

import type { RequestEvent } from '@sveltejs/kit';
import { Effect, Exit } from 'effect';
import { IdentityApi } from './apis-identity';
import type { VerifiedSession } from './auth';
import type { EdgeFailure } from './edge';
import { failureOf } from './flow';
import { photoStorage } from './onboarding';
import { runApi } from './request';

export const MAX_PHOTO_BYTES = 5 * 1024 * 1024;

const TYPES = [
	{ ext: 'jpg', type: 'image/jpeg', magic: [0xff, 0xd8, 0xff] },
	{ ext: 'png', type: 'image/png', magic: [0x89, 0x50, 0x4e, 0x47] }
] as const;

/** JPEG, PNG or WebP by content, never by the file name or the browser's type. */
export function sniffImage(
	bytes: Uint8Array
): { ext: 'jpg' | 'png' | 'webp'; type: string } | null {
	for (const t of TYPES) {
		if (t.magic.every((b, i) => bytes[i] === b)) return { ext: t.ext, type: t.type };
	}
	const riff = String.fromCharCode(...bytes.slice(0, 4));
	const webp = String.fromCharCode(...bytes.slice(8, 12));
	if (riff === 'RIFF' && webp === 'WEBP') return { ext: 'webp', type: 'image/webp' };
	return null;
}

export type PhotoResult =
	{ ok: true } | { ok: false; error: string } | { ok: false; failure: EdgeFailure };

export async function storePhoto(
	event: RequestEvent,
	session: VerifiedSession,
	file: File
): Promise<PhotoResult> {
	const bucket = await photoStorage();
	if (!bucket) return { ok: false, error: 'Photo upload isn’t available yet.' };
	if (file.size === 0) return { ok: false, error: 'Choose a photo.' };
	if (file.size > MAX_PHOTO_BYTES) return { ok: false, error: 'Use a photo under 5 MB.' };
	const bytes = new Uint8Array(await file.arrayBuffer());
	const kind = sniffImage(bytes);
	if (!kind) return { ok: false, error: 'Use a JPEG, PNG or WebP photo.' };

	const key = `photos/${session.userId}/${crypto.randomUUID()}.${kind.ext}`;
	await bucket.put(key, bytes.buffer as ArrayBuffer, { httpMetadata: { contentType: kind.type } });
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* IdentityApi).setPhoto(key);
		})
	);
	if (Exit.isFailure(exit)) {
		await bucket.delete(key);
		return { ok: false, failure: failureOf(exit) };
	}
	const previous = exit.value.previousPhotoKey;
	if (previous && previous !== key) await bucket.delete(previous);
	return { ok: true };
}

/** The caller's own photo, or null. */
export async function readOwnPhoto(event: RequestEvent, session: VerifiedSession) {
	const bucket = await photoStorage();
	if (!bucket) return null;
	const exit = await runApi(
		event,
		session,
		Effect.gen(function* () {
			return yield* (yield* IdentityApi).photoKey;
		})
	);
	if (Exit.isFailure(exit) || !exit.value) return null;
	return bucket.get(exit.value);
}
