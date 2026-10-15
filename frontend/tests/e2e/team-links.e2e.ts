// Team invite links (Blueprint 38; Paper "Team links v11"): a leader makes the
// office's link with the PIN, a newcomer opens it, signs up with their own
// email and joins as a Member at once; turning it off stops it. Local stack
// only, synthetic data.

import { type Page } from '@playwright/test';
import { expect, stubTurnstile, test } from './fixtures';
import {
	confirmLinkFor,
	createConfirmedAccount,
	expectAccessible,
	humanReady,
	pick,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, memberWithAccount, asPresident } = walletPeople;
const NETWORK = 'Linden Test Network';

test.describe.configure({ mode: 'serial' });

const founder = { email: uniqueEmail('links-f'), password: PASSWORD, pin: PIN };
let linkPath = '';

async function openTeamLink(page: Page) {
	await page.goto('/app/invitations?invite');
	const dialog = page.getByRole('dialog', { name: 'Invite a member' });
	await expect(dialog).toBeVisible();
	await dialog.getByRole('tab', { name: 'Team link' }).click();
	return dialog;
}

test('a leader makes the office’s team link with the PIN', async ({ page }) => {
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await memberWithAccount(founder, NETWORK, uniqueEmail('links-m'));
	await asPresident(page, founder.email, NETWORK);

	const dialog = await openTeamLink(page);
	await expect(dialog.getByText('Link works for')).toBeVisible();
	await expect(dialog.getByRole('combobox', { name: 'Link works for' })).toHaveText('7 days');
	await pick(dialog.getByRole('combobox', { name: 'People who can join' }), '10 people');
	await expectAccessible(page);

	// "You'll confirm with your PIN": the first press asks for it.
	await dialog.getByRole('button', { name: 'Create link' }).click();
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: 'Create link' }).click();

	await expect(dialog.getByText('Your team link')).toBeVisible();
	const shown = await dialog.locator('.url').innerText();
	expect(shown).toMatch(/\/j\/[0-9A-HJKMNP-TV-Z]{10}$/);
	linkPath = shown.slice(shown.indexOf('/j/'));
	await expect(dialog.getByText('0 of 10')).toBeVisible();
	await expectAccessible(page);
});

test('a newcomer opens the link, signs up and joins as a Member', async ({ browser }) => {
	const context = await browser.newContext();
	await stubTurnstile(context);
	const page = await context.newPage();
	const newcomer = uniqueEmail('links-new');

	// The code leaves the address bar at once.
	await page.goto(linkPath);
	await expect(page).toHaveURL(/\/team-join$/);
	await expect(page.getByRole('heading', { name: /^Join / })).toBeVisible();
	await expect(page.getByText(`invited you to ${NETWORK}. You’ll join as a Member.`)).toBeVisible();
	await expectAccessible(page);

	await page.getByLabel('Email', { exact: true }).fill(newcomer);
	await page.getByLabel('Create a password').fill(PASSWORD);
	await humanReady(page);
	await page.getByRole('button', { name: 'Create account' }).click();
	await expect(page.getByRole('heading', { name: 'Check your inbox' })).toBeVisible();

	// The confirmation email returns to the join page in this browser.
	await page.goto(await confirmLinkFor(newcomer, /Confirm your Elivate Wallet email/));
	await page.getByRole('button', { name: 'Continue' }).click();
	await expect(page).toHaveURL(/\/team-join$/);
	await expect(page.getByText(newcomer)).toBeVisible();
	await page.getByRole('button', { name: `Join ${NETWORK}` }).click();

	await expect(page).toHaveURL(/\/onboarding$/);
	await expect(page.getByRole('heading', { name: `Welcome to ${NETWORK}` })).toBeVisible();
	await expect(page.getByText('Member', { exact: true })).toBeVisible();
	await context.close();
});

test('the leader sees the join and turns the link off', async ({ page, browser }) => {
	await asPresident(page, founder.email, NETWORK);
	// Slice 39 (Paper TL07d): the Invitations page shows the live link and its count.
	await page.goto('/app/invitations');
	const card = page.getByRole('region', { name: /^Team link/ });
	await expect(card.getByText('Live')).toBeVisible();
	await expect(card.getByText('1 of 10', { exact: true })).toBeVisible();
	await expect(card.getByText(linkPath)).toBeVisible();
	await expectAccessible(page);
	// Manage opens the Invite dialog on its Team link tab.
	await card.getByRole('button', { name: 'Manage' }).click();
	const dialog = page.getByRole('dialog', { name: 'Invite a member' });
	await expect(dialog.getByRole('tab', { name: 'Team link' })).toHaveAttribute(
		'aria-selected',
		'true'
	);
	await expect(dialog.getByText('1 of 10')).toBeVisible();

	await dialog.getByRole('button', { name: 'Turn off' }).click();
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: 'Turn off link' }).click();
	await expect(dialog.getByRole('button', { name: 'Create link' })).toBeVisible();
	// Paper TL08: closing the dialog leaves the card offering a new link.
	await page.keyboard.press('Escape');
	await expect(card.getByRole('button', { name: 'Make a team link' })).toBeVisible();

	// Anyone who opens it now gets the one "unavailable" answer.
	const context = await browser.newContext();
	const late = await context.newPage();
	await late.goto(linkPath);
	await expect(late).toHaveURL(/\/team-join$/);
	await expect(late.getByRole('heading', { name: 'This link has stopped working' })).toBeVisible();
	await late.goto('/j/ABCDEFGHJK');
	await expect(late.getByRole('heading', { name: 'This link has stopped working' })).toBeVisible();
	await context.close();
});
