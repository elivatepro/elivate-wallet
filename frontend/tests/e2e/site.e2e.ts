// Slice 33: what a standard site shows a browser, a crawler and a link
// preview (Open Graph, X card, icons, robots, sitemap, security.txt).
import { expect, test } from './fixtures';

test('the sign-in page carries the description and the link preview', async ({ page }) => {
	await page.goto('/sign-in');
	const meta = (sel: string) => page.locator(sel).first().getAttribute('content');
	expect(await meta('meta[name="description"]')).toMatch(/whole team/);
	expect(await meta('meta[property="og:title"]')).toBe('Elivate Wallet');
	expect(await meta('meta[property="og:image"]')).toBe('https://app.elivatewallet.com/og.jpg');
	expect(await meta('meta[property="og:image:width"]')).toBe('1200');
	expect(await meta('meta[name="twitter:card"]')).toBe('summary_large_image');
	await expect(page.locator('link[rel="canonical"]')).toHaveAttribute(
		'href',
		'https://app.elivatewallet.com/sign-in'
	);
});

test('the preview image, icons, robots, sitemap and security.txt are served', async ({
	request
}) => {
	const og = await request.get('/og.jpg');
	expect(og.status()).toBe(200);
	expect(og.headers()['content-type']).toContain('image/jpeg');
	expect((await request.get('/favicon.ico')).status()).toBe(200);
	expect((await request.get('/icons/favicon-32.png')).status()).toBe(200);
	const robots = await (await request.get('/robots.txt')).text();
	expect(robots).toContain('Disallow: /app');
	expect(robots).toContain('Sitemap: https://app.elivatewallet.com/sitemap.xml');
	expect(await (await request.get('/sitemap.xml')).text()).toContain('/sign-in');
	expect(await (await request.get('/.well-known/security.txt')).text()).toContain(
		'Contact: mailto:support@elivatewallet.com'
	);
});
