import { describe, expect, it } from 'vitest';
import {
	deviceNoun,
	keyBytes,
	parsePushPayload,
	pushSupportFor,
	switchStateFor,
	type PushEnvironment
} from './push.js';

const env = (over: Partial<PushEnvironment> = {}): PushEnvironment => ({
	device: 'android',
	standalone: false,
	serviceWorker: true,
	pushManager: true,
	notification: true,
	...over
});

describe('where push can work (Blueprint 42)', () => {
	it('works in Android, desktop and Mac browsers with the Push API', () => {
		expect(pushSupportFor(env())).toBe('supported');
		expect(pushSupportFor(env({ device: 'desktop' }))).toBe('supported');
		expect(pushSupportFor(env({ device: 'mac-safari' }))).toBe('supported');
	});

	it('needs the installed app on iPhone and iPad', () => {
		expect(pushSupportFor(env({ device: 'ios' }))).toBe('ios-install-first');
		expect(pushSupportFor(env({ device: 'ios', standalone: true }))).toBe('supported');
	});

	it('is not possible in an in-app browser or without the Push API', () => {
		expect(pushSupportFor(env({ device: 'in-app' }))).toBe('unsupported');
		expect(pushSupportFor(env({ pushManager: false }))).toBe('unsupported');
		expect(pushSupportFor(env({ device: 'ios', standalone: true, notification: false }))).toBe(
			'unsupported'
		);
	});
});

describe('the Profile switch (PN02/PN03)', () => {
	it('is on only when the backend and the browser both say so', () => {
		expect(switchStateFor('supported', 'granted', true, true)).toBe('on');
		expect(switchStateFor('supported', 'granted', false, true)).toBe('off');
		expect(switchStateFor('supported', 'default', true, true)).toBe('off');
	});

	it('shows the blocked and iPhone states', () => {
		expect(switchStateFor('supported', 'denied', true, true)).toBe('blocked');
		expect(switchStateFor('ios-install-first', null, false, true)).toBe('ios-install-first');
	});

	it('is left out where push cannot work or is not set up', () => {
		expect(switchStateFor('unsupported', null, false, true)).toBe('hidden');
		expect(switchStateFor('supported', 'granted', false, false)).toBe('hidden');
	});

	it('names the device', () => {
		expect(deviceNoun('android')).toBe('this phone');
		expect(deviceNoun('ios')).toBe('this phone');
		expect(deviceNoun('desktop')).toBe('this computer');
		expect(deviceNoun('mac-safari')).toBe('this computer');
	});
});

describe('what the service worker shows', () => {
	const id = '11111111-2222-3333-4444-555555555555';
	const good = { v: 1, id, title: 'Income posted', body: '₦250,000.00, split across your pockets' };

	it('accepts the worker payload and keeps app links only', () => {
		expect(parsePushPayload({ ...good, path: '/app/withdrawals' })).toEqual({
			id,
			title: good.title,
			body: good.body,
			path: '/app/withdrawals'
		});
		expect(parsePushPayload({ ...good, path: 'https://evil.example/app' })?.path).toBe('/app');
		expect(parsePushPayload({ ...good, path: '//evil.example' })?.path).toBe('/app');
		expect(parsePushPayload(good)?.path).toBe('/app');
		const wd = '/app/withdrawals/0b0e7b5c-6d3a-4f4e-9a52-6c2f1f7e8a10';
		expect(parsePushPayload({ ...good, path: wd })?.path).toBe(wd);
		expect(parsePushPayload({ ...good, path: `${wd}/x` })?.path).toBe('/app');
	});

	it('ignores anything else', () => {
		expect(parsePushPayload(null)).toBeNull();
		expect(parsePushPayload('hello')).toBeNull();
		expect(parsePushPayload({ ...good, v: 2 })).toBeNull();
		expect(parsePushPayload({ ...good, id: 'not-a-uuid' })).toBeNull();
		expect(parsePushPayload({ ...good, title: '' })).toBeNull();
		expect(parsePushPayload({ ...good, body: 'x'.repeat(201) })).toBeNull();
	});
});

describe('the VAPID key', () => {
	it('decodes base64url to bytes', () => {
		expect([...keyBytes('BAEC_-8')]).toEqual([4, 1, 2, 255, 239]);
	});
});
