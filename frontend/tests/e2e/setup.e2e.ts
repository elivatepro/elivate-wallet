// Slice 22 (Blueprint 22): setup by role and the backend profile gate. A
// President founder finishes the light setup before /app works (even a typed
// URL with a workspace cookie); a member who skipped the NIN reaches neither
// /app nor the API; a director whose funds are not managed gets the light
// setup and no own-money pages; the switch is refused while the wallet holds
// money. Local stack only, synthetic data.

import { type Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	apiSession,
	createConfirmedAccount,
	createNetworkFor,
	inviteMember,
	lightSetupWizard,
	localSql,
	recordIncome,
	uidOf,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, signInAs } = walletPeople;
const key = () => crypto.randomUUID();

test.describe.configure({ mode: 'serial' });

/** A gated read through the app server (with the workspace cookie set). */
async function homeRead(page: Page) {
	const response = await page.request.get('/api/home');
	return {
		status: response.status(),
		body: (await response.json()) as { error?: { code: string } }
	};
}

/** Forgets an account's setup, as for a real user from before this slice. */
function forgetSetup(email: string) {
	localSql(`update identity.profiles p set photo_key = null, photo_updated_at = null, rank = null,
	  first_name = null, last_name = null from auth.users u where u.id = p.user_id and u.email = '${email}'`);
}

function membershipOf(email: string, role: string): string {
	return localSql(`select m.id from org.memberships m join auth.users u on u.id = m.user_id
	  where u.email = '${email}' and m.role = '${role}' and m.status = 'active' limit 1`);
}

test('a President founder finishes the light setup before /app works', async ({ page }) => {
	const founder = uniqueEmail('setup-founder');
	await createConfirmedAccount(founder, PASSWORD, PIN);
	await createNetworkFor(founder, PASSWORD, PIN, 'Setup Network');
	forgetSetup(founder);
	const president = membershipOf(founder, 'president_team_member');

	await signInAs(page, founder);
	await expect(page).toHaveURL(/\/onboarding\/profile$/);

	// A typed app URL, even with the workspace cookie set, lands in the wizard.
	await page
		.context()
		.addCookies([{ name: 'ew_ws', value: president, url: 'http://127.0.0.1:3000' }]);
	await page.goto('/app/members');
	await expect(page).toHaveURL(/\/onboarding\/profile$/);
	const gated = await homeRead(page);
	expect(gated.status).toBe(403);
	expect(gated.body.error?.code).toBe('profile_required');

	await lightSetupWizard(page);
	await expect(page.getByText('Transaction PIN')).toBeVisible();
	await page.getByRole('link', { name: 'Continue' }).click();
	// Back to the page that was asked for.
	await expect(page).toHaveURL(/\/app\/members$/);
	expect((await homeRead(page)).status).toBe(200);
});

test('a wallet member who skipped the NIN reaches neither /app nor the API', async ({ page }) => {
	const founder = uniqueEmail('setup-wm-founder');
	const member = uniqueEmail('setup-wm-member');
	await createConfirmedAccount(founder, PASSWORD, PIN);
	const { joinPath } = await inviteMember(
		{ email: founder, password: PASSWORD, pin: PIN },
		'Gate Network',
		member
	);
	await createConfirmedAccount(member, PASSWORD, PIN);
	const api = await apiSession(member, PASSWORD, PIN);
	await api.call('invitations', '/accept', {
		token: joinPath.split('#t=')[1],
		idempotencyKey: key()
	});
	// Straight to the Edge: every money read is refused with the step.
	await expect(api.call('ledger', '/me/wallet')).rejects.toThrow(/profile_required.*identity/);
	await api.close();

	await signInAs(page, member);
	await expect(page).toHaveURL(/\/onboarding\/identity$/);
	await page
		.context()
		.addCookies([
			{ name: 'ew_ws', value: membershipOf(member, 'member'), url: 'http://127.0.0.1:3000' }
		]);
	await page.goto('/app');
	await expect(page).toHaveURL(/\/onboarding\/identity$/);
	const gated = await homeRead(page);
	expect(gated.status).toBe(403);
	expect(gated.body.error?.code).toBe('profile_required');
});

test('a director whose funds are not managed: the switch, then the light setup', async ({
	page
}) => {
	const founder = uniqueEmail('setup-dir-founder');
	const empty = uniqueEmail('setup-dir-empty');
	const holding = uniqueEmail('setup-dir-money');
	const people = { email: founder, password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder, PASSWORD, PIN);
	await inviteMember(people, 'Funds Network', uniqueEmail('setup-dir-unused'));
	await createConfirmedAccount(empty, PASSWORD, PIN);
	await createConfirmedAccount(holding, PASSWORD, PIN);

	// A Director office under the founder's World Team, led by both directors.
	const api = await apiSession(founder, PASSWORD, PIN);
	const workspaces = await api.call<
		Array<{ membershipId: string; role: string; officeId: string }>
	>('org', '/workspaces');
	const president = workspaces.find((w) => w.role === 'president_team_member')!.membershipId;
	const worldTeam = workspaces.find((w) => w.role === 'world_team_member')!.officeId;
	await api.call(
		'org',
		'/offices',
		{
			type: 'director',
			name: 'Funds Directors',
			parentOfficeId: worldTeam,
			leaderUids: [uidOf(empty), uidOf(holding)],
			idempotencyKey: key()
		},
		president
	);
	await api.close();
	await recordIncome(people, holding, '1500.00', 'NGN', 'director');

	// The founder (President Team) opens the director with money: blocked.
	await signInAs(page, founder);
	await page.goto('/workspaces?switch');
	await page.getByRole('button', { name: /Funds Network.*President Team/ }).click();
	await page.goto(`/app/members/${membershipOf(holding, 'director')}`);
	await expect(page.getByText('Can’t switch while their wallet holds money')).toBeVisible();
	await expect(page.getByRole('button', { name: 'Funds not managed' })).toHaveCount(0);
	// Straight to the backend it is refused too.
	const direct = await apiSession(founder, PASSWORD, PIN);
	await expect(
		direct.call(
			'org',
			`/memberships/${membershipOf(holding, 'director')}/funds`,
			{ notManaged: true, reason: 'Holds no money', idempotencyKey: key() },
			president
		)
	).rejects.toThrow(/wallet_not_empty/);
	await direct.close();

	// The empty director: switched with a reason and the PIN.
	await page.goto(`/app/members/${membershipOf(empty, 'director')}`);
	await expect(page.getByText('Managed', { exact: true })).toBeVisible();
	await page.getByRole('button', { name: 'Funds not managed' }).click();
	const dialog = page.getByRole('dialog');
	await dialog.getByLabel('Reason').fill('Runs the team, holds no money');
	await dialog.getByLabel('Your PIN').fill(PIN);
	await dialog.getByRole('button', { name: /Mark funds not managed/ }).click();
	await expect(page.getByText('Funds marked as not managed.')).toBeVisible();
	await expect(page.getByText('Not managed', { exact: true })).toBeVisible();

	// The director signs in: the light setup only (no NIN, phone or bank).
	await signInAs(page, empty);
	await lightSetupWizard(page);
	await page.getByRole('link', { name: 'Continue' }).click();
	await expect(page).toHaveURL(/\/app$/);
	// Blueprint 25: a director without funds gets the network overview as Home.
	await expect(page.getByRole('region', { name: 'Income recorded this month' })).toBeVisible();
	const sidebar = page.getByRole('complementary', { name: 'Main' });
	await expect(sidebar.getByRole('link', { name: 'Withdrawals' })).toHaveCount(0);
	await expect(sidebar.getByRole('link', { name: 'Payout accounts' })).toHaveCount(0);
	await page.goto('/app/withdrawals');
	await expect(page.getByRole('heading', { name: 'Not available for your role' })).toBeVisible();
});
