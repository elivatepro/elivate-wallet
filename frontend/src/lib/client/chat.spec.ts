import { describe, expect, it } from 'vitest';
import { CHATWOOT_SETTINGS, chatScreen, sdkUrl } from './chat.js';

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
});
