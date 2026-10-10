import { describe, expect, it } from 'vitest';
import type { BackupStorage } from './storage';
import {
	removeExpired,
	runBackup,
	type BackupClient,
	type BackupRunnerDeps,
	type FileEntry,
	type Prepared
} from './runner';

const job = {
	backupId: '00000000-0000-0000-0000-0000000000f1',
	objectKey:
		'backups/00000000-0000-0000-0000-0000000000e1/00000000-0000-0000-0000-0000000000f1/1.zip',
	attempt: 1
};

const rows = [
	{ seq: 1, section: 'network', data: { id: 't' } },
	{ seq: 2, section: 'people', data: { uid: 'EW-10001' } },
	{ seq: 3, section: 'people', data: { uid: 'EW-10002' } },
	{ seq: 4, section: 'audit', data: { action: 'settings.updated' } }
];

function fakeClient(over: Partial<BackupClient> = {}, prepared?: Partial<Prepared>) {
	const calls: { step: string; args: unknown }[] = [];
	const client: BackupClient = {
		claim: async () => job,
		prepare: async () => ({
			status: 'building',
			recordCount: rows.length,
			counts: { network: 1, people: 2, audit: 1 },
			network: { tenantId: 't', name: 'Cedar Network' },
			formatVersion: 1,
			takenAt: '2026-10-05T10:40:00Z',
			...prepared
		}),
		rows: async (_id, _w, after, limit) => ({
			rows: rows.filter((r) => r.seq > after).slice(0, limit),
			recordCount: rows.length
		}),
		finalize: async (_id, _w, file) => {
			calls.push({ step: 'finalize', args: file });
			return { status: 'ready' };
		},
		fail: async (_id, _w, reason) => {
			calls.push({ step: 'fail', args: reason });
		},
		expired: async () => ({ items: [] }),
		deleted: async (id) => {
			calls.push({ step: 'deleted', args: id });
		},
		...over
	};
	return { client, calls };
}

function memoryStorage(failWrite = false) {
	const files = new Map<string, Uint8Array[]>();
	const events: string[] = [];
	const storage: BackupStorage = {
		async upload(key) {
			const parts: Uint8Array[] = [];
			return {
				async write(bytes) {
					if (failWrite) throw new Error('r2 down');
					parts.push(bytes.slice());
				},
				async complete() {
					files.set(key, parts);
					events.push('complete');
				},
				async abort() {
					events.push('abort');
				}
			};
		},
		get: async (key) => (files.has(key) ? { body: new Uint8Array() } : null),
		async delete(key) {
			files.delete(key);
			events.push(`delete:${key}`);
		}
	};
	return { storage, files, events };
}

const deps = (client: BackupClient, storage: BackupStorage, pageSize = 2): BackupRunnerDeps => ({
	client,
	storage,
	log: () => undefined,
	pageSize
});

describe('runBackup', () => {
	it('writes one file per section and finalizes with matching counts', async () => {
		const { client, calls } = fakeClient();
		const { storage, files } = memoryStorage();
		const outcome = await runBackup(deps(client, storage), job, 'w1');
		expect(outcome.status).toBe('ready');
		expect(files.has(job.objectKey)).toBe(true);
		const fin = calls.find((c) => c.step === 'finalize')?.args as {
			recordCount: number;
			files: FileEntry[];
			sha256: string;
		};
		expect(fin.recordCount).toBe(4);
		expect(fin.files.map((f) => [f.section, f.rows])).toEqual([
			['network', 1],
			['people', 2],
			['audit', 1]
		]);
		expect(fin.sha256).toMatch(/^[0-9a-f]{64}$/);
	});

	it('fails on a gap in the rows and never finalizes', async () => {
		const { client, calls } = fakeClient({
			rows: async () => ({ rows: [rows[0]!, rows[2]!], recordCount: rows.length })
		});
		const { storage, events } = memoryStorage();
		const outcome = await runBackup(deps(client, storage), job, 'w1');
		expect(outcome).toMatchObject({ status: 'failed', reason: 'incomplete' });
		expect(calls.map((c) => c.step)).toEqual(['fail']);
		expect(events).toContain('abort');
	});

	it('fails when a section count differs from the database', async () => {
		const { client } = fakeClient({}, { counts: { network: 1, people: 3, audit: 1 } });
		const outcome = await runBackup(deps(client, memoryStorage().storage), job, 'w1');
		expect(outcome).toMatchObject({ status: 'failed', reason: 'incomplete' });
	});

	it('reports storage failures and aborts the upload', async () => {
		const { client, calls } = fakeClient();
		const { storage, events } = memoryStorage(true);
		const outcome = await runBackup(deps(client, storage), job, 'w1');
		expect(outcome).toMatchObject({ status: 'failed', reason: 'storage_failed' });
		expect(calls.at(-1)).toEqual({ step: 'fail', args: 'storage_failed' });
		expect(events).toContain('abort');
	});

	it('passes "too large" through without storing anything', async () => {
		const { client } = fakeClient({
			prepare: async () => ({ status: 'too_large', recordCount: 600000 })
		});
		const { storage, files } = memoryStorage();
		expect((await runBackup(deps(client, storage), job, 'w1')).status).toBe('too_large');
		expect(files.size).toBe(0);
	});
});

describe('removeExpired', () => {
	it('deletes every attempt file, then marks the backup gone', async () => {
		const { client, calls } = fakeClient({
			expired: async () => ({
				items: [{ backupId: job.backupId, objectKeys: [job.objectKey] }]
			})
		});
		const { storage, events } = memoryStorage();
		expect(await removeExpired(deps(client, storage))).toBe(1);
		expect(events).toEqual([`delete:${job.objectKey}`]);
		expect(calls).toEqual([{ step: 'deleted', args: job.backupId }]);
	});
});
