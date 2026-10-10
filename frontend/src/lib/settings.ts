// Workspace settings helpers (Blueprint 17): what changed between the form and
// the saved settings, the field checks the backend repeats, and the labels the
// Branding, Team details and Backup vault screens show. Pure, so it is tested.

import type {
	BackupStatus,
	Revision,
	RestoreStatus,
	SettingsField,
	SettingsPatch,
	TeamSettings,
	Theme
} from '#lib/contract/settings.js';

export interface SettingsForm {
	name: string;
	shortName: string;
	theme: Theme;
	slogan: string;
	supportName: string;
	supportEmail: string;
	supportPhone: string;
	helpUrl: string;
	locale: string;
	timeZone: string;
}

export const formOf = (s: TeamSettings): SettingsForm => ({
	name: s.name,
	shortName: s.shortName,
	theme: s.theme,
	slogan: s.slogan ?? '',
	supportName: s.supportName ?? '',
	supportEmail: s.supportEmail ?? '',
	supportPhone: s.supportPhone ?? '',
	helpUrl: s.helpUrl ?? '',
	locale: s.locale,
	timeZone: s.timeZone
});

const OPTIONAL = ['slogan', 'supportName', 'supportEmail', 'supportPhone', 'helpUrl'] as const;
const REQUIRED = ['name', 'shortName', 'theme', 'locale', 'timeZone'] as const;

/** Uploaded logo keys waiting to be saved. */
export type PendingAssets = Partial<Record<'logoKey' | 'iconKey' | 'logoLightKey', string>>;

/** Only what differs from the saved settings; empty optional text clears it. */
export function buildPatch(
	saved: TeamSettings,
	form: SettingsForm,
	assets: PendingAssets = {}
): SettingsPatch {
	const patch: Record<string, string | null> = {};
	const before = formOf(saved);
	for (const key of REQUIRED) {
		const value = form[key].trim();
		if (value !== before[key]) patch[key] = value;
	}
	for (const key of OPTIONAL) {
		const value = form[key].trim();
		if (value !== before[key]) patch[key] = value === '' ? null : value;
	}
	for (const [key, value] of Object.entries(assets)) if (value) patch[key] = value;
	return patch as SettingsPatch;
}

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const HTTPS = /^https:\/\/[^/@\s?#]+(\/\S*)?$/;

/** "+2348012342210" from "0801 234 2210"; null when it can't be a phone number. */
export function normalizePhone(value: string): string | null {
	let digits = value.replace(/[\s()-]/g, '');
	if (digits === '') return '';
	if (/^0[0-9]{10}$/.test(digits)) digits = `+234${digits.slice(1)}`;
	return /^\+[1-9][0-9]{6,14}$/.test(digits) ? digits : null;
}

export type FieldErrors = Partial<Record<keyof SettingsForm, string>>;

/** The same limits the database enforces (D-11), said plainly. */
export function checkForm(form: SettingsForm): FieldErrors {
	const errors: FieldErrors = {};
	const name = form.name.trim();
	if (name.length < 2 || name.length > 100) errors.name = 'Use 2 to 100 characters.';
	const short = form.shortName.trim();
	if (short.length < 1 || short.length > 30) errors.shortName = 'Use 1 to 30 characters.';
	if (form.slogan.trim().length > 60) errors.slogan = 'Keep it to 60 characters.';
	if (form.supportName.trim().length > 80) errors.supportName = 'Keep it to 80 characters.';
	const email = form.supportEmail.trim();
	if (email !== '' && (email.length > 254 || !EMAIL.test(email))) {
		errors.supportEmail = 'Enter an email address like help@example.com.';
	}
	if (normalizePhone(form.supportPhone) === null) {
		errors.supportPhone = 'Enter a phone number like +234 801 234 5678.';
	}
	const url = form.helpUrl.trim();
	if (url !== '' && (url.length > 300 || !HTTPS.test(url))) {
		errors.helpUrl = 'Use an https:// address without a password in it.';
	}
	return errors;
}

const FIELD_TITLES: Readonly<Record<SettingsField, string>> = {
	name: 'Team name changed',
	shortName: 'Short name changed',
	theme: 'Theme changed',
	slogan: 'Slogan updated',
	supportName: 'Support name changed',
	supportEmail: 'Support email changed',
	supportPhone: 'Support phone changed',
	helpUrl: 'Help website changed',
	locale: 'Language changed',
	timeZone: 'Time zone changed',
	logoKey: 'New logo uploaded',
	iconKey: 'New square icon uploaded',
	logoLightKey: 'New light logo uploaded'
};

/** Paper F02 "Recent changes" titles. */
export function revisionTitle(r: Revision): string {
	if (r.restoredFrom !== null) return `Restored revision ${r.restoredFrom}`;
	if (r.changed.length === 0) return 'Network created';
	const first = FIELD_TITLES[r.changed[0]!];
	return r.changed.length === 1 ? first : `${first} + ${r.changed.length - 1} more`;
}

/** "38 MB" (decimal units, like the backend's pg_size_pretty rounding). */
export function formatBytes(bytes: number | null): string {
	if (bytes === null || bytes < 0) return '—';
	if (bytes < 1024) return `${bytes} bytes`;
	const units = ['kB', 'MB', 'GB'];
	let value = bytes / 1024;
	let unit = 0;
	while (value >= 1024 && unit < units.length - 1) {
		value /= 1024;
		unit += 1;
	}
	return `${value >= 10 ? Math.round(value) : Math.round(value * 10) / 10} ${units[unit]}`;
}

/** "sha256 · 9f4c…a1e7" (Paper E09). */
export const shortChecksum = (sha: string | null) =>
	sha && /^[0-9a-f]{64}$/.test(sha) ? `sha256 · ${sha.slice(0, 4)}…${sha.slice(-4)}` : '—';

const WAT_DATE_TIME = new Intl.DateTimeFormat('en-GB', {
	day: 'numeric',
	month: 'short',
	year: 'numeric',
	hour: '2-digit',
	minute: '2-digit',
	hour12: false,
	timeZone: 'Africa/Lagos'
});
const WAT_DATE = new Intl.DateTimeFormat('en-GB', {
	day: 'numeric',
	month: 'short',
	timeZone: 'Africa/Lagos'
});

/** "5 Oct 2026, 11:40" in WAT (the network's time zone). */
export const watDateTime = (iso: string) => WAT_DATE_TIME.format(new Date(iso));
/** "3 Oct" in WAT. */
export const watDay = (iso: string) => WAT_DATE.format(new Date(iso));

export const BACKUP_STATUS: Readonly<
	Record<BackupStatus, { label: string; tone: 'success' | 'warning' | 'danger' | 'muted' }>
> = {
	queued: { label: 'Starting', tone: 'warning' },
	preparing: { label: 'In progress', tone: 'warning' },
	building: { label: 'In progress', tone: 'warning' },
	ready: { label: 'Complete', tone: 'success' },
	failed: { label: 'Failed', tone: 'danger' },
	too_large: { label: 'Too large', tone: 'danger' },
	expired: { label: 'Expired', tone: 'muted' }
};

export const RESTORE_STATUS: Readonly<
	Record<RestoreStatus, { label: string; tone: 'success' | 'warning' | 'danger' | 'muted' }>
> = {
	requested: { label: 'Requested', tone: 'warning' },
	validating: { label: 'Checking', tone: 'warning' },
	in_review: { label: 'In review', tone: 'warning' },
	restoring: { label: 'Restoring', tone: 'warning' },
	completed: { label: 'Restored', tone: 'success' },
	rejected: { label: 'Not restored', tone: 'muted' },
	cancelled: { label: 'Cancelled', tone: 'muted' },
	failed: { label: 'Failed', tone: 'danger' }
};

/** A backup is still being made: the vault refreshes until it settles. */
export const backupRunning = (status: BackupStatus) =>
	status === 'queued' || status === 'preparing' || status === 'building';
