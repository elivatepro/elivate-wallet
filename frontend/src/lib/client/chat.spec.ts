import { describe, expect, it } from 'vitest';
import {
	CHATWOOT_SETTINGS,
	browserContext,
	chatScreen,
	describeDevice,
	sdkUrl,
	startChat,
	type ChatwootApi
} from './chat.js';

/** Mirrors Chatwoot's SDK checks (sdk.js setUser / setCustomAttributes). */
function fakeChatwoot() {
	const calls: string[] = [];
	const api: ChatwootApi = {
		setUser(identifier, user) {
			if (typeof identifier !== 'string') throw new Error('Identifier should be a string');
			const record = user as unknown as Record<string, unknown>;
			if (!['avatar_url', 'email', 'name'].some((key) => !!record[key])) {
				throw new Error('User object should have one of the keys [avatar_url, email, name]');
			}
			calls.push(`user:${identifier}:${Object.keys(user).sort().join(',')}`);
		},
		setCustomAttributes(attributes) {
			calls.push(`attrs:${Object.keys(attributes).sort().join(',')}`);
		},
		toggle(state) {
			calls.push(`toggle:${state}`);
		}
	};
	return { api, calls };
}

describe('support chat (W-21)', () => {
	it('shares only the route pattern as the screen', () => {
		expect(chatScreen('/app/support')).toBe('/app/support');
		expect(chatScreen('/app/members/[id]')).toBe('/app/members/[id]');
		expect(chatScreen('/app/activity?tx=123#top')).toBe('/app/activity');
		expect(chatScreen('/app/<script>"x"')).toBe('/app/scriptx');
		expect(chatScreen(null)).toBe('/app');
		expect(chatScreen('')).toBe('/app');
		expect(chatScreen('evil')).toBe('/app');
		expect(chatScreen(`/app/${'a'.repeat(400)}`)).toHaveLength(120);
	});

	it('hides the Chatwoot bubble and asks for no personal fields', () => {
		expect(CHATWOOT_SETTINGS).toEqual({
			hideMessageBubble: true,
			position: 'right',
			type: 'standard',
			launcherTitle: 'Chat with support',
			darkMode: 'auto'
		});
	});

	it('loads the SDK only from an https origin', () => {
		expect(sdkUrl('https://app.chatwoot.com')).toBe('https://app.chatwoot.com/packs/js/sdk.js');
		expect(sdkUrl('https://app.chatwoot.com/some/path?x=1')).toBe(
			'https://app.chatwoot.com/packs/js/sdk.js'
		);
		expect(sdkUrl('http://app.chatwoot.com')).toBeNull();
		expect(sdkUrl('javascript:alert(1)')).toBeNull();
		expect(sdkUrl('not a url')).toBeNull();
		expect(sdkUrl('http://127.0.0.1:3000')).toBe('http://127.0.0.1:3000/packs/js/sdk.js');
	});

	it('names the contact, adds the email and the context, then opens', () => {
		const { api, calls } = fakeChatwoot();
		const chat = {
			identifier: 'EW-7Q2K9',
			identifierHash: 'ab'.repeat(32),
			name: 'Ada Obi',
			email: 'ada@example.com'
		};
		expect(startChat(api, chat, { network: 'Ruby Net', screen: '/app/withdrawals' })).toBe(true);
		expect(calls).toEqual([
			'user:EW-7Q2K9:email,identifier_hash,name',
			'attrs:network,screen,uid',
			'toggle:open'
		]);
	});

	it('names the contact by UID when there is no name yet (the SDK requires one)', () => {
		const { api, calls } = fakeChatwoot();
		const chat = { identifier: 'EW-7Q2K9', identifierHash: 'x', name: null, email: null };
		expect(startChat(api, chat, {})).toBe(true);
		expect(calls[0]).toBe('user:EW-7Q2K9:identifier_hash,name');
	});

	it('still opens the chat when Chatwoot refuses the identity', () => {
		const { api, calls } = fakeChatwoot();
		api.setUser = () => {
			throw new Error('refused');
		};
		const chat = { identifier: 'EW-7Q2K9', identifierHash: 'x', name: 'Ada', email: null };
		expect(startChat(api, chat, { screen: '/app/support' })).toBe(true);
		expect(calls).toEqual(['toggle:open']);
	});

	it('describes the device from the user agent', () => {
		expect(
			describeDevice(
				'Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36',
				5
			)
		).toBe('Phone · Android 14 · Chrome 141');
		expect(
			describeDevice(
				'Mozilla/5.0 (iPhone; CPU iPhone OS 19_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Mobile/15E148 Safari/604.1',
				5
			)
		).toBe('Phone · iOS 19 · Safari 19');
		expect(
			describeDevice(
				'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15',
				5
			)
		).toBe('Tablet · iOS · Safari 19');
		expect(
			describeDevice(
				'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0',
				0
			)
		).toBe('Desktop · Windows · Edge 141');
		expect(describeDevice('', 0)).toBe('Desktop · Unknown OS · Unknown browser');
	});

	it('adds the last error only when there was one', () => {
		const device = {
			userAgent: '',
			maxTouchPoints: 0,
			standalone: true,
			language: 'en-NG',
			timeZone: 'Africa/Lagos'
		};
		expect(browserContext(device, '1760000000000', '/app/income', null)).toEqual({
			screen: '/app/income',
			device: 'Desktop · Unknown OS · Unknown browser',
			installed_app: true,
			app_version: '1760000000000',
			language: 'en-NG',
			timezone: 'Africa/Lagos'
		});
		const error = {
			code: 'authorization_denied',
			requestId: '0e6c2b9a-1f3d-4c5e-8a7b-9c0d1e2f3a4b',
			screen: '/app/offices',
			at: '2026-10-11T10:00:00.000Z'
		};
		expect(browserContext(device, 'v', '/app/offices', error)).toMatchObject({
			last_error: 'authorization_denied on /app/offices',
			last_error_request: '0e6c2b9a-1f3d-4c5e-8a7b-9c0d1e2f3a4b',
			last_error_at: '2026-10-11T10:00:00.000Z'
		});
	});
});
