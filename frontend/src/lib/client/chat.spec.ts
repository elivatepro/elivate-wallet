import { describe, expect, it } from 'vitest';
import { CHATWOOT_SETTINGS, chatScreen, sdkUrl, startChat, type ChatwootApi } from './chat.js';

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

	it('names the Chatwoot contact by UID only, which the SDK requires, then opens', () => {
		const { api, calls } = fakeChatwoot();
		const chat = { identifier: 'EW-7Q2K9', identifierHash: 'ab'.repeat(32), network: 'Ruby Net' };
		expect(startChat(api, chat, '/app/support')).toBe(true);
		expect(calls).toEqual([
			'user:EW-7Q2K9:identifier_hash,name',
			'attrs:network,screen,uid',
			'toggle:open'
		]);
	});

	it('still opens the chat when Chatwoot refuses the identity', () => {
		const { api, calls } = fakeChatwoot();
		api.setUser = () => {
			throw new Error('refused');
		};
		const chat = { identifier: 'EW-7Q2K9', identifierHash: 'x', network: 'Ruby Net' };
		expect(startChat(api, chat, '/app/support')).toBe(true);
		expect(calls).toEqual(['toggle:open']);
	});
});
