import { describe, expect, it } from 'vitest';
import { sniffImage } from './photos.js';

describe('sniffImage', () => {
	it('recognises JPEG, PNG and WebP by content', () => {
		expect(sniffImage(new Uint8Array([0xff, 0xd8, 0xff, 0xe0]))?.ext).toBe('jpg');
		expect(sniffImage(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d]))?.ext).toBe('png');
		const webp = new TextEncoder().encode('RIFF\0\0\0\0WEBPVP8 ');
		expect(sniffImage(webp)?.ext).toBe('webp');
	});

	it('refuses anything else, whatever it is called', () => {
		expect(sniffImage(new TextEncoder().encode('<svg onload=alert(1)>'))).toBeNull();
		expect(sniffImage(new TextEncoder().encode('GIF89a'))).toBeNull();
	});
});
