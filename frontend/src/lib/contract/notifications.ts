// The bell (Blueprint 13): `identity` Edge routes /notifications*, derived
// from api.my_notifications / my_notification_count / mark_notifications_read.
// Items carry safe display params only; the kind decides the wording.

import { Schema } from 'effect';
import { IsoDateTime, Uuid } from './common';

export const NotificationItem = Schema.Struct({
	id: Uuid,
	kind: Schema.String,
	/** A live "needs your action" task this workspace can still do. */
	open: Schema.Boolean,
	subject: Schema.Struct({ type: Schema.String, id: Uuid }),
	params: Schema.Record(Schema.String, Schema.String),
	read: Schema.Boolean,
	createdAt: IsoDateTime
});
export type NotificationItem = typeof NotificationItem.Type;

export const NotificationPage = Schema.Struct({
	actions: Schema.Array(NotificationItem),
	items: Schema.Array(NotificationItem),
	nextCursor: Schema.NullOr(Schema.String),
	unread: Schema.Int
});
export type NotificationPage = typeof NotificationPage.Type;

export const UnreadCount = Schema.Struct({ unread: Schema.Int });
export const MarkedRead = Schema.Struct({ marked: Schema.Int, unread: Schema.Int });

export const NotificationView = Schema.Literals(['unread', 'all']);
export type NotificationView = typeof NotificationView.Type;

export const MarkReadCommand = Schema.Union([
	Schema.Struct({ ids: Schema.Array(Uuid) }),
	Schema.Struct({ all: Schema.Literal(true) })
]);
export type MarkReadCommand = typeof MarkReadCommand.Type;

export const NotificationRoutes = {
	list: { method: 'GET', path: '/notifications' },
	unread: { method: 'GET', path: '/notifications/unread' },
	read: { method: 'POST', path: '/notifications/read' }
} as const;

export const BellRoutes = {
	list: '/api/notifications',
	unread: '/api/notifications/unread',
	read: '/api/notifications/read'
} as const;
