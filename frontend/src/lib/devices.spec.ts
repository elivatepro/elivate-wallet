import { describe, expect, it } from 'vitest';
import { activityLabel, describeDevice, initials, maskPhone } from './devices';

const IPHONE =
	'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const MAC_CHROME =
	'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
const WIN_EDGE =
	'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0';
const IPAD =
	'Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

describe('describeDevice', () => {
	it('labels common devices and browsers', () => {
		expect(describeDevice(IPHONE)).toEqual({ kind: 'phone', label: 'iPhone · Safari' });
		expect(describeDevice(MAC_CHROME)).toEqual({ kind: 'laptop', label: 'Mac · Chrome' });
		expect(describeDevice(WIN_EDGE)).toEqual({ kind: 'laptop', label: 'Windows · Edge' });
		expect(describeDevice(IPAD)).toEqual({ kind: 'tablet', label: 'iPad · Safari' });
	});

	it('falls back without a user agent', () => {
		expect(describeDevice(null)).toEqual({ kind: 'laptop', label: 'Unknown device' });
	});
});

describe('activityLabel', () => {
	const now = Date.parse('2026-10-08T12:00:00Z');
	it('says now, minutes, hours, then a date', () => {
		expect(activityLabel('2026-10-08T11:58:00Z', now)).toBe('Active now');
		expect(activityLabel('2026-10-08T11:30:00Z', now)).toBe('Active 30 minutes ago');
		expect(activityLabel('2026-10-08T10:00:00Z', now)).toBe('Active 2 hours ago');
		expect(activityLabel('2026-10-08T10:00:00Z', now, {}, true)).toBe('2 h ago');
		expect(activityLabel('2026-10-04T18:05:00Z', now, { locale: 'en-GB', timeZone: 'UTC' })).toBe(
			'Active 4 Oct, 18:05'
		);
	});
});

describe('initials and maskPhone', () => {
	it('builds initials', () => {
		expect(initials('Adaeze Nwosu')).toBe('AN');
		expect(initials('Ada')).toBe('A');
		expect(initials(null)).toBeNull();
	});

	it('shows only the last four digits', () => {
		expect(maskPhone('+2348012344410')).toBe('+234 •• •••• 4410');
		expect(maskPhone('08012344410')).toBe('•• •••• 4410');
		expect(maskPhone(null)).toBeNull();
	});
});
