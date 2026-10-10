// Profile photos in the browser (Blueprint 06 B4, slice 21): shrink before
// upload and address the stored photo by version, so the browser may keep it.
// The server still checks every upload's type (by content) and size.

/** Longest side of a stored profile photo; shown at most ~96 px (×3 screens). */
export const PHOTO_MAX_SIDE = 512;
/** Re-encoded quality (WebP, else JPEG). */
const QUALITY = 0.85;

/** Width and height that fit within `max` on the longest side, never enlarged. */
export function fitWithin(
	width: number,
	height: number,
	max = PHOTO_MAX_SIDE
): { width: number; height: number } {
	const longest = Math.max(width, height);
	if (longest <= max || longest === 0) return { width, height };
	const scale = max / longest;
	return {
		width: Math.max(1, Math.round(width * scale)),
		height: Math.max(1, Math.round(height * scale))
	};
}

/**
 * The own photo's URL, versioned by when it last changed: a new photo is a new
 * URL, so `/api/profile/photo` can be cached privately without going stale.
 */
export function profilePhotoSrc(
	profile: { hasPhoto: boolean; photoUpdatedAt?: string | null } | null | undefined
): string | null {
	if (!profile?.hasPhoto) return null;
	const at = profile.photoUpdatedAt ? Date.parse(profile.photoUpdatedAt) : NaN;
	return Number.isFinite(at) ? `/api/profile/photo?v=${at}` : '/api/profile/photo';
}

function encode(canvas: HTMLCanvasElement, type: string): Promise<Blob | null> {
	return new Promise((resolve) => canvas.toBlob(resolve, type, QUALITY));
}

/**
 * Scales a chosen photo to at most 512 px and re-encodes it (WebP, else JPEG),
 * which also drops its metadata (camera, location). Keeps the original when
 * the browser can't decode it here or the result isn't smaller; the server
 * decides either way.
 */
export async function shrinkPhoto(file: File): Promise<File> {
	if (typeof createImageBitmap !== 'function' || typeof document === 'undefined') return file;
	let bitmap: ImageBitmap;
	try {
		bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' });
	} catch {
		return file;
	}
	try {
		const size = fitWithin(bitmap.width, bitmap.height);
		const canvas = document.createElement('canvas');
		canvas.width = size.width;
		canvas.height = size.height;
		const context = canvas.getContext('2d');
		if (!context) return file;
		context.imageSmoothingQuality = 'high';
		context.drawImage(bitmap, 0, 0, size.width, size.height);
		let blob = await encode(canvas, 'image/webp');
		// Browsers without a WebP encoder hand back PNG: use JPEG instead.
		if (!blob || blob.type !== 'image/webp') blob = await encode(canvas, 'image/jpeg');
		if (!blob || blob.size === 0) return file;
		const fitted = size.width === bitmap.width && size.height === bitmap.height;
		if (fitted && blob.size >= file.size) return file;
		const ext = blob.type === 'image/webp' ? 'webp' : 'jpg';
		return new File([blob], `photo.${ext}`, { type: blob.type });
	} catch {
		return file;
	} finally {
		bitmap.close();
	}
}

/**
 * For the no-JavaScript-first wizard form: swaps the input's chosen file for
 * the shrunk one, so the normal form post sends the small photo.
 */
export async function shrinkInputPhoto(input: HTMLInputElement): Promise<File | null> {
	const file = input.files?.[0];
	if (!file) return null;
	const small = await shrinkPhoto(file);
	// A newer choice while this one was converting wins: leave it alone.
	if (input.files?.[0] !== file) return null;
	if (small !== file && typeof DataTransfer === 'function') {
		try {
			const transfer = new DataTransfer();
			transfer.items.add(small);
			input.files = transfer.files;
		} catch {
			// keep the original; the server checks its size
		}
	}
	return small;
}
