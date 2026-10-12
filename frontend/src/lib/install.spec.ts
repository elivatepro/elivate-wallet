import { describe, expect, it } from 'vitest';
import { installDeviceFor } from './install.js';

const UA = {
	iphone:
		'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
	ipad: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
	android:
		'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36',
	macChrome:
		'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
	windowsEdge:
		'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0',
	instagram:
		'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Instagram 350.0.0.0'
};

describe('install screen by device (Blueprint 35)', () => {
	it('shows the Safari steps on iPhone and iPad', () => {
		expect(installDeviceFor(UA.iphone)).toBe('ios');
		expect(installDeviceFor(UA.ipad, 5)).toBe('ios');
	});

	it('tells a Mac in Safari from an iPad by touch points', () => {
		expect(installDeviceFor(UA.ipad)).toBe('mac-safari');
	});

	it('uses the install prompt on Android and Chromium desktops', () => {
		expect(installDeviceFor(UA.android)).toBe('android');
		expect(installDeviceFor(UA.macChrome)).toBe('desktop');
		expect(installDeviceFor(UA.windowsEdge)).toBe('desktop');
	});

	it('sends in-app browsers to a real browser', () => {
		expect(installDeviceFor(UA.instagram)).toBe('in-app');
	});
});
