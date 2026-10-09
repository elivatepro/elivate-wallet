// Evidence files of one conversion / adjustment / returned-funds attempt
// (Blueprint 12, E-01). Each file uploads once per command key (the backend
// binds uploads to it); a new key (after a definitive refusal) uploads again.

import { Cause, Effect, Exit, Option } from 'effect';
import type { ApiFailure } from '#lib/contract/errors.js';
import { EntryAppRoutes, type EntryKind } from '#lib/contract/entries.js';
import { RECEIPT_MAX_BYTES } from '#lib/contract/income.js';
import { uploadEntryEvidence } from './income-api';

export const EVIDENCE_MAX_FILES = 5;

export interface PickedFile {
	readonly id: string;
	readonly file: File;
	evidenceId: string | null;
	/** The command key the upload is bound to. */
	key: string | null;
	progress: number | null;
}

export class EntryEvidence {
	files = $state<PickedFile[]>([]);
	problem = $state<string | null>(null);

	/** Adds picked files; refuses the wrong type or size (PDF, JPG, PNG up to 10 MB). */
	add(list: FileList | null | undefined): void {
		this.problem = null;
		for (const file of Array.from(list ?? [])) {
			if (this.files.length >= EVIDENCE_MAX_FILES) {
				this.problem = `Up to ${EVIDENCE_MAX_FILES} files.`;
				break;
			}
			if (!/^(application\/pdf|image\/(jpeg|png))$/.test(file.type)) {
				this.problem = 'Upload a PDF, JPG or PNG.';
				continue;
			}
			if (file.size > RECEIPT_MAX_BYTES) {
				this.problem = 'Each file must be 10 MB or smaller.';
				continue;
			}
			this.files.push({
				id: crypto.randomUUID(),
				file,
				evidenceId: null,
				key: null,
				progress: null
			});
		}
	}

	remove(id: string): void {
		this.files = this.files.filter((f) => f.id !== id);
	}

	clear(): void {
		this.files = [];
		this.problem = null;
	}

	/**
	 * Uploads every file not yet bound to `key`; returns the evidence ids, or
	 * the failure (a PIN prompt, a refusal or a network error).
	 */
	async upload(
		input: { kind: EntryKind; targetMembershipId: string; key: string; pin?: string },
		workspaceId: string
	): Promise<{ ids: string[] } | { failure: ApiFailure | null }> {
		const ids: string[] = [];
		for (const f of this.files) {
			if (f.evidenceId && f.key === input.key) {
				ids.push(f.evidenceId);
				continue;
			}
			f.progress = 0;
			const exit = await Effect.runPromiseExit(
				uploadEntryEvidence(
					{
						file: f.file,
						kind: input.kind,
						targetMembershipId: input.targetMembershipId,
						idempotencyKey: input.key,
						...(input.pin ? { pin: input.pin } : {})
					},
					workspaceId,
					EntryAppRoutes.evidenceUpload,
					(fraction) => (f.progress = fraction)
				)
			);
			f.progress = null;
			if (Exit.isFailure(exit)) {
				return { failure: Option.getOrUndefined(Cause.findErrorOption(exit.cause)) ?? null };
			}
			f.evidenceId = exit.value.evidenceId;
			f.key = input.key;
			ids.push(exit.value.evidenceId);
		}
		return { ids };
	}
}
