// Shared Playwright fixtures. Cloudflare's Turnstile script is replaced by a
// local stand-in so runs never depend on challenges.cloudflare.com: it renders
// the hidden `cf-turnstile-response` field with Cloudflare's documented dummy
// token, which the app server verifies against the local siteverify stand-in
// (scripts/e2e-local.sh fake providers). Server-side verification itself is
// covered by unit tests; the real widget is smoke-tested on dev.

import { test as base, type BrowserContext } from '@playwright/test';

const STUB = `
window.turnstile = {
  render(el, options) {
    const input = document.createElement('input');
    input.type = 'hidden';
    input.name = 'cf-turnstile-response';
    input.value = 'XXXX.DUMMY.TOKEN.XXXX';
    el.appendChild(input);
    setTimeout(() => options.callback && options.callback(input.value), 0);
    return 'stub-' + Math.random().toString(36).slice(2);
  },
  reset() {},
  remove() {}
};`;

export async function stubTurnstile(context: BrowserContext) {
	await context.route('https://challenges.cloudflare.com/**', (route) =>
		route.fulfill({ status: 200, contentType: 'application/javascript', body: STUB })
	);
}

export const test = base.extend({
	context: async ({ context }, use) => {
		await stubTurnstile(context);
		await use(context);
	}
});

export { expect } from '@playwright/test';
