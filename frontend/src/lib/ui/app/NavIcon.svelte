<!--
	Blueprint 25: one Lucide icon per navigation item (Paper "Navigation v5"
	NV01–NV03 draw the same shapes). Decorative: the item's label names it.
-->
<script lang="ts">
	import ArrowDownToLine from '@lucide/svelte/icons/arrow-down-to-line';
	import ArrowRightLeft from '@lucide/svelte/icons/arrow-right-left';
	import ArrowUp from '@lucide/svelte/icons/arrow-up';
	import Blend from '@lucide/svelte/icons/blend';
	import ChartNoAxesColumn from '@lucide/svelte/icons/chart-no-axes-column';
	import ChartPie from '@lucide/svelte/icons/chart-pie';
	import Clock from '@lucide/svelte/icons/clock';
	import CreditCard from '@lucide/svelte/icons/credit-card';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';
	import File from '@lucide/svelte/icons/file';
	import FileText from '@lucide/svelte/icons/file-text';
	import House from '@lucide/svelte/icons/house';
	import Landmark from '@lucide/svelte/icons/landmark';
	import PiggyBank from '@lucide/svelte/icons/piggy-bank';
	import LayoutGrid from '@lucide/svelte/icons/layout-grid';
	import List from '@lucide/svelte/icons/list';
	import Mail from '@lucide/svelte/icons/mail';
	import RotateCcw from '@lucide/svelte/icons/rotate-ccw';
	import Shield from '@lucide/svelte/icons/shield';
	import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
	import SquareCheck from '@lucide/svelte/icons/square-check';
	import Upload from '@lucide/svelte/icons/upload';
	import UserRound from '@lucide/svelte/icons/user-round';
	import Users from '@lucide/svelte/icons/users';
	import Wallet from '@lucide/svelte/icons/wallet';
	import Warehouse from '@lucide/svelte/icons/warehouse';
	import type { NavIcon } from '#lib/nav.js';

	let {
		name,
		size = 18,
		strokeWidth = 1.9
	}: { name: NavIcon; size?: number; strokeWidth?: number } = $props();

	const ICONS: Record<NavIcon, typeof House> = {
		home: House,
		team: LayoutGrid,
		activity: List,
		withdraw: Upload,
		more: Ellipsis,
		approvals: SquareCheck,
		people: Users,
		queue: ArrowUp,
		transfers: ArrowRightLeft,
		evidence: File,
		identity: UserRound,
		reversals: RotateCcw,
		income: ArrowDownToLine,
		wallets: Wallet,
		mywallet: PiggyBank,
		convert: Blend,
		reports: ChartNoAxesColumn,
		members: Users,
		offices: Warehouse,
		invitations: Mail,
		access: Shield,
		settings: SlidersHorizontal,
		billing: CreditCard,
		audit: Clock,
		payout: Landmark,
		statements: FileText,
		split: ChartPie
	};
	const Icon = $derived(ICONS[name]);
</script>

<Icon {size} {strokeWidth} aria-hidden="true" />
