// Workspace settings (Blueprint 17, W-20/W-21/W-24): team settings and their
// revisions, the brand every member reads, the Team Backup Vault, restore
// requests and quick search. Routes live on the `org` Edge Function. Storage
// keys (logos, archives) never reach the browser.

import { Schema } from 'effect';
import { IDEMPOTENCY_KEY_PATTERN, IsoDateTime, OfficeType, Person, Role, Uuid } from './common';
import { Money, Currency } from './ledger';

const IdempotencyKey = Schema.String.check(Schema.isPattern(IDEMPOTENCY_KEY_PATTERN));
const PinField = Schema.String.check(Schema.isPattern(/^[0-9]{4}$/));

/** The six team themes (owner answer Q3, Paper TS01d). Ember is the default. */
export const THEMES = ['ember', 'cobalt', 'fern', 'iris', 'saffron', 'rose'] as const;
export const Theme = Schema.Literals(THEMES);
export type Theme = typeof Theme.Type;

export const THEME_LABELS: Readonly<Record<Theme, string>> = {
	ember: 'Ember',
	cobalt: 'Cobalt',
	fern: 'Fern',
	iris: 'Iris',
	saffron: 'Saffron',
	rose: 'Rose'
};

export const SupportContact = Schema.Struct({
	name: Schema.NullOr(Schema.String),
	email: Schema.NullOr(Schema.String),
	phone: Schema.NullOr(Schema.String),
	helpUrl: Schema.NullOr(Schema.String)
});
export type SupportContact = typeof SupportContact.Type;

/** GET /org/brand: safe presentation fields for every member (W-20). */
export const Brand = Schema.Struct({
	tenantId: Uuid,
	name: Schema.String,
	shortName: Schema.String,
	initial: Schema.String,
	theme: Theme,
	slogan: Schema.NullOr(Schema.String),
	revision: Schema.Int,
	hasLogo: Schema.Boolean,
	hasIcon: Schema.Boolean,
	hasLogoLight: Schema.Boolean,
	support: Schema.NullOr(SupportContact)
});
export type Brand = typeof Brand.Type;

export const SettingsField = Schema.Literals([
	'name',
	'shortName',
	'theme',
	'slogan',
	'supportName',
	'supportEmail',
	'supportPhone',
	'helpUrl',
	'locale',
	'timeZone',
	'logoKey',
	'iconKey',
	'logoLightKey',
	'oneOpenWithdrawal'
]);
export type SettingsField = typeof SettingsField.Type;

export const Revision = Schema.Struct({
	revision: Schema.Int,
	changed: Schema.Array(SettingsField),
	restoredFrom: Schema.NullOr(Schema.Int),
	actor: Person,
	createdAt: IsoDateTime
});
export type Revision = typeof Revision.Type;

export const TeamSettings = Schema.Struct({
	revision: Schema.Int,
	name: Schema.String,
	shortName: Schema.String,
	theme: Theme,
	slogan: Schema.NullOr(Schema.String),
	supportName: Schema.NullOr(Schema.String),
	supportEmail: Schema.NullOr(Schema.String),
	supportPhone: Schema.NullOr(Schema.String),
	helpUrl: Schema.NullOr(Schema.String),
	locale: Schema.String,
	timeZone: Schema.String,
	hasLogo: Schema.Boolean,
	hasIcon: Schema.Boolean,
	hasLogoLight: Schema.Boolean,
	/** Blueprint 44 (D3): "One open withdrawal at a time", off by default. */
	oneOpenWithdrawal: Schema.optionalKey(Schema.Boolean),
	updatedAt: IsoDateTime
});
export type TeamSettings = typeof TeamSettings.Type;

/** GET /org/settings (manage_team_settings). */
export const SettingsView = Schema.Struct({
	settings: TeamSettings,
	options: Schema.Struct({
		themes: Schema.Array(Theme),
		locales: Schema.Array(Schema.String),
		timeZones: Schema.Array(Schema.String)
	}),
	revisions: Schema.Array(Revision),
	canEdit: Schema.Boolean
});
export type SettingsView = typeof SettingsView.Type;

/** Only changed fields are sent; null clears an optional one. Asset keys come from an upload. */
export const SettingsPatch = Schema.Struct({
	name: Schema.optional(Schema.String),
	shortName: Schema.optional(Schema.String),
	theme: Schema.optional(Theme),
	slogan: Schema.optional(Schema.NullOr(Schema.String)),
	supportName: Schema.optional(Schema.NullOr(Schema.String)),
	supportEmail: Schema.optional(Schema.NullOr(Schema.String)),
	supportPhone: Schema.optional(Schema.NullOr(Schema.String)),
	helpUrl: Schema.optional(Schema.NullOr(Schema.String)),
	locale: Schema.optional(Schema.String),
	timeZone: Schema.optional(Schema.String),
	logoKey: Schema.optional(Schema.NullOr(Schema.String)),
	iconKey: Schema.optional(Schema.NullOr(Schema.String)),
	logoLightKey: Schema.optional(Schema.NullOr(Schema.String)),
	oneOpenWithdrawal: Schema.optional(Schema.Boolean)
});
export type SettingsPatch = typeof SettingsPatch.Type;

export const SaveSettingsCommand = Schema.Struct({
	expectedRevision: Schema.Int,
	fields: SettingsPatch,
	pin: Schema.optional(PinField),
	idempotencyKey: IdempotencyKey
});
export type SaveSettingsCommand = typeof SaveSettingsCommand.Type;

export const RestoreRevisionCommand = Schema.Struct({
	expectedRevision: Schema.Int,
	revision: Schema.Int,
	pin: Schema.optional(PinField),
	idempotencyKey: IdempotencyKey
});
export type RestoreRevisionCommand = typeof RestoreRevisionCommand.Type;

export const AssetKind = Schema.Literals(['logo', 'icon', 'logo-light']);
export type AssetKind = typeof AssetKind.Type;

/** POST /api/settings/assets: the stored upload, to be saved with the settings. */
export const UploadedAsset = Schema.Struct({ kind: AssetKind, key: Schema.String });
export type UploadedAsset = typeof UploadedAsset.Type;

export const ObjectTarget = Schema.Struct({
	objectKey: Schema.String,
	fileName: Schema.optional(Schema.String),
	contentType: Schema.optional(Schema.String),
	byteSize: Schema.optional(Schema.NullOr(Schema.Int)),
	sha256: Schema.optional(Schema.NullOr(Schema.String)),
	revision: Schema.optional(Schema.Int)
});
export type ObjectTarget = typeof ObjectTarget.Type;

// ── Backup vault (W-24) ──

export const BackupStatus = Schema.Literals([
	'queued',
	'preparing',
	'building',
	'ready',
	'failed',
	'too_large',
	'expired'
]);
export type BackupStatus = typeof BackupStatus.Type;

export const Backup = Schema.Struct({
	backupId: Uuid,
	status: BackupStatus,
	startedBy: Person,
	recordCount: Schema.NullOr(Schema.Int),
	byteSize: Schema.NullOr(Schema.Int),
	sha256: Schema.NullOr(Schema.String),
	counts: Schema.NullOr(Schema.Record(Schema.String, Schema.Int)),
	failReason: Schema.NullOr(Schema.String),
	createdAt: IsoDateTime,
	readyAt: Schema.NullOr(IsoDateTime),
	expiresAt: Schema.NullOr(IsoDateTime),
	canDownload: Schema.Boolean
});
export type Backup = typeof Backup.Type;

export const RestoreStatus = Schema.Literals([
	'requested',
	'validating',
	'in_review',
	'restoring',
	'completed',
	'rejected',
	'cancelled',
	'failed'
]);
export type RestoreStatus = typeof RestoreStatus.Type;

export const Restore = Schema.Struct({
	restoreId: Uuid,
	reference: Schema.String,
	status: RestoreStatus,
	statusReason: Schema.NullOr(Schema.String),
	reason: Schema.String,
	backup: Schema.Struct({
		backupId: Uuid,
		readyAt: Schema.NullOr(IsoDateTime),
		byteSize: Schema.NullOr(Schema.Int),
		sha256: Schema.NullOr(Schema.String)
	}),
	requestedBy: Person,
	createdAt: IsoDateTime,
	updatedAt: IsoDateTime,
	canCancel: Schema.Boolean
});
export type Restore = typeof Restore.Type;

export const VaultView = Schema.Struct({
	backups: Schema.Array(Backup),
	restores: Schema.Array(Restore),
	canBackup: Schema.Boolean,
	canRequestRestore: Schema.Boolean,
	retentionDays: Schema.Int,
	rowLimit: Schema.Int
});
export type VaultView = typeof VaultView.Type;

export const StartBackupCommand = Schema.Struct({ idempotencyKey: IdempotencyKey });
export const StartedBackup = Schema.Struct({ backup: Backup });
export type StartedBackup = typeof StartedBackup.Type;

export const RestoreRequestCommand = Schema.Struct({
	backupId: Uuid,
	reason: Schema.String,
	idempotencyKey: IdempotencyKey
});
export type RestoreRequestCommand = typeof RestoreRequestCommand.Type;

export const CancelRestoreCommand = Schema.Struct({ idempotencyKey: IdempotencyKey });
export const RestoreResult = Schema.Struct({ restore: Restore });
export type RestoreResult = typeof RestoreResult.Type;

// ── Quick search (P-06) ──

export const SearchPerson = Schema.Struct({
	membershipId: Uuid,
	person: Person,
	role: Role,
	status: Schema.String,
	officeName: Schema.NullOr(Schema.String),
	emailMasked: Schema.NullOr(Schema.String),
	phoneMasked: Schema.NullOr(Schema.String),
	self: Schema.Boolean
});
export type SearchPerson = typeof SearchPerson.Type;

export const SearchOffice = Schema.Struct({
	officeId: Uuid,
	name: Schema.String,
	officeType: OfficeType,
	status: Schema.String,
	parentName: Schema.NullOr(Schema.String),
	memberCount: Schema.Int
});
export type SearchOffice = typeof SearchOffice.Type;

export const SearchRecord = Schema.Struct({
	kind: Schema.Literals(['withdrawal', 'transfer', 'returned_funds', 'transaction']),
	id: Uuid,
	reference: Schema.String,
	status: Schema.optional(Schema.String),
	type: Schema.optional(Schema.String),
	withdrawalId: Schema.optional(Schema.NullOr(Uuid)),
	walletId: Schema.optional(Schema.NullOr(Uuid)),
	amount: Schema.optional(Schema.Struct({ amount: Money, currency: Currency })),
	person: Person,
	officeName: Schema.NullOr(Schema.String),
	at: IsoDateTime,
	own: Schema.Boolean
});
export type SearchRecord = typeof SearchRecord.Type;

export const SearchResults = Schema.Struct({
	query: Schema.String,
	people: Schema.Array(SearchPerson),
	offices: Schema.Array(SearchOffice),
	records: Schema.Array(SearchRecord)
});
export type SearchResults = typeof SearchResults.Type;

export const SettingsRoutes = {
	settings: { method: 'GET', path: '/settings' },
	save: { method: 'PATCH', path: '/settings' },
	restoreRevision: { method: 'POST', path: '/settings/restore' },
	brand: { method: 'GET', path: '/brand' },
	assetKey: { method: 'POST', path: '/brand/asset-key' },
	uploadKey: { method: 'POST', path: '/brand/upload-key' },
	search: { method: 'GET', path: '/search' },
	vault: { method: 'GET', path: '/backups' },
	startBackup: { method: 'POST', path: '/backups' },
	backupDownload: (id: string) => ({ method: 'POST', path: `/backups/${id}/download` }) as const,
	requestRestore: { method: 'POST', path: '/restores' },
	cancelRestore: (id: string) => ({ method: 'POST', path: `/restores/${id}/cancel` }) as const
} as const;

/** GET /api/support/chat: Chatwoot settings, or unavailable (W-21). */
export const SupportChat = Schema.Union([
	Schema.Struct({ available: Schema.Literal(false) }),
	Schema.Struct({
		available: Schema.Literal(true),
		baseUrl: Schema.String,
		websiteToken: Schema.String,
		identifier: Schema.String,
		identifierHash: Schema.String,
		network: Schema.String,
		/**
		 * Slice 34 (owner decision 2026-10-11): support sees who they are
		 * talking to and the account context it needs. Never money, bank
		 * details, evidence, PINs or tokens.
		 */
		name: Schema.NullOr(Schema.String),
		email: Schema.NullOr(Schema.String),
		context: Schema.Record(Schema.String, Schema.String)
	})
]);
export type SupportChat = typeof SupportChat.Type;
