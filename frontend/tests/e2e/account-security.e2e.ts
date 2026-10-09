// Account and security extras (Blueprint 14): sign-in history with the
// approximate place, unusual sign-ins and A07, changing the password while
// signed in (Z08/Z09) with A06, the reset confirmation (Z10), and A08 on a
// PIN change. Local stack only: the place comes from the local-only e2e
// headers (E2E_GEO_HEADERS), emails reach Mailpit. Synthetic data.

import { type Browser, type Page } from '@playwright/test';
import { expect, stubTurnstile, test } from './fixtures';
import {
	confirmLinkFor,
	createConfirmedAccount,
	expectAccessible,
	fillSettled,
	humanReady,
	mailFor,
	shot,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, memberWithAccount } = walletPeople;
const NEW_PASSWORD = 'staple-lantern-violet';
const NEW_PIN = '2468';
const DESKTOP = { width: 1440, height: 900 };
const MOBILE = { width: 390, height: 844 };
const WINDOWS_EDGE =
	'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0';
const LAGOS = { 'cf-connecting-ip': '102.89.1.10', 'x-e2e-city': 'Lagos', 'x-e2e-country': 'NG' };
const ABUJA = { 'cf-connecting-ip': '41.58.1.1', 'x-e2e-city': 'Abuja', 'x-e2e-country': 'NG' };

test.describe.configure({ mode: 'serial' });

async function signIn(page: Page, email: string, password: string, pin: string) {
	await page.context().clearCookies();
	await page.goto('/sign-in');
	await page.getByLabel('Email address').fill(email);
	await page.getByLabel('Password', { exact: true }).fill(password);
	await humanReady(page);
	await page.getByRole('button', { name: 'Sign in' }).click();
	await page.getByLabel('PIN', { exact: true }).fill(pin);
	await page.getByRole('button', { name: 'Verify' }).click();
	await expect(page).not.toHaveURL(/\/pin(\?.*)?$/);
}

/** Another device: its own browser, user agent and place. */
async function otherDevice(browser: Browser, headers: Record<string, string>, userAgent?: string) {
	const context = await browser.newContext({
		extraHTTPHeaders: headers,
		...(userAgent ? { userAgent } : {})
	});
	await stubTurnstile(context);
	return { context, page: await context.newPage() };
}

/** Renders a caught email for the Paper comparison: light, dark and 320 px. */
async function shootEmail(page: Page, html: string, code: string) {
	for (const [label, size] of [
		['light', { width: 600, height: 700 }],
		['mobile-320', { width: 320, height: 700 }]
	] as const) {
		await page.setViewportSize(size);
		await page.setContent(html, { waitUntil: 'load' });
		await shot(page, `email-${code}-${label}`);
	}
	await page.emulateMedia({ colorScheme: 'dark' });
	await page.setViewportSize({ width: 600, height: 700 });
	await page.setContent(html, { waitUntil: 'load' });
	await shot(page, `email-${code}-dark`);
	await page.emulateMedia({ colorScheme: 'light' });
}

test('sign-ins record the place; a new place and device is unusual and sends A07', async ({
	page,
	browser
}) => {
	const founder = { email: uniqueEmail('sec-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('sec-m');
	await memberWithAccount(founder, 'Security Test Network', member);

	// First sign-in through the app, from Lagos: never unusual.
	await page.context().setExtraHTTPHeaders(LAGOS);
	await signIn(page, member, PASSWORD, PIN);

	// Then a Windows laptop in Abuja: new place and new device.
	const other = await otherDevice(browser, ABUJA, WINDOWS_EDGE);
	await signIn(other.page, member, PASSWORD, PIN);

	const a07 = await mailFor(member, /^New sign-in to your Elivate Wallet$/);
	expect(a07.HTML).toContain('Windows · Edge · Abuja');
	expect(a07.HTML).toContain('Review sessions');
	expect(a07.HTML).not.toMatch(/41\.58|102\.89/);
	await other.context.close();

	// Devices & sessions (Z07/S03/S04): places and the unusual sign-in.
	await page.setViewportSize(DESKTOP);
	await page.goto('/app/account/devices');
	await expect(page.getByText('Lagos, Nigeria (approx.)').first()).toBeVisible();
	await expect(page.getByText('Abuja, Nigeria (approx.)').first()).toBeVisible();
	const unusual = page.getByRole('region', { name: 'Unusual sign-ins' });
	await expect(unusual.getByText('Windows · Edge · new device and location')).toBeVisible();
	await expect(unusual.getByText(/Signed in .* · still signed in/)).toBeVisible();
	await expect(page.getByText(/102\.89|41\.58/)).toHaveCount(0);
	await expectAccessible(page);
	await shot(page, 'Z07-devices-unusual-desktop');
	await page.setViewportSize(MOBILE);
	await page.reload();
	await expect(
		unusual.getByText(/New device and location · Abuja \(approx\.\) · .* · still signed in/)
	).toBeVisible();
	await shot(page, 'S04-devices-unusual-mobile');

	// The bell has the personal item.
	await page.setViewportSize(DESKTOP);
	await page.goto('/app/account');
	await expect(page.getByText('Password', { exact: true })).toBeVisible();
	await expect(page.getByText('New location').first()).toBeVisible();
	await shot(page, 'B09-profile-security-desktop');

	// "Not you? Change password" opens Z08.
	await page.goto('/app/account/devices');
	await unusual.getByRole('link', { name: 'Not you? Change password' }).click();
	await expect(page).toHaveURL(/\/app\/account\/password$/);

	await page.goto('/');
	await shootEmail(page, a07.HTML, 'A07');
});

test('change password while signed in (Z08/Z09): PIN only, others signed out, A06', async ({
	page,
	browser
}) => {
	const founder = { email: uniqueEmail('pw-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const member = uniqueEmail('pw-m');
	await memberWithAccount(founder, 'Password Test Network', member);
	await signIn(page, member, PASSWORD, PIN);
	const other = await otherDevice(browser, LAGOS);
	await signIn(other.page, member, PASSWORD, PIN);

	await page.setViewportSize(DESKTOP);
	await page.goto('/app/account');
	await page.getByRole('link', { name: /Password/ }).click();
	await expect(page).toHaveURL(/\/app\/account\/password$/);
	await expect(page.getByRole('heading', { name: 'Change password' })).toBeVisible();
	await expectAccessible(page);
	await shot(page, 'Z08-change-password-desktop');
	await page.setViewportSize(MOBILE);
	await shot(page, 'Z08-change-password-mobile');
	await page.setViewportSize(DESKTOP);

	// Too short, then a wrong PIN (counted), then the change.
	await fillSettled(page, 'New password', 'short');
	await page.getByLabel('Your PIN').fill(PIN);
	await page.getByRole('button', { name: 'Save new password' }).click();
	await expect(page.getByText('Use at least 8 characters.')).toBeVisible();
	await fillSettled(page, 'New password', NEW_PASSWORD);
	await page.getByLabel('Your PIN').fill('9999');
	await page.getByRole('button', { name: 'Save new password' }).click();
	await expect(page.getByText('That PIN is incorrect. 4 tries left.')).toBeVisible();
	await fillSettled(page, 'New password', NEW_PASSWORD);
	await page.getByLabel('Your PIN').fill(PIN);
	await page.getByRole('button', { name: 'Save new password' }).click();
	await expect(
		page.getByText('Your other devices were signed out.', { exact: false })
	).toBeVisible();
	await shot(page, 'Z09-password-changed-desktop');
	await page.setViewportSize(MOBILE);
	await shot(page, 'Z09-password-changed-mobile');
	await page.setViewportSize(DESKTOP);

	// This device stays signed in; the other one is signed out by Auth.
	await page.getByRole('button', { name: 'Back to Profile & security' }).click();
	await expect(page.getByText(/^Changed \d+ \w+ \d{4}$/)).toBeVisible();
	await other.page.goto('/workspaces');
	await expect(other.page).toHaveURL(/\/sign-in$/);
	await other.context.close();

	const a06 = await mailFor(member, /^Your Elivate Wallet password was changed$/);
	expect(a06.HTML).toContain('Secure my account');
	expect(a06.HTML).not.toContain(NEW_PASSWORD);

	// The new password signs in; then a PIN change sends A08.
	await signIn(page, member, NEW_PASSWORD, PIN);
	await page.goto('/app/account/pin');
	await page.getByLabel('Current PIN').fill(PIN);
	await page.getByLabel('New PIN', { exact: true }).fill(NEW_PIN);
	await page.getByLabel('Confirm new PIN').fill(NEW_PIN);
	await page.getByRole('button', { name: 'Save new PIN' }).click();
	await expect(page.getByText('Your PIN is changed.')).toBeVisible();
	const a08 = await mailFor(member, /^Your Wallet PIN was changed$/);
	expect(a08.HTML).toContain('Review security');
	expect(a08.HTML).not.toMatch(new RegExp(`${PIN}|${NEW_PIN}`));

	// Both are personal bell items.
	await page.goto('/app/notifications');
	await expect(page.getByText('PIN changed').first()).toBeVisible();
	await expect(page.getByText('Password changed').first()).toBeVisible();

	await page.goto('/');
	await shootEmail(page, a06.HTML, 'A06');
	await shootEmail(page, a08.HTML, 'A08');
});

test('password reset shows Z10 (others signed out), then the PIN; A06 sent', async ({
	page,
	browser
}) => {
	const email = uniqueEmail('sec-reset');
	await createConfirmedAccount(email, PASSWORD, PIN);
	const other = await otherDevice(browser, LAGOS);
	await other.page.goto('/sign-in');
	await other.page.getByLabel('Email address').fill(email);
	await other.page.getByLabel('Password', { exact: true }).fill(PASSWORD);
	await humanReady(other.page);
	await other.page.getByRole('button', { name: 'Sign in' }).click();
	await expect(other.page).toHaveURL(/\/pin(\?.*)?$/);

	await page.goto('/forgot-password');
	await page.getByLabel('Email address').fill(email);
	await humanReady(page);
	await page.getByRole('button', { name: 'Send reset instructions' }).click();
	await page.goto(await confirmLinkFor(email, /Reset your Elivate Wallet password/));
	await page.getByRole('button', { name: 'Continue' }).click();
	await fillSettled(page, 'New password', NEW_PASSWORD);
	await page.getByRole('button', { name: 'Save new password' }).click();

	await page.setViewportSize(DESKTOP);
	await expect(page.getByRole('heading', { name: 'Password changed' })).toBeVisible();
	await expect(page.getByText(/were signed out/)).toBeVisible();
	await expectAccessible(page);
	await shot(page, 'Z10-reset-saved-desktop');
	await page.setViewportSize(MOBILE);
	await shot(page, 'Z10-reset-saved-mobile');
	await page.getByRole('link', { name: 'Continue to PIN' }).click();
	await expect(page).toHaveURL(/\/pin(\?.*)?$/);

	await other.page.goto('/workspaces');
	await expect(other.page).toHaveURL(/\/sign-in$/);
	await other.context.close();

	const a06 = await mailFor(email, /^Your Elivate Wallet password was changed$/);
	expect(a06.HTML).toContain('Password changed');
});
