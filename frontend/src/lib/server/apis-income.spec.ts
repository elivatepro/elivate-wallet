import { describe, expect, it } from 'vitest';
import { rebaseUploadUrl } from './apis-income.js';

const path =
	'/storage/v1/object/upload/sign/financial-evidence/6b0f8f3e-2a4c-4b8e-9d55-0c7a1d2e3f40/income/9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d';

describe('rebaseUploadUrl', () => {
	it('moves the signed upload onto the configured Supabase origin', () => {
		expect(rebaseUploadUrl(`http://kong:8000${path}?token=abc.def`, 'http://127.0.0.1:54321')).toBe(
			`http://127.0.0.1:54321${path}?token=abc.def`
		);
		expect(rebaseUploadUrl(`https://x.supabase.co${path}?token=t`, 'https://x.supabase.co')).toBe(
			`https://x.supabase.co${path}?token=t`
		);
	});

	it('refuses anything but the evidence bucket signed-upload path with a token', () => {
		const origin = 'https://x.supabase.co';
		expect(rebaseUploadUrl(`https://x.supabase.co${path}`, origin)).toBeNull();
		expect(
			rebaseUploadUrl('https://x.supabase.co/storage/v1/object/upload/sign/other/a?token=t', origin)
		).toBeNull();
		expect(rebaseUploadUrl(`https://x.supabase.co${path}/../../x?token=t`, origin)).toBeNull();
		expect(rebaseUploadUrl('not a url', origin)).toBeNull();
	});

	it('accepts each evidence kind of Blueprint 12, and nothing else', () => {
		const origin = 'https://x.supabase.co';
		for (const kind of ['conversion', 'adjustment', 'returned_funds']) {
			const p = path.replace('/income/', `/${kind}/`);
			expect(rebaseUploadUrl(`${origin}${p}?token=t`, origin)).toBe(`${origin}${p}?token=t`);
		}
		expect(
			rebaseUploadUrl(`${origin}${path.replace('/income/', '/other/')}?token=t`, origin)
		).toBeNull();
	});
});
