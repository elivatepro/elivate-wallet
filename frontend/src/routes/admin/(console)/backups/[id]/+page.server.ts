import { error, fail, redirect, type RequestEvent } from '@sveltejs/kit';
import { Effect } from 'effect';
import type { RestoreStatus } from '#lib/contract/admin.js';
import { AdminApi } from '#lib/server/apis-admin.js';
import {
	adminCall,
	adminPage,
	adminPathForCode,
	newKey,
	readCommandForm,
	requireAdmin,
	withStepUp
} from '#lib/server/admin.js';
import type { VerifiedSession } from '#lib/server/auth.js';
import { validateRestore } from '#lib/server/backups/restore-check.js';
import type { Actions, PageServerLoad } from './$types';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** The dialogs this page opens (?dialog=…) and the status each one moves to. */
const DIALOG_STATUS = {
	start: 'validating',
	fail: 'failed',
	reject: 'rejected',
	restore: 'restoring',
	complete: 'completed'
} as const;
type Dialog = keyof typeof DIALOG_STATUS;
type Target = (typeof DIALOG_STATUS)[Dialog];

/** Which dialogs fit each status (mirrors platform_advance_restore). */
const ALLOWED: Partial<Record<RestoreStatus, readonly Dialog[]>> = {
	requested: ['start'],
	validating: ['fail'],
	in_review: ['reject', 'restore'],
	restoring: ['complete', 'fail']
};

const isDialog = (value: string | null): value is Dialog =>
	value !== null && Object.hasOwn(DIALOG_STATUS, value);

function restoreId(params: { id: string }): string {
	if (!UUID.test(params.id)) error(404, 'Not found');
	return params.id;
}

const NOTICES = {
	unfinished: 'Validation didn’t finish. Run it again.',
	unavailable: 'Backup storage isn’t available here. Run validation again later.',
	moved: 'That step is no longer possible. Reload to see the latest status.'
} as const;
type Notice = keyof typeof NOTICES;

export const load: PageServerLoad = (event) =>
	adminPage(event, async (session) => {
		const id = restoreId(event.params);
		const restore = await adminCall(
			event,
			session,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).restore(id);
			})
		);
		const asked = event.url.searchParams.get('dialog');
		const dialog = isDialog(asked) && ALLOWED[restore.status]?.includes(asked) ? asked : null;
		return {
			title: `Backups & restores / ${restore.reference}`,
			restore,
			dialog,
			notice: NOTICES[event.url.searchParams.get('notice') as Notice] ?? null,
			idempotencyKey: newKey()
		};
	});

/** Runs one validation pass; returns a notice for the page when it couldn't finish. */
async function runValidation(
	event: RequestEvent,
	session: VerifiedSession,
	id: string
): Promise<Notice | null> {
	const outcome = await validateRestore(event, session, id);
	if (outcome.ok) return null;
	const failure = outcome.failure;
	if (failure === null) return 'unavailable';
	if (failure._tag === 'BackendError') {
		const gate = adminPathForCode(failure.code);
		if (gate) redirect(303, gate);
		if (failure.code === 'conflict' && failure.details.reason === 'invalid_transition') {
			return 'moved';
		}
	}
	return 'unfinished';
}

const backTo = (id: string, notice: Notice | null) =>
	notice ? `/admin/backups/${id}?notice=${notice}` : `/admin/backups/${id}`;

export const actions: Actions = {
	/** Reason + PIN: one step of the guided restore (W-24, owner answer Q7). */
	advance: async (event) => {
		const { session } = await requireAdmin(event);
		const id = restoreId(event.params);
		const command = await readCommandForm(event);
		if (!('pin' in command)) return command;
		const status = String(command.form.get('status') ?? '') as Target;
		if (!Object.values(DIALOG_STATUS).includes(status)) {
			return fail(400, { error: 'Reload the page and try again.', reason: command.reason });
		}
		const result = await withStepUp(
			event,
			session,
			command.pin,
			Effect.gen(function* () {
				return yield* (yield* AdminApi).advanceRestore(id, {
					status,
					reason: command.reason,
					idempotencyKey: command.idempotencyKey
				});
			})
		);
		if (!result.ok) return fail(result.status, { error: result.message, reason: command.reason });
		// Starting validation runs it straight away (no second PIN: a continuation).
		if (status === 'validating') {
			redirect(303, backTo(id, await runValidation(event, session, id)));
		}
		redirect(303, backTo(id, null));
	},

	/** Runs validation again while the request is still validating. */
	validate: async (event) => {
		const { session } = await requireAdmin(event);
		const id = restoreId(event.params);
		redirect(303, backTo(id, await runValidation(event, session, id)));
	}
};
