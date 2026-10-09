// Statements and reports (Blueprint 15, W-18), against the local stack with
// synthetic people and money only. A member with money in two networks makes
// a PDF and a CSV statement (builder S10/S08, files S11, preview S09); the
// President makes an office report and downloads it with the PIN (S05, S13d,
// S14d, S12, S06); M15 renders in light, dark and at 320 px. Files are made by
// the real export runner (local mode: temp directory + Playwright Chromium).
// E2E_SHOTS=<dir> keeps screenshots and the downloaded files for review.

import { writeFileSync } from 'node:fs';
import type { Page } from '@playwright/test';
import { expect, test } from './fixtures';
import {
	apiSession,
	createConfirmedAccount,
	expectAccessible,
	expectNoHorizontalScroll,
	invitationToken,
	inviteMember,
	localSql,
	mailFor,
	recordIncome,
	runOutboxWorker,
	shot,
	uniqueEmail,
	walletPeople
} from './helpers';

const { PASSWORD, PIN, memberWithAccount, signInAs, asPresident } = walletPeople;
const MOBILE = { width: 390, height: 844 };
const DESKTOP = { width: 1440, height: 900 };
const SECRET = process.env.EXPORTS_WORKER_SECRET ?? '';

test.describe.configure({ mode: 'serial' });
// Whole flows with real PDF rendering take longer than the default.
test.setTimeout(240_000);

/** Runs the export runner once, as pg_cron would (the app also starts it on each request). */
async function runExports(page: Page) {
	const response = await page.request.post('/internal/exports/run', {
		headers: { authorization: `Bearer ${SECRET}` }
	});
	expect(response.status()).toBe(200);
}

/** Waits for a file row to say Ready, nudging the runner if needed. */
async function untilReady(page: Page, title: RegExp) {
	const row = page.locator('.ex-row', { hasText: title }).first();
	for (let i = 0; i < 20; i++) {
		if (
			await row.locator('.ex-row-status[data-state="ready"], .ex-row[data-state="ready"]').count()
		)
			break;
		if ((await row.getAttribute('data-state')) === 'ready') break;
		if (i % 4 === 3) await runExports(page);
		await page.waitForTimeout(1000);
	}
	await expect(row).toHaveAttribute('data-state', 'ready');
	return row;
}

function keep(name: string, bytes: Buffer) {
	const dir = process.env.E2E_SHOTS;
	if (dir) writeFileSync(`${dir}/${name}`, bytes);
}

test('a member makes PDF and CSV statements; every file state shows', async ({ page }) => {
	const founder = { email: uniqueEmail('st-f'), password: PASSWORD, pin: PIN };
	const other = { email: uniqueEmail('st-o'), password: PASSWORD, pin: PIN };
	const member = uniqueEmail('st-m');
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	await createConfirmedAccount(other.email, PASSWORD, PIN);
	await memberWithAccount(founder, 'Cedar Statements', member);
	// The same person joins a second network (owner decision: a network choice then shows).
	const { joinPath } = await inviteMember(other, 'Oak Statements', member);
	const api = await apiSession(member, PASSWORD, PIN);
	await api.call('invitations', '/accept', {
		token: joinPath.split('#t=')[1] ?? '',
		idempotencyKey: `e2e${crypto.randomUUID().replaceAll('-', '')}`
	});
	await api.close();
	await recordIncome(founder, member, '120000.00');
	await recordIncome(founder, member, '20000.00');
	await recordIncome(founder, member, '300.00', 'USD');

	await signInAs(page, member);
	if (page.url().includes('/workspaces')) {
		await page.getByRole('button', { name: /Cedar Statements/ }).click();
		await expect(page).toHaveURL(/\/app/);
	}
	await page.setViewportSize(DESKTOP);
	await page.goto('/app/statements');
	await expect(page.getByRole('heading', { name: 'Create a statement' })).toBeVisible();
	await expect(page.getByLabel('Network')).toBeVisible();
	await expect(page.getByText('No files yet')).toBeVisible();
	await expectAccessible(page);
	await shot(page, 'S10d-statements-first-visit');

	await page.getByLabel('Network').selectOption({ label: 'Cedar Statements' });
	await page.getByRole('button', { name: 'This month' }).click();
	await page.getByRole('button', { name: 'Create PDF statement' }).click();
	await untilReady(page, /NGN/);
	// A PDF made while waiting opens its preview (S09d).
	const preview = page.getByRole('dialog');
	await expect(preview.getByText(/PDF · \d+ pages?/)).toBeVisible({ timeout: 15_000 });
	await expect(preview.getByRole('img', { name: /First page/ })).toBeVisible();
	await shot(page, 'S09d-statement-preview');
	const pdfDownload = page.waitForEvent('download');
	await preview.getByRole('button', { name: 'Download PDF' }).click();
	const pdf = await (await pdfDownload).path();
	const { readFileSync } = await import('node:fs');
	const pdfBytes = readFileSync(pdf);
	expect(pdfBytes.subarray(0, 5).toString()).toBe('%PDF-');
	keep('sample-statement.pdf', pdfBytes);
	await page.keyboard.press('Escape');

	// CSV of transactions: posted movements only, exact amounts.
	await page.getByRole('radio', { name: /CSV of transactions/ }).check();
	await page.getByRole('button', { name: 'Create CSV' }).click();
	const csvRow = page.locator('.ex-row').first();
	await expect(csvRow.locator('.ex-tile')).toHaveText('CSV');
	await untilReady(page, /NGN/);
	const csvDownload = page.waitForEvent('download');
	await csvRow.getByRole('button', { name: /^Get / }).click();
	const csv = readFileSync(await (await csvDownload).path(), 'utf8');
	expect(csv).toContain('posted_at_utc,date_wat,time_wat,reference');
	expect(csv).toContain('120000.00');
	expect(csv).toContain('20000.00');
	expect(csv).not.toContain('300.00'); // USD is its own statement
	keep('sample-statement.csv', Buffer.from(csv));
	expect(
		localSql(`select count(*) from audit.security_events e join auth.users u on u.id = e.actor_user_id
      where u.email = '${member}' and e.action = 'export.downloaded'`)
	).toBe('2');

	// Every other state (S11d): too large, failed, expired.
	localSql(`do $$ begin
  set local session_replication_role = replica;
  update exports.files set status = 'too_large', row_count = 99999, finished_at = null, expires_at = null,
    sha256 = null, byte_size = null
  where id = (select f.id from exports.files f join auth.users u on u.id = f.requested_by
              where u.email = '${member}' and f.kind = 'statement_csv' order by f.created_at limit 1);
  set local session_replication_role = origin;
end $$`);
	await page.getByLabel('Network').selectOption({ label: 'Oak Statements' });
	await page.getByRole('radio', { name: /PDF statement/ }).check();
	await page.getByRole('button', { name: 'Create PDF statement' }).click();
	await untilReady(page, /NGN/);
	await page.keyboard.press('Escape');
	localSql(`update exports.files set expires_at = now() - interval '1 minute'
    where id = (select f.id from exports.files f join auth.users u on u.id = f.requested_by
                where u.email = '${member}' and f.kind = 'statement_pdf' order by f.created_at limit 1)`);
	await page.goto('/app/statements');
	await expect(page.getByRole('button', { name: 'Recreate' })).toBeVisible();
	await expect(page.getByText('Too large', { exact: true })).toBeVisible();
	await expect(page.getByText('That’s a big one')).toHaveCount(0);
	await shot(page, 'S11d-statement-file-states');

	await page.setViewportSize(MOBILE);
	await page.goto('/app/statements');
	await expect(page.getByLabel('Network')).toBeVisible();
	await expectNoHorizontalScroll(page);
	await shot(page, 'S10-statements-mobile');
	await page.setViewportSize({ width: 320, height: 700 });
	await expectNoHorizontalScroll(page);
	await shot(page, 'S10-statements-320');
	await page.setViewportSize(MOBILE);
	await page
		.locator('.ex-row[data-state="ready"]')
		.first()
		.getByRole('button', { name: /^Get / })
		.click();
	await expect(page.getByRole('dialog').getByText(/Page 1 of/)).toBeVisible();
	await shot(page, 'S09-statement-preview-mobile');
});

test('the President exports an office report and downloads it with the PIN', async ({ page }) => {
	const founder = { email: uniqueEmail('rp-f'), password: PASSWORD, pin: PIN };
	await createConfirmedAccount(founder.email, PASSWORD, PIN);
	const members = [uniqueEmail('rp-a'), uniqueEmail('rp-b')];
	await memberWithAccount(founder, 'Cedar Reports', members[0]!);
	// A second member in the same office, invited and accepted through the API.
	const lead = await apiSession(founder.email, PASSWORD, PIN);
	const workspaces = await lead.call<Array<{ membershipId: string; role: string }>>(
		'org',
		'/workspaces'
	);
	const president = workspaces.find((w) => w.role === 'president_team_member')!.membershipId;
	const officeId = localSql(`select o.id from org.offices o join org.tenants t on t.id = o.tenant_id
    where t.name = 'Cedar Reports' and o.name = 'Cedar World Team' order by o.created_at desc limit 1`);
	const invitation = await lead.call<{ invitationId: string }>(
		'invitations',
		'/',
		{
			officeId,
			role: 'member',
			email: members[1],
			idempotencyKey: `e2e${crypto.randomUUID().replaceAll('-', '')}`
		},
		president
	);
	await lead.close();
	await createConfirmedAccount(members[1]!, PASSWORD, PIN);
	const second = await apiSession(members[1]!, PASSWORD, PIN);
	await second.call('invitations', '/accept', {
		token: invitationToken(invitation.invitationId),
		idempotencyKey: `e2e${crypto.randomUUID().replaceAll('-', '')}`
	});
	await second.close();
	await recordIncome(founder, members[0]!, '180000.00');
	await recordIncome(founder, members[1]!, '310000.00');

	await asPresident(page, founder.email, 'Cedar Reports');
	await page.setViewportSize(DESKTOP);
	await page.goto('/app/reports');
	await expect(page.locator('.hero-amount')).toHaveText('₦490,000.00');
	await expect(page.getByText('2 · 2')).toBeVisible(); // memberships · distinct people
	await expectAccessible(page);
	await shot(page, 'S05-reports-desktop');

	await page.getByRole('button', { name: 'Export PDF' }).click();
	const dialog = page.getByRole('dialog', { name: 'Export report' });
	await expect(dialog.getByRole('radio', { name: /Member balances · CSV/ })).toBeVisible();
	await dialog.getByLabel('Period').selectOption('this_month');
	await shot(page, 'S13d-export-report');
	await dialog.getByRole('button', { name: 'Create report' }).click();
	await expect(dialog).toBeHidden();
	await untilReady(page, /NGN/);

	// A report download needs a fresh PIN (S14d): let the sign-in proof age.
	localSql(`update identity.session_pin_proofs p set verified_at = now() - interval '10 minutes'
    from auth.users u where u.id = p.user_id and u.email = '${founder.email}'`);
	await page.locator('.ex-row').first().getByRole('button', { name: /^Get / }).click();
	const pinDialog = page.getByRole('dialog', { name: 'Download report' });
	await expect(pinDialog).toBeVisible();
	await shot(page, 'S14d-download-report-pin');
	await pinDialog.getByLabel('Your PIN').fill(PIN);
	const download = page.waitForEvent('download');
	await pinDialog.getByRole('button', { name: 'Download PDF' }).click();
	const { readFileSync } = await import('node:fs');
	const bytes = readFileSync(await (await download).path());
	expect(bytes.subarray(0, 5).toString()).toBe('%PDF-');
	keep('sample-report.pdf', bytes);
	expect(
		localSql(`select count(*) from audit.tenant_events e join auth.users u on u.id = e.actor_user_id
      where u.email = '${founder.email}' and e.action = 'export.downloaded'`)
	).toBe('1');

	await page.setViewportSize(MOBILE);
	await page.goto('/app/reports');
	await expect(page.locator('.hero-amount')).toHaveText('₦490,000.00');
	await expectNoHorizontalScroll(page);
	await shot(page, 'S12-reports-mobile');
	await page.getByRole('button', { name: 'Export report' }).click();
	await expect(page).toHaveURL(/\/app\/reports\/export/);
	await expect(page.getByText('Recent reports')).toBeVisible();
	await expectNoHorizontalScroll(page);
	await shot(page, 'S06-export-report-mobile');
});

test('M15 Statement ready renders from its Paper artboard', async ({ page }) => {
	const to = uniqueEmail('m15');
	for (const [code, chip, path, format] of [
		['M15', 'Statement', '/app/statements', 'PDF statement'],
		['M15-report', 'Report', '/app/reports', 'Office report PDF']
	] as const) {
		const params = {
			network: 'Cedar Network',
			title: 'September 2026',
			currency: 'NGN',
			format,
			chip,
			path
		};
		localSql(`select outbox.enqueue_email('money.statement_ready', 'e2e-sample:${code}:${to}', 'sample',
      gen_random_uuid(), null, null, '${to}', '${JSON.stringify(params)}'::jsonb)`);
	}
	await runOutboxWorker();
	const messages = [
		await mailFor(to, /^Your statement is ready$/),
		await mailFor(to, /^Your report is ready$/)
	];
	for (const detail of messages) {
		expect(detail.HTML).toContain('September 2026');
		expect(detail.HTML).not.toMatch(/₦|exports\//);
		const code = detail.Subject.includes('report') ? 'M15-report' : 'M15';
		for (const [label, size] of [
			['light', { width: 600, height: 700 }],
			['mobile-320', { width: 320, height: 700 }]
		] as const) {
			await page.setViewportSize(size);
			await page.setContent(detail.HTML, { waitUntil: 'load' });
			await shot(page, `email-${code}-${label}`);
		}
		await page.emulateMedia({ colorScheme: 'dark' });
		await page.setViewportSize({ width: 600, height: 700 });
		await page.setContent(detail.HTML, { waitUntil: 'load' });
		await shot(page, `email-${code}-dark`);
		await page.emulateMedia({ colorScheme: 'light' });
	}
});
