import { describe, expect, it } from 'vitest';
import { fitWithin, profilePhotoSrc } from './photo.js';

describe('profile photo', () => {
	it('fits the longest side within 512 px, never enlarging', () => {
		expect(fitWithin(4032, 3024)).toEqual({ width: 512, height: 384 });
		expect(fitWithin(1080, 1920)).toEqual({ width: 288, height: 512 });
		expect(fitWithin(300, 200)).toEqual({ width: 300, height: 200 });
		expect(fitWithin(5000, 1)).toEqual({ width: 512, height: 1 });
	});

	it('versions the photo URL by when it changed', () => {
		expect(profilePhotoSrc({ hasPhoto: false, photoUpdatedAt: null })).toBeNull();
		expect(profilePhotoSrc(null)).toBeNull();
		expect(profilePhotoSrc({ hasPhoto: true, photoUpdatedAt: '2026-10-10T08:00:00.000Z' })).toBe(
			`/api/profile/photo?v=${Date.parse('2026-10-10T08:00:00.000Z')}`
		);
		expect(profilePhotoSrc({ hasPhoto: true, photoUpdatedAt: null })).toBe('/api/profile/photo');
	});
});
