// Synthetic statement and report data (Paper S01–S04 sample values) for unit
// tests and the sample files compared with Paper. Never real people or money.
import type {
	MemberFigure,
	ReportSummary,
	StatementSummary,
	TxnRow
} from '#lib/contract/exports.js';

const network = {
	tenantId: '00000000-0000-4000-8000-000000000001',
	name: 'Cedar Network',
	initial: 'C'
};

export const statementSummary: StatementSummary = {
	type: 'statement',
	network,
	person: { uid: 'EW-48213', name: 'Adaeze Nwosu' },
	memberships: [{ office: 'Lagos office', role: 'member', status: 'active' }],
	currency: 'NGN',
	period: {
		kind: 'month',
		from: '2026-09-01',
		to: '2026-09-30',
		title: 'September 2026',
		asOf: '2026-09-30T23:00:00.000000Z',
		cutShort: false,
		timeZone: 'Africa/Lagos'
	},
	opening: '312400.00',
	moneyIn: '272500.00',
	moneyOut: '-128500.00',
	closing: '456400.00',
	inCount: 4,
	outTypes: { withdrawal: 2, reversal: 1 },
	pockets: [
		{
			pocket: 'Spend',
			kind: 'ordinary',
			opening: '187440.00',
			in: '183500.00',
			out: '-115500.00',
			closing: '255440.00'
		},
		{
			pocket: 'Save',
			kind: 'ordinary',
			opening: '93720.00',
			in: '81750.00',
			out: '-29750.00',
			closing: '145720.00'
		},
		{
			pocket: 'Invest',
			kind: 'ordinary',
			opening: '31240.00',
			in: '27250.00',
			out: '-3250.00',
			closing: '55240.00'
		}
	],
	pending: [
		{
			kind: 'withdrawal',
			reference: 'WDR-2M8N-0930',
			status: 'approved',
			pocket: 'Spend',
			date: '2026-09-30',
			amount: '20000.00'
		}
	],
	reserved: '20000.00',
	available: '436400.00',
	generatedAt: '2026-10-01T07:12:00.000000Z',
	reference: 'STM-4V9B-0412'
};

const txn = (
	row: Partial<TxnRow> & Pick<TxnRow, 'reference' | 'type' | 'date' | 'amount' | 'balance'>
): TxnRow => ({
	transactionId: '00000000-0000-4000-8000-0000000000aa',
	postedAt: `${row.date}T09:00:00.000000Z`,
	time: '10:00',
	office: 'Lagos office',
	status: 'posted',
	pockets: [],
	...row
});

export const statementRows: TxnRow[] = [
	txn({
		reference: 'INC-5A1B-0712',
		type: 'income',
		date: '2026-09-02',
		amount: '120000.00',
		balance: '432400.00',
		income: { source: 'Paper' },
		pockets: [
			{ pocket: 'Spend', amount: '72000.00' },
			{ pocket: 'Save', amount: '36000.00' },
			{ pocket: 'Invest', amount: '12000.00' }
		]
	}),
	txn({
		reference: 'WDR-7H2K-0455',
		type: 'withdrawal',
		date: '2026-09-09',
		amount: '-48000.00',
		balance: '384400.00',
		pockets: [{ pocket: 'Spend', amount: '-48000.00' }]
	}),
	txn({
		reference: 'INC-6C3D-0820',
		type: 'income',
		date: '2026-09-15',
		amount: '100000.00',
		balance: '484400.00',
		pockets: [
			{ pocket: 'Spend', amount: '60000.00' },
			{ pocket: 'Save', amount: '30000.00' },
			{ pocket: 'Invest', amount: '10000.00' }
		]
	}),
	txn({
		reference: 'PTR-3D1E-1101',
		type: 'pocket_transfer',
		date: '2026-09-18',
		amount: '0.00',
		balance: '484400.00',
		transfer: { from: 'Save', to: 'Spend', amount: '20000.00' },
		pockets: [
			{ pocket: 'Spend', amount: '20000.00' },
			{ pocket: 'Save', amount: '-20000.00' }
		]
	}),
	txn({
		reference: 'INC-8E4F-0915',
		type: 'income',
		date: '2026-09-22',
		amount: '32500.00',
		balance: '516900.00',
		status: 'reversed',
		reversedBy: 'REV-2B7C-0923',
		reversalCategory: 'recorded_twice',
		pockets: [{ pocket: 'Spend', amount: '32500.00' }]
	}),
	txn({
		reference: 'REV-2B7C-0923',
		type: 'reversal',
		date: '2026-09-23',
		amount: '-32500.00',
		balance: '484400.00',
		reverses: 'INC-8E4F-0915',
		reversalCategory: 'recorded_twice',
		pockets: [{ pocket: 'Spend', amount: '-32500.00' }]
	}),
	txn({
		reference: 'INC-8E5G-0923',
		type: 'income',
		date: '2026-09-23',
		amount: '20000.00',
		balance: '504400.00',
		pockets: [
			{ pocket: 'Spend', amount: '12000.00' },
			{ pocket: 'Save', amount: '6000.00' },
			{ pocket: 'Invest', amount: '2000.00' }
		]
	}),
	txn({
		reference: 'WDR-9J5K-0601',
		type: 'withdrawal',
		date: '2026-09-25',
		amount: '-48000.00',
		balance: '456400.00',
		pockets: [{ pocket: 'Spend', amount: '-48000.00' }]
	})
];

export const reportSummary: ReportSummary = {
	type: 'report',
	network,
	scope: { kind: 'office', name: 'Lagos office', member: null },
	preparedFor: { uid: 'EW-31877', name: 'Tunde B.', role: 'team_leader' },
	currency: 'NGN',
	period: {
		kind: 'month',
		from: '2026-09-01',
		to: '2026-09-30',
		title: 'September 2026',
		asOf: '2026-09-30T23:00:00.000000Z',
		cutShort: false,
		timeZone: 'Africa/Lagos'
	},
	opening: '28112750.00',
	closing: '29402750.00',
	held: [
		{ kind: 'income', count: 42, amount: '2342500.00' },
		{ kind: 'reversal', count: 1, amount: '-32500.00' },
		{ kind: 'withdrawal', count: 25, amount: '-1020000.00' }
	],
	reserved: '84000.00',
	reservedCount: 2,
	available: '29318750.00',
	netIncomeByPocket: [
		{ pocket: 'Spend', amount: '1386000.00' },
		{ pocket: 'Save', amount: '693000.00' },
		{ pocket: 'Invest', amount: '231000.00' }
	],
	netIncome: '2310000.00',
	withdrawals: [
		{ stage: 'requested', count: 31, amount: '1248000.00' },
		{ stage: 'approved', count: 27, amount: '1104000.00' },
		{ stage: 'completed', count: 25, amount: '1020000.00' },
		{ stage: 'rejected', count: 2, amount: '96000.00' },
		{ stage: 'cancelled', count: 2, amount: '48000.00' }
	],
	counts: { activeMemberships: 24, people: 24, joined: 3 },
	excludedPeople: 0,
	members: 24,
	generatedAt: '2026-10-01T08:05:00.000000Z',
	reference: 'RPT-6H4S-0031'
};

const names = [
	'Femi Adeyemi',
	'Kemi Okafor',
	'Adaeze Nwosu',
	'Bayo Lawal',
	'Chioma Eze',
	'Emeka Obi',
	'Funke Ade',
	'Ibrahim Musa',
	'Ngozi Uche',
	'Segun Ola',
	'Tolu Bello',
	'Yemi Ajayi',
	'Uche Okoro',
	'Zainab Bello',
	'Kunle Ade',
	'Amaka Obi',
	'Dayo Ogun',
	'Halima Sani',
	'Ifeoma Nnaji',
	'Jide Kola',
	'Lola Badmus',
	'Musa Ali',
	'Nkem Eze',
	'Ola Ojo'
];

export const reportMembers: MemberFigure[] = names.map((name, i) => ({
	member: { uid: `EW-${31877 + i * 1013}`, name },
	offices: ['Lagos office'],
	opening: '500000.00',
	income: `${(310000 - i * 10000).toFixed(2)}`,
	paidOut: `${(i % 3 === 0 ? 0 : 48000).toFixed(2)}`,
	in: `${(310000 - i * 10000).toFixed(2)}`,
	out: `${(i % 3 === 0 ? 0 : -48000).toFixed(2)}`,
	closing: `${(810000 - i * 10000 - (i % 3 === 0 ? 0 : 48000)).toFixed(2)}`,
	reserved: '0.00',
	available: `${(810000 - i * 10000 - (i % 3 === 0 ? 0 : 48000)).toFixed(2)}`
}));
